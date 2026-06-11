-- ════════════════════════════════════════════════════════════════════
-- 182_commission_7pct.sql
--
-- OBJETIVO: Cambiar comisión de plataforma de 10%/8% a 7%.
--
-- Modelo correcto:
--   cliente paga:  base_price × 1.07  (total_price en reservations)
--   app gana:      total_price / 1.07 × 0.07  = base_price × 0.07
--   grupo recibe:  total_price - commission    = base_price
--
-- Fórmula general:  commission = total_price × rate / (100 + rate)
--   con rate = 7 → total_price × 7/107
--   Ejemplo: $3,745 × 7/107 = $245 → grupo recibe $3,500 ✓
--
-- Cambios:
--   1. countries.commission_rate → 7
--   2. calculate_commission() trigger → fórmula 7/107
--   3. mp_credit_pending_earnings → 0.08 → fórmula 7/107
--
-- Requiere: 181_create_ad_state_and_indices.sql
-- ════════════════════════════════════════════════════════════════════


-- ── 1. countries: actualizar tasa a 7% ──────────────────────────────────────

UPDATE public.countries
SET commission_rate    = 7.0,
    default_commission = 7.0;

-- ── 2. calculate_commission() — trigger BEFORE INSERT en reservations ────────
--
-- Antes:  commission = total_price × rate / 100   (rate=10 → 10% del total)
-- Ahora:  commission = total_price × rate / (100 + rate)
--         Esto garantiza que group_earnings = base_price exacto.

CREATE OR REPLACE FUNCTION public.calculate_commission()
RETURNS TRIGGER AS $func$
DECLARE
  v_commission_rate DECIMAL;
BEGIN
  SELECT c.commission_rate INTO v_commission_rate
  FROM public.groups g
  JOIN public.countries c ON g.country_id = c.id
  WHERE g.id = NEW.group_id;

  -- Fallback si no tiene país asignado
  IF v_commission_rate IS NULL THEN
    v_commission_rate := 7.0;
  END IF;

  -- commission = total_price × rate / (100 + rate)
  -- → grupo recibe exactamente el precio base (total_price / 1.rate)
  NEW.platform_commission := ROUND(
    NEW.total_price * v_commission_rate / (100.0 + v_commission_rate),
    2
  );
  NEW.group_earnings := NEW.total_price - NEW.platform_commission;

  RETURN NEW;
END;
$func$ LANGUAGE plpgsql SECURITY DEFINER;


-- ── 3. mp_credit_pending_earnings — reemplazar 0.08 por fórmula 7/107 ────────
--
-- El total_price guardado ya incluye el 7% (base × 1.07).
-- Para extraer exactamente 7% del base: total_price × 7 / 107

CREATE OR REPLACE FUNCTION public.mp_credit_pending_earnings(
  p_reservation_id UUID,
  p_payment_id     TEXT,
  p_amount_paid    NUMERIC  DEFAULT NULL,
  p_is_deposit     BOOLEAN  DEFAULT FALSE
)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_res        RECORD;
  v_commission NUMERIC(12,2);
  v_group_net  NUMERIC(12,2);
  v_payout     RECORD;
  v_owner_id   UUID;
  v_admin_id   UUID;
  v_credited   INT := 0;
  v_deposit    NUMERIC(12,2);
BEGIN
  SELECT * INTO v_res
  FROM   public.reservations
  WHERE  id = p_reservation_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'reservation_not_found');
  END IF;

  IF v_res.wallet_pending_credited THEN
    RETURN jsonb_build_object('ok', true, 'skipped', true, 'reason', 'already_pending_credited');
  END IF;

  v_admin_id := public.get_platform_admin_id();

  -- ── Modelo de anticipo (50%): comisión completa extraída del depósito ──
  IF p_is_deposit THEN
    v_deposit    := COALESCE(p_amount_paid, ROUND(v_res.total_price * 0.5, 2));
    -- 7% del base_price = total_price × 7/107
    v_commission := ROUND(v_res.total_price * 7.0 / 107.0, 2);

    -- Si el anticipo no alcanza para la comisión completa, tomar lo disponible
    IF v_commission > v_deposit THEN
      v_commission := v_deposit;
    END IF;

    v_group_net := v_deposit - v_commission;

    RAISE NOTICE '[COMMISSION_FLOW] deposit res=% total=% commission=% group_net=% deposit=%',
      p_reservation_id, v_res.total_price, v_commission, v_group_net, v_deposit;

    -- Marcar pago recibido
    UPDATE public.reservations
    SET payment_status          = 'deposit_paid',
        mp_payment_id           = p_payment_id,
        wallet_pending_credited = TRUE,
        commission_extracted    = TRUE
    WHERE id = p_reservation_id;

    -- 7% → admin (disponible de inmediato)
    IF v_admin_id IS NOT NULL THEN
      INSERT INTO public.wallets (user_id) VALUES (v_admin_id)
        ON CONFLICT (user_id) DO NOTHING;

      UPDATE public.wallets
      SET available_balance = available_balance + v_commission,
          total_earned      = total_earned + v_commission,
          updated_at        = NOW()
      WHERE user_id = v_admin_id;

      INSERT INTO public.wallet_transactions
        (user_id, amount, type, status, reference_event_id, description)
      VALUES
        (v_admin_id, v_commission, 'commission', 'completed', p_reservation_id,
         'Comisión 7% extraída del anticipo · evento ' || v_res.event_date::TEXT);

      INSERT INTO public.financial_ledger
        (reservation_id, user_id, entry_type, amount, currency, description)
      VALUES
        (p_reservation_id, v_admin_id, 'platform_commission', v_commission, 'mxn',
         'Comisión completa del anticipo · evento ' || v_res.event_date::TEXT);
    END IF;

    -- Resto del anticipo → grupo (pending hasta que termine el evento)
    SELECT g.owner_id INTO v_owner_id
    FROM   public.groups g
    WHERE  g.id = v_res.group_id;

    IF v_owner_id IS NOT NULL AND v_group_net > 0 THEN
      INSERT INTO public.wallets (user_id) VALUES (v_owner_id)
        ON CONFLICT (user_id) DO NOTHING;

      UPDATE public.wallets
      SET pending_balance = pending_balance + v_group_net,
          updated_at      = NOW()
      WHERE user_id = v_owner_id;

      INSERT INTO public.wallet_transactions
        (user_id, amount, type, status, reference_event_id, description)
      VALUES
        (v_owner_id, v_group_net, 'event_earning', 'pending', p_reservation_id,
         'Saldo del anticipo en espera · evento ' || v_res.event_date::TEXT);

      INSERT INTO public.notifications
        (user_id, type, title, body, data)
      VALUES
        (v_owner_id, 'payment',
         '⏳ Anticipo recibido',
         'Tienes $' || v_group_net::TEXT ||
         ' MXN reservados. Se liberarán al terminar el evento.',
         jsonb_build_object(
           'reservation_id', p_reservation_id,
           'amount',         v_group_net,
           'screen',         'Wallet'
         ));
    END IF;

    RETURN jsonb_build_object(
      'ok',         true,
      'type',       'deposit',
      'deposit',    v_deposit,
      'commission', v_commission,
      'group_net',  v_group_net
    );
  END IF;

  -- ── Flujo normal (pago completo / segundo pago) ────────────────────────

  -- Si la comisión ya fue extraída del anticipo, no volver a cobrarla
  IF v_res.commission_extracted THEN
    v_commission := 0;
    v_group_net  := COALESCE(p_amount_paid, v_res.total_price * 0.5);
  ELSE
    -- 7% del base_price = total_price × 7/107
    v_commission := ROUND(v_res.total_price * 7.0 / 107.0, 2);
    v_group_net  := v_res.total_price - v_commission;
  END IF;

  RAISE NOTICE '[COMMISSION_FLOW] full res=% total=% commission=% group_net=% commission_already_extracted=%',
    p_reservation_id, v_res.total_price, v_commission, v_group_net, v_res.commission_extracted;

  UPDATE public.reservations
  SET payment_status          = 'deposit_paid',
      mp_payment_id           = p_payment_id,
      wallet_pending_credited = TRUE
  WHERE id = p_reservation_id;

  -- Comisión al admin (solo si no se extrajo antes)
  IF v_admin_id IS NOT NULL AND v_commission > 0 THEN
    INSERT INTO public.wallets (user_id) VALUES (v_admin_id)
      ON CONFLICT (user_id) DO NOTHING;

    UPDATE public.wallets
    SET pending_balance = pending_balance + v_commission,
        updated_at      = NOW()
    WHERE user_id = v_admin_id;

    INSERT INTO public.wallet_transactions
      (user_id, amount, type, status, reference_event_id, description)
    VALUES
      (v_admin_id, v_commission, 'commission', 'pending', p_reservation_id,
       'Comisión 7% en espera · evento ' || v_res.event_date::TEXT);
  END IF;

  -- Ganancias del grupo
  FOR v_payout IN
    SELECT ep.user_id, ep.amount, ep.role
    FROM   public.event_payouts ep
    WHERE  ep.reservation_id = p_reservation_id
      AND  ep.payout_status  = 'pending'
      AND  ep.amount         > 0
  LOOP
    INSERT INTO public.wallets (user_id) VALUES (v_payout.user_id)
      ON CONFLICT (user_id) DO NOTHING;

    UPDATE public.wallets
    SET pending_balance = pending_balance + v_payout.amount,
        updated_at      = NOW()
    WHERE user_id = v_payout.user_id;

    INSERT INTO public.wallet_transactions
      (user_id, amount, type, status, reference_event_id, description)
    VALUES
      (v_payout.user_id, v_payout.amount, 'event_earning', 'pending',
       p_reservation_id,
       'Ganancia en espera · evento ' || v_res.event_date::TEXT || ' (' || v_payout.role || ')');

    INSERT INTO public.notifications (user_id, type, title, body, data)
    VALUES (v_payout.user_id, 'payment',
      '⏳ Dinero reservado para ti',
      'Tienes $' || v_payout.amount::TEXT || ' MXN reservados.',
      jsonb_build_object('reservation_id', p_reservation_id, 'amount', v_payout.amount, 'screen', 'Wallet'));

    v_credited := v_credited + 1;
  END LOOP;

  IF v_credited = 0 THEN
    SELECT g.owner_id INTO v_owner_id FROM public.groups g WHERE g.id = v_res.group_id;
    IF v_owner_id IS NOT NULL THEN
      INSERT INTO public.wallets (user_id) VALUES (v_owner_id) ON CONFLICT (user_id) DO NOTHING;
      UPDATE public.wallets
      SET pending_balance = pending_balance + v_group_net, updated_at = NOW()
      WHERE user_id = v_owner_id;
      INSERT INTO public.wallet_transactions (user_id, amount, type, status, reference_event_id, description)
      VALUES (v_owner_id, v_group_net, 'event_earning', 'pending', p_reservation_id,
        'Ganancia en espera · evento ' || v_res.event_date::TEXT || ' (owner)');
    END IF;
  END IF;

  RETURN jsonb_build_object('ok', true, 'commission', v_commission, 'group_net', v_group_net);

EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$$;


-- ── Verificación ──────────────────────────────────────────────────────────────

-- Confirmar tasa en countries
SELECT name, commission_rate, default_commission FROM public.countries;

-- Ejemplo de la fórmula: base=$3500, client=$3745, commission=$245, group=$3500
SELECT
  3745                                          AS client_price,
  ROUND(3745 * 7.0 / 107.0, 2)                 AS commission,
  3745 - ROUND(3745 * 7.0 / 107.0, 2)          AS group_earnings;

SELECT '182_commission_7pct.sql ejecutado ✅' AS status;
