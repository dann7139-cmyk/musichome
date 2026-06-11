-- ════════════════════════════════════════════════════════════════════
-- 64_commission_distribution.sql
-- Flujo de comisiones mejorado:
--
-- Eventos normales   → 8% plataforma (admin wallet) + 92% participantes
-- Horas extra        → 3% plataforma (admin wallet) + 97% dueño del grupo
--
-- Todos los montos de eventos van a pending_balance al pagar,
-- y se liberan a available_balance cuando termina el evento.
-- Las horas extra van directo a available_balance (evento ya en curso).
--
-- Ejecutar DESPUÉS de 63_mp_pending_flow.sql.
-- ════════════════════════════════════════════════════════════════════

-- ── Helper: obtener user_id del admin principal ───────────────────────────
CREATE OR REPLACE FUNCTION public.get_platform_admin_id()
RETURNS UUID
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT id FROM public.profiles
  WHERE role = 'admin'
  ORDER BY created_at
  LIMIT 1;
$$;

-- ════════════════════════════════════════════════════════════════════
-- RPC: mp_credit_pending_earnings  (reemplaza versión de 63)
-- Cuando MercadoPago confirma el pago:
--   1. 8% → admin wallet (pending)
--   2. 92% distribuido entre participantes (pending, según event_payouts)
-- ════════════════════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION public.mp_credit_pending_earnings(
  p_reservation_id UUID,
  p_payment_id     TEXT,
  p_amount_paid    NUMERIC DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
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

  -- Marcar pago recibido
  UPDATE public.reservations
  SET payment_status          = 'deposit_paid',
      mp_payment_id           = p_payment_id,
      wallet_pending_credited = TRUE
  WHERE id = p_reservation_id;

  -- Calcular comisión 8%
  v_commission := ROUND(v_res.total_price * 0.08, 2);
  v_group_net  := v_res.total_price - v_commission;
  v_admin_id   := public.get_platform_admin_id();

  -- ── 1. Comisión 8% → admin wallet (pending) ───────────────────────────
  IF v_admin_id IS NOT NULL THEN
    INSERT INTO public.wallets (user_id)
    VALUES (v_admin_id)
    ON CONFLICT (user_id) DO NOTHING;

    UPDATE public.wallets
    SET pending_balance = pending_balance + v_commission,
        updated_at      = NOW()
    WHERE user_id = v_admin_id;

    INSERT INTO public.wallet_transactions
      (user_id, amount, type, status, reference_event_id, description)
    VALUES
      (v_admin_id, v_commission, 'commission', 'pending', p_reservation_id,
       'Comisión plataforma 8% en espera · evento ' || v_res.event_date::TEXT);

    INSERT INTO public.financial_ledger
      (reservation_id, user_id, entry_type, amount, currency, description)
    VALUES
      (p_reservation_id, v_admin_id, 'platform_commission', v_commission, 'mxn',
       'Comisión 8% pendiente · evento ' || v_res.event_date::TEXT);
  END IF;

  -- ── 2. Distribuir 92% entre participantes (pending) ───────────────────
  FOR v_payout IN
    SELECT ep.user_id, ep.amount, ep.role
    FROM   public.event_payouts ep
    WHERE  ep.reservation_id = p_reservation_id
      AND  ep.payout_status  = 'pending'
      AND  ep.amount         > 0
  LOOP
    INSERT INTO public.wallets (user_id)
    VALUES (v_payout.user_id)
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

    INSERT INTO public.notifications
      (user_id, type, title, body, data)
    VALUES
      (v_payout.user_id, 'payment',
       '⏳ Dinero reservado para ti',
       'Tienes $' || v_payout.amount::TEXT ||
       ' MXN reservados. Se liberarán cuando termine el evento.',
       jsonb_build_object(
         'reservation_id', p_reservation_id,
         'amount',         v_payout.amount,
         'screen',         'Wallet'
       ));

    v_credited := v_credited + 1;
  END LOOP;

  -- Fallback: sin event_payouts → 92% al dueño del grupo
  IF v_credited = 0 THEN
    SELECT g.owner_id INTO v_owner_id
    FROM   public.groups g
    WHERE  g.id = v_res.group_id;

    IF v_owner_id IS NOT NULL THEN
      INSERT INTO public.wallets (user_id)
      VALUES (v_owner_id)
      ON CONFLICT (user_id) DO NOTHING;

      UPDATE public.wallets
      SET pending_balance = pending_balance + v_group_net,
          updated_at      = NOW()
      WHERE user_id = v_owner_id;

      INSERT INTO public.wallet_transactions
        (user_id, amount, type, status, reference_event_id, description)
      VALUES
        (v_owner_id, v_group_net, 'event_earning', 'pending', p_reservation_id,
         'Ganancia en espera · evento ' || v_res.event_date::TEXT || ' (owner)');

      INSERT INTO public.notifications
        (user_id, type, title, body, data)
      VALUES
        (v_owner_id, 'payment',
         '⏳ Dinero reservado para ti',
         'Tienes $' || v_group_net::TEXT ||
         ' MXN reservados. Se liberarán cuando termine el evento.',
         jsonb_build_object(
           'reservation_id', p_reservation_id,
           'amount',         v_group_net,
           'screen',         'Wallet'
         ));

      v_credited := 1;
    END IF;
  END IF;

  RETURN jsonb_build_object(
    'ok',         true,
    'credited',   v_credited,
    'total',      v_res.total_price,
    'commission', v_commission,
    'group_net',  v_group_net
  );

EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$$;

GRANT EXECUTE ON FUNCTION public.mp_credit_pending_earnings(UUID, TEXT, NUMERIC) TO service_role;

-- ════════════════════════════════════════════════════════════════════
-- RPC: distribute_event_earnings  (reemplaza versión de 63)
-- Cuando el evento termina → libera TODOS los pendientes:
--   - Comisión admin (type='commission')
--   - Ganancias participantes (type='event_earning')
-- ════════════════════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION public.distribute_event_earnings(
  p_reservation_id UUID
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_res         RECORD;
  v_commission  NUMERIC(12,2);
  v_group_net   NUMERIC(12,2);
  v_tx          RECORD;
  v_payout      RECORD;
  v_owner_id    UUID;
  v_admin_id    UUID;
  v_distributed INT     := 0;
  v_has_pending BOOLEAN;
BEGIN
  SELECT * INTO v_res
  FROM   public.reservations
  WHERE  id = p_reservation_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'reservation_not_found');
  END IF;

  IF v_res.wallet_distributed THEN
    RETURN jsonb_build_object('ok', true, 'skipped', true, 'reason', 'already_distributed');
  END IF;

  v_commission := ROUND(v_res.total_price * 0.08, 2);
  v_group_net  := v_res.total_price - v_commission;
  v_admin_id   := public.get_platform_admin_id();

  -- Marcar evento completado
  UPDATE public.reservations
  SET commission_amount  = v_commission,
      platform_fee       = v_commission,
      group_earnings     = v_group_net,
      wallet_distributed = TRUE,
      payout_completed   = TRUE,
      status             = 'completed',
      payment_status     = 'fully_paid',
      event_ended_at     = COALESCE(event_ended_at, NOW())
  WHERE id = p_reservation_id;

  -- ── ¿Hay transacciones pendientes? (flujo MercadoPago) ───────────────
  SELECT EXISTS (
    SELECT 1
    FROM   public.wallet_transactions
    WHERE  reference_event_id = p_reservation_id
      AND  type   IN ('event_earning', 'commission')
      AND  status = 'pending'
  ) INTO v_has_pending;

  -- ── RUTA A: liberar todas las transacciones pendientes ────────────────
  -- Incluye comisión admin (commission) + ganancias participantes (event_earning)
  IF v_has_pending THEN
    FOR v_tx IN
      SELECT id, user_id, amount, type
      FROM   public.wallet_transactions
      WHERE  reference_event_id = p_reservation_id
        AND  type   IN ('event_earning', 'commission')
        AND  status = 'pending'
    LOOP
      -- Mover pending → available
      UPDATE public.wallets
      SET available_balance = available_balance + v_tx.amount,
          pending_balance   = GREATEST(0, pending_balance - v_tx.amount),
          total_earned      = total_earned + v_tx.amount,
          updated_at        = NOW()
      WHERE user_id = v_tx.user_id;

      -- Marcar transacción completada
      UPDATE public.wallet_transactions
      SET status      = 'completed',
          description = REGEXP_REPLACE(description, 'en espera', 'liberada')
      WHERE id = v_tx.id;

      -- Marcar payout como pagado (solo para event_earning)
      IF v_tx.type = 'event_earning' THEN
        UPDATE public.event_payouts
        SET payout_status = 'paid'
        WHERE reservation_id = p_reservation_id
          AND user_id        = v_tx.user_id;
      END IF;

      -- Notificar según tipo
      IF v_tx.type = 'commission' THEN
        -- Notificación al admin
        INSERT INTO public.notifications
          (user_id, type, title, body, data)
        VALUES
          (v_tx.user_id, 'payment',
           '📊 Comisión liberada — $' || v_tx.amount::TEXT,
           'La comisión de $' || v_tx.amount::TEXT ||
           ' MXN del evento del ' || v_res.event_date::TEXT ||
           ' ya está disponible en la billetera de la plataforma.',
           jsonb_build_object(
             'reservation_id', p_reservation_id,
             'amount',         v_tx.amount,
             'screen',         'Wallet'
           ));
      ELSE
        -- Notificación a participantes
        INSERT INTO public.notifications
          (user_id, type, title, body, data)
        VALUES
          (v_tx.user_id, 'payment',
           '💰 ¡Dinero disponible en tu billetera!',
           'Tu ganancia de $' || v_tx.amount::TEXT ||
           ' MXN ya está disponible. ¡Puedes retirarla cuando quieras!',
           jsonb_build_object(
             'reservation_id', p_reservation_id,
             'amount',         v_tx.amount,
             'screen',         'Wallet'
           ));
      END IF;

      v_distributed := v_distributed + 1;
    END LOOP;

  -- ── RUTA B: sin pending → acreditar directo (legacy / sin MP) ────────
  ELSE
    -- 8% al admin directamente
    IF v_admin_id IS NOT NULL THEN
      INSERT INTO public.wallets (user_id)
      VALUES (v_admin_id)
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
         'Comisión plataforma 8% · evento ' || v_res.event_date::TEXT);

      INSERT INTO public.financial_ledger
        (reservation_id, user_id, entry_type, amount, currency, description)
      VALUES
        (p_reservation_id, v_admin_id, 'platform_commission', v_commission, 'mxn',
         'Comisión 8% · evento ' || v_res.event_date::TEXT);
    END IF;

    -- 92% a participantes según event_payouts
    FOR v_payout IN
      SELECT ep.user_id, ep.amount, ep.role
      FROM   public.event_payouts ep
      WHERE  ep.reservation_id = p_reservation_id
        AND  ep.payout_status  = 'pending'
        AND  ep.amount         > 0
    LOOP
      INSERT INTO public.wallets (user_id)
      VALUES (v_payout.user_id)
      ON CONFLICT (user_id) DO NOTHING;

      UPDATE public.wallets
      SET available_balance = available_balance + v_payout.amount,
          total_earned      = total_earned + v_payout.amount,
          updated_at        = NOW()
      WHERE user_id = v_payout.user_id;

      INSERT INTO public.wallet_transactions
        (user_id, amount, type, status, reference_event_id, description)
      VALUES
        (v_payout.user_id, v_payout.amount, 'event_earning', 'completed',
         p_reservation_id,
         'Ganancia evento ' || v_res.event_date::TEXT || ' (' || v_payout.role || ')');

      INSERT INTO public.financial_ledger
        (reservation_id, user_id, entry_type, amount, currency, description)
      VALUES
        (p_reservation_id, v_payout.user_id,
         CASE v_payout.role
           WHEN 'owner'  THEN 'group_transfer'
           WHEN 'member' THEN 'member_transfer'
           ELSE               'talent_transfer'
         END,
         v_payout.amount, 'mxn',
         'Pago evento ' || v_res.event_date::TEXT);

      UPDATE public.event_payouts
      SET payout_status = 'paid'
      WHERE reservation_id = p_reservation_id
        AND user_id        = v_payout.user_id;

      INSERT INTO public.notifications
        (user_id, type, title, body, data)
      VALUES
        (v_payout.user_id, 'payment',
         '💰 Pago disponible en tu billetera',
         'Tu pago de $' || v_payout.amount::TEXT || ' MXN está disponible.',
         jsonb_build_object(
           'reservation_id', p_reservation_id,
           'amount',         v_payout.amount,
           'screen',         'Wallet'
         ));

      v_distributed := v_distributed + 1;
    END LOOP;

    -- Sin event_payouts → 92% al dueño del grupo
    IF v_distributed = 0 THEN
      SELECT g.owner_id INTO v_owner_id
      FROM   public.groups g
      WHERE  g.id = v_res.group_id;

      IF v_owner_id IS NOT NULL THEN
        INSERT INTO public.wallets (user_id) VALUES (v_owner_id) ON CONFLICT (user_id) DO NOTHING;
        UPDATE public.wallets
        SET available_balance = available_balance + v_group_net,
            total_earned      = total_earned + v_group_net,
            updated_at        = NOW()
        WHERE user_id = v_owner_id;
        INSERT INTO public.wallet_transactions
          (user_id, amount, type, status, reference_event_id, description)
        VALUES
          (v_owner_id, v_group_net, 'event_earning', 'completed',
           p_reservation_id, 'Ganancia evento ' || v_res.event_date::TEXT || ' (owner)');
        INSERT INTO public.notifications
          (user_id, type, title, body, data)
        VALUES
          (v_owner_id, 'payment', '💰 Pago disponible en tu billetera',
           'Tu pago de $' || v_group_net::TEXT || ' MXN está disponible.',
           jsonb_build_object(
             'reservation_id', p_reservation_id,
             'amount',         v_group_net,
             'screen',         'Wallet'
           ));
        v_distributed := 1;
      END IF;
    END IF;
  END IF;

  RETURN jsonb_build_object(
    'ok',               true,
    'reservation',      p_reservation_id,
    'total',            v_res.total_price,
    'commission',       v_commission,
    'group_net',        v_group_net,
    'distributed',      v_distributed,
    'used_pending_flow', v_has_pending
  );

EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$$;

GRANT EXECUTE ON FUNCTION public.distribute_event_earnings(UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION public.distribute_event_earnings(UUID) TO service_role;

-- ════════════════════════════════════════════════════════════════════
-- RPC: credit_extra_hour_earnings
-- Cuando se cobra una hora extra durante el evento:
--   3% → admin wallet (disponible de inmediato)
--   97% → dueño del grupo (disponible de inmediato)
-- ════════════════════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION public.credit_extra_hour_earnings(
  p_reservation_id UUID,
  p_extra_amount   NUMERIC   -- monto total cobrado por hora(s) extra
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_res        RECORD;
  v_commission NUMERIC(12,2);
  v_net        NUMERIC(12,2);
  v_admin_id   UUID;
  v_owner_id   UUID;
BEGIN
  SELECT r.*, g.owner_id AS group_owner_id
  INTO   v_res
  FROM   public.reservations r
  JOIN   public.groups g ON g.id = r.group_id
  WHERE  r.id = p_reservation_id;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'reservation_not_found');
  END IF;

  IF p_extra_amount <= 0 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_amount');
  END IF;

  -- 3% comisión para horas extra
  v_commission := ROUND(p_extra_amount * 0.03, 2);
  v_net        := p_extra_amount - v_commission;
  v_admin_id   := public.get_platform_admin_id();
  v_owner_id   := v_res.group_owner_id;

  -- ── 3% al admin (disponible de inmediato) ────────────────────────────
  IF v_admin_id IS NOT NULL THEN
    INSERT INTO public.wallets (user_id)
    VALUES (v_admin_id)
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
       'Comisión 3% hora extra · evento ' || v_res.event_date::TEXT);

    INSERT INTO public.financial_ledger
      (reservation_id, user_id, entry_type, amount, currency, description)
    VALUES
      (p_reservation_id, v_admin_id, 'platform_commission', v_commission, 'mxn',
       'Comisión 3% hora extra · evento ' || v_res.event_date::TEXT);
  END IF;

  -- ── 97% al dueño del grupo (disponible de inmediato) ─────────────────
  IF v_owner_id IS NOT NULL THEN
    INSERT INTO public.wallets (user_id)
    VALUES (v_owner_id)
    ON CONFLICT (user_id) DO NOTHING;

    UPDATE public.wallets
    SET available_balance = available_balance + v_net,
        total_earned      = total_earned + v_net,
        updated_at        = NOW()
    WHERE user_id = v_owner_id;

    INSERT INTO public.wallet_transactions
      (user_id, amount, type, status, reference_event_id, description)
    VALUES
      (v_owner_id, v_net, 'extra_hour', 'completed', p_reservation_id,
       'Ganancia hora extra · evento ' || v_res.event_date::TEXT);

    INSERT INTO public.financial_ledger
      (reservation_id, user_id, entry_type, amount, currency, description)
    VALUES
      (p_reservation_id, v_owner_id, 'extra_hour', v_net, 'mxn',
       'Hora extra · evento ' || v_res.event_date::TEXT);

    INSERT INTO public.notifications
      (user_id, type, title, body, data)
    VALUES
      (v_owner_id, 'payment',
       '💰 Hora extra cobrada',
       'Se agregaron $' || v_net::TEXT ||
       ' MXN a tu billetera por hora(s) extra del evento.',
       jsonb_build_object(
         'reservation_id', p_reservation_id,
         'amount',         v_net,
         'screen',         'Wallet'
       ));
  END IF;

  RETURN jsonb_build_object(
    'ok',          true,
    'extra_amount', p_extra_amount,
    'commission',  v_commission,
    'net',         v_net,
    'admin_id',    v_admin_id,
    'owner_id',    v_owner_id
  );

EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$$;

GRANT EXECUTE ON FUNCTION public.credit_extra_hour_earnings(UUID, NUMERIC) TO authenticated;
GRANT EXECUTE ON FUNCTION public.credit_extra_hour_earnings(UUID, NUMERIC) TO service_role;

SELECT '64_commission_distribution: comisión admin 8%/3% + distribute + extra_hours ✅' AS status;
