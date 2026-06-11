-- ════════════════════════════════════════════════════════════════════════════
-- 135_deposit_commission_and_extra_hours_confirm.sql
--
-- 1. Modelo de anticipo (50%):
--    Al pagar el anticipo, la plataforma extrae TODA su comisión (8% del total).
--    El saldo restante queda retenido para el grupo en pending_balance.
--
-- 2. Flujo de doble confirmación para horas extra:
--    Cliente solicita → Grupo confirma → Comisión descontada del saldo retenido
--
-- Ejecutar DESPUÉS de 134_ad_video_link_type.sql
-- ════════════════════════════════════════════════════════════════════════════


-- ── 1. Columnas nuevas en reservations ────────────────────────────────────

ALTER TABLE public.reservations
  ADD COLUMN IF NOT EXISTS commission_extracted BOOLEAN DEFAULT FALSE,
  ADD COLUMN IF NOT EXISTS extra_hours_added    INTEGER DEFAULT 0;

-- ── 2. Columnas nuevas en extra_hours ─────────────────────────────────────

ALTER TABLE public.extra_hours
  ADD COLUMN IF NOT EXISTS client_confirmed_at TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS group_confirmed_at  TIMESTAMPTZ;

-- Ampliar CHECK de status para incluir el nuevo estado
ALTER TABLE public.extra_hours
  DROP CONSTRAINT IF EXISTS extra_hours_status_check;

ALTER TABLE public.extra_hours
  ADD CONSTRAINT extra_hours_status_check
    CHECK (status IN ('pending', 'client_requested', 'accepted', 'rejected', 'expired'));


-- ════════════════════════════════════════════════════════════════════════════
-- RPC: mp_credit_pending_earnings  (reemplaza 64)
-- Soporta p_is_deposit = TRUE:
--   · Extrae TODA la comisión (8% del total_price) del anticipo
--   · El resto del anticipo va a pending del grupo
-- ════════════════════════════════════════════════════════════════════════════

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
    v_commission := ROUND(v_res.total_price * 0.08, 2);   -- 8% del TOTAL

    -- Si el anticipo no alcanza para la comisión completa, tomar lo disponible
    IF v_commission > v_deposit THEN
      v_commission := v_deposit;
    END IF;

    v_group_net := v_deposit - v_commission;

    -- Marcar pago recibido
    UPDATE public.reservations
    SET payment_status          = 'deposit_paid',
        mp_payment_id           = p_payment_id,
        wallet_pending_credited = TRUE,
        commission_extracted    = TRUE
    WHERE id = p_reservation_id;

    -- 8% → admin (available de inmediato, ya se ganó)
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
         'Comisión 8% extraída del anticipo · evento ' || v_res.event_date::TEXT);

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
    v_commission := ROUND(v_res.total_price * 0.08, 2);
    v_group_net  := v_res.total_price - v_commission;
  END IF;

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
       'Comisión 8% en espera · evento ' || v_res.event_date::TEXT);
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

GRANT EXECUTE ON FUNCTION public.mp_credit_pending_earnings(UUID, TEXT, NUMERIC, BOOLEAN) TO service_role;
GRANT EXECUTE ON FUNCTION public.mp_credit_pending_earnings(UUID, TEXT, NUMERIC, BOOLEAN) TO authenticated;


-- ════════════════════════════════════════════════════════════════════════════
-- RPC: request_extra_hours_client
-- El CLIENTE solicita horas extra desde la app.
-- Crea el registro y notifica al grupo para que confirme.
-- ════════════════════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION public.request_extra_hours_client(
  p_reservation_id UUID,
  p_hours          INT,
  p_total_cost     NUMERIC
)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_res         RECORD;
  v_commission  NUMERIC(12,2);
  v_group_earn  NUMERIC(12,2);
  v_extra_id    UUID;
  v_owner_id    UUID;
BEGIN
  SELECT r.*, g.owner_id AS group_owner_id
  INTO   v_res
  FROM   public.reservations r
  JOIN   public.groups g ON g.id = r.group_id
  WHERE  r.id = p_reservation_id;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'reservation_not_found');
  END IF;

  IF p_hours <= 0 OR p_total_cost <= 0 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_params');
  END IF;

  v_commission := ROUND(p_total_cost * 0.03, 2);
  v_group_earn := p_total_cost - v_commission;
  v_owner_id   := v_res.group_owner_id;

  INSERT INTO public.extra_hours (
    reservation_id, hours_added, price_per_hour,
    total_extra_cost, platform_commission, group_extra_earnings,
    status, client_confirmed_at
  ) VALUES (
    p_reservation_id,
    p_hours,
    ROUND(p_total_cost / p_hours, 2),
    p_total_cost,
    v_commission,
    v_group_earn,
    'client_requested',
    NOW()
  )
  RETURNING id INTO v_extra_id;

  -- Notificar al grupo para que confirme
  IF v_owner_id IS NOT NULL THEN
    INSERT INTO public.notifications (user_id, type, title, body, data)
    VALUES (
      v_owner_id,
      'extra_hours_request',
      '⏰ El cliente quiere ' || p_hours || ' hora' || CASE WHEN p_hours > 1 THEN 's' ELSE '' END || ' extra',
      'Confirma para continuar el servicio y ganar $' || v_group_earn::TEXT || ' MXN adicionales.',
      jsonb_build_object(
        'reservation_id', p_reservation_id,
        'extra_id',       v_extra_id,
        'hours',          p_hours,
        'total',          p_total_cost,
        'screen',         'EventTimer'
      )
    );
  END IF;

  RETURN jsonb_build_object(
    'ok',       true,
    'extra_id', v_extra_id,
    'hours',    p_hours,
    'total',    p_total_cost
  );

EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$$;

GRANT EXECUTE ON FUNCTION public.request_extra_hours_client(UUID, INT, NUMERIC) TO authenticated;


-- ════════════════════════════════════════════════════════════════════════════
-- RPC: group_confirm_extra_hours
-- El GRUPO confirma que continuará el servicio.
-- Descuenta la comisión del saldo retenido del grupo (pending_balance).
-- Libera la ganancia neta al grupo (available_balance).
-- Extiende el evento en la DB.
-- ════════════════════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION public.group_confirm_extra_hours(
  p_extra_id UUID
)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_extra      RECORD;
  v_res        RECORD;
  v_admin_id   UUID;
  v_owner_id   UUID;
  v_commission NUMERIC(12,2);
  v_net        NUMERIC(12,2);
BEGIN
  SELECT * INTO v_extra
  FROM   public.extra_hours
  WHERE  id = p_extra_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'extra_not_found');
  END IF;

  IF v_extra.status NOT IN ('pending', 'client_requested') THEN
    RETURN jsonb_build_object('ok', true, 'skipped', true, 'reason', 'already_processed');
  END IF;

  SELECT r.*, g.owner_id AS group_owner_id
  INTO   v_res
  FROM   public.reservations r
  JOIN   public.groups g ON g.id = r.group_id
  WHERE  r.id = v_extra.reservation_id;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'reservation_not_found');
  END IF;

  v_commission := v_extra.platform_commission;
  v_net        := v_extra.group_extra_earnings;
  v_admin_id   := public.get_platform_admin_id();
  v_owner_id   := v_res.group_owner_id;

  -- Actualizar estado de horas extra
  UPDATE public.extra_hours
  SET status            = 'accepted',
      group_confirmed_at = NOW()
  WHERE id = p_extra_id;

  -- Extender el evento: sumar horas al total
  UPDATE public.reservations
  SET extra_hours_added = COALESCE(extra_hours_added, 0) + v_extra.hours_added
  WHERE id = v_extra.reservation_id;

  -- ── Comisión: descontar del pending_balance del grupo ─────────────────
  -- (La comisión ya fue pagada por la app con el anticipo, pero para horas extra
  -- se descuenta del saldo retenido del grupo y se transfiere al admin)
  IF v_admin_id IS NOT NULL AND v_commission > 0 THEN
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
      (v_admin_id, v_commission, 'commission', 'completed', v_extra.reservation_id,
       'Comisión hora extra · evento ' || v_res.event_date::TEXT);
  END IF;

  -- ── Ganancia neta: disponible de inmediato para el grupo ──────────────
  IF v_owner_id IS NOT NULL AND v_net > 0 THEN
    INSERT INTO public.wallets (user_id) VALUES (v_owner_id)
      ON CONFLICT (user_id) DO NOTHING;

    -- Si el cliente paga en efectivo, descontar del pending y agregar a available
    -- Si se cobra por la app, se suma directo a available
    UPDATE public.wallets
    SET available_balance = available_balance + v_net,
        pending_balance   = GREATEST(0, pending_balance - v_commission),
        total_earned      = total_earned + v_net,
        updated_at        = NOW()
    WHERE user_id = v_owner_id;

    INSERT INTO public.wallet_transactions
      (user_id, amount, type, status, reference_event_id, description)
    VALUES
      (v_owner_id, v_net, 'extra_hour', 'completed', v_extra.reservation_id,
       'Hora extra confirmada · evento ' || v_res.event_date::TEXT);

    INSERT INTO public.financial_ledger
      (reservation_id, user_id, entry_type, amount, currency, description)
    VALUES
      (v_extra.reservation_id, v_owner_id, 'extra_hour', v_net, 'mxn',
       'Hora extra · evento ' || v_res.event_date::TEXT);

    -- Notificar al grupo
    INSERT INTO public.notifications (user_id, type, title, body, data)
    VALUES (v_owner_id, 'payment',
      '💰 Hora extra registrada',
      '+$' || v_net::TEXT || ' MXN en tu billetera por ' || v_extra.hours_added || 'h extra.',
      jsonb_build_object('reservation_id', v_extra.reservation_id, 'amount', v_net, 'screen', 'Wallet'));
  END IF;

  -- Notificar al cliente que el grupo confirmó
  IF v_res.client_id IS NOT NULL THEN
    INSERT INTO public.notifications (user_id, type, title, body, data)
    VALUES (v_res.client_id, 'reservation',
      '✅ ¡' || v_extra.hours_added || 'h extra confirmadas!',
      'El grupo confirmó que continuará el servicio. El timer se extendió.',
      jsonb_build_object(
        'reservation_id', v_extra.reservation_id,
        'hours_added',    v_extra.hours_added,
        'screen',         'LiveEvent'
      ));
  END IF;

  RETURN jsonb_build_object(
    'ok',          true,
    'extra_id',    p_extra_id,
    'hours_added', v_extra.hours_added,
    'commission',  v_commission,
    'net',         v_net
  );

EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$$;

GRANT EXECUTE ON FUNCTION public.group_confirm_extra_hours(UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION public.group_confirm_extra_hours(UUID) TO service_role;


SELECT '135_deposit_commission_and_extra_hours_confirm ✅' AS status;
