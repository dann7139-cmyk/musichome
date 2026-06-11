-- ════════════════════════════════════════════════════════════════════
-- 63_mp_pending_flow.sql
-- Flujo de saldos pendientes con MercadoPago:
--
-- 1. mp_credit_pending_earnings  → cuando MP aprueba el pago
--    Acredita pending_balance a cada participante (dueño + integrantes)
--    según la distribución de event_payouts.
--
-- 2. distribute_event_earnings   → cuando termina el evento
--    RUTA A (flujo MP):  mueve pending_balance → available_balance
--    RUTA B (legacy):    acredita directo desde event_payouts
--
-- Ejecutar DESPUÉS de 59, 60, 61 y 62.
-- ════════════════════════════════════════════════════════════════════

-- Columna idempotencia para el crédito pendiente
ALTER TABLE public.reservations
  ADD COLUMN IF NOT EXISTS wallet_pending_credited BOOLEAN NOT NULL DEFAULT FALSE;

-- ════════════════════════════════════════════════════════════════════
-- RPC 1: mp_credit_pending_earnings
-- Llamada desde el webhook de MercadoPago cuando el pago es aprobado.
-- ════════════════════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION public.mp_credit_pending_earnings(
  p_reservation_id UUID,
  p_payment_id     TEXT,
  p_amount_paid    NUMERIC DEFAULT NULL   -- monto recibido en este pago (opcional)
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
  v_credited   INT := 0;
BEGIN
  -- Bloquear fila para evitar doble ejecución concurrente
  SELECT * INTO v_res
  FROM   public.reservations
  WHERE  id = p_reservation_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'reservation_not_found');
  END IF;

  -- Idempotencia
  IF v_res.wallet_pending_credited THEN
    RETURN jsonb_build_object('ok', true, 'skipped', true, 'reason', 'already_pending_credited');
  END IF;

  -- Actualizar reserva: pago recibido
  UPDATE public.reservations
  SET payment_status          = 'deposit_paid',
      mp_payment_id           = p_payment_id,
      wallet_pending_credited = TRUE
  WHERE id = p_reservation_id;

  -- Comisión 8% sobre precio total del evento
  v_commission := ROUND(v_res.total_price * 0.08, 2);
  v_group_net  := v_res.total_price - v_commission;

  -- Distribuir pending_balance según event_payouts
  FOR v_payout IN
    SELECT ep.user_id, ep.amount, ep.role
    FROM   public.event_payouts ep
    WHERE  ep.reservation_id = p_reservation_id
      AND  ep.payout_status  = 'pending'
      AND  ep.amount         > 0
  LOOP
    -- Crear wallet si no existe
    INSERT INTO public.wallets (user_id)
    VALUES (v_payout.user_id)
    ON CONFLICT (user_id) DO NOTHING;

    -- Acreditar saldo pendiente
    UPDATE public.wallets
    SET pending_balance = pending_balance + v_payout.amount,
        updated_at      = NOW()
    WHERE user_id = v_payout.user_id;

    -- Registrar transacción como pendiente
    INSERT INTO public.wallet_transactions
      (user_id, amount, type, status, reference_event_id, description)
    VALUES
      (v_payout.user_id,
       v_payout.amount,
       'event_earning',
       'pending',
       p_reservation_id,
       'Ganancia en espera · evento ' || v_res.event_date::TEXT || ' (' || v_payout.role || ')');

    -- Notificar al participante
    INSERT INTO public.notifications
      (user_id, type, title, body, data)
    VALUES
      (v_payout.user_id,
       'payment',
       '⏳ Dinero reservado para ti',
       'Tienes $' || v_payout.amount::TEXT ||
       ' MXN reservados. Se liberarán en tu billetera cuando termine el evento.',
       jsonb_build_object(
         'reservation_id', p_reservation_id,
         'amount',         v_payout.amount,
         'screen',         'Wallet'
       ));

    v_credited := v_credited + 1;
  END LOOP;

  -- Fallback: sin event_payouts → todo al dueño del grupo
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
        (v_owner_id, v_group_net, 'event_earning', 'pending',
         p_reservation_id,
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
    'ok',          true,
    'credited',    v_credited,
    'total',       v_res.total_price,
    'commission',  v_commission,
    'group_net',   v_group_net
  );

EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$$;

GRANT EXECUTE ON FUNCTION public.mp_credit_pending_earnings(UUID, TEXT, NUMERIC) TO service_role;

-- ════════════════════════════════════════════════════════════════════
-- RPC 2: distribute_event_earnings  (reemplazo de 61)
-- Cuando el evento termina:
--   RUTA A (flujo MP)    → mueve pending_balance → available_balance
--   RUTA B (legacy/directo) → acredita desde event_payouts
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

  -- Marcar el evento como completado
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

  -- Registrar comisión de plataforma
  INSERT INTO public.financial_ledger
    (reservation_id, entry_type, amount, currency, description)
  VALUES
    (p_reservation_id, 'platform_commission', v_commission, 'mxn',
     'Comisión 8% – evento ' || v_res.event_date::TEXT);

  -- ── ¿Existen transacciones pendientes? (flujo MercadoPago) ──────────────
  SELECT EXISTS (
    SELECT 1
    FROM   public.wallet_transactions
    WHERE  reference_event_id = p_reservation_id
      AND  type               = 'event_earning'
      AND  status             = 'pending'
  ) INTO v_has_pending;

  -- ── RUTA A: mover pending_balance → available_balance ────────────────────
  IF v_has_pending THEN
    FOR v_tx IN
      SELECT id, user_id, amount
      FROM   public.wallet_transactions
      WHERE  reference_event_id = p_reservation_id
        AND  type               = 'event_earning'
        AND  status             = 'pending'
    LOOP
      UPDATE public.wallets
      SET available_balance = available_balance + v_tx.amount,
          pending_balance   = GREATEST(0, pending_balance - v_tx.amount),
          total_earned      = total_earned + v_tx.amount,
          updated_at        = NOW()
      WHERE user_id = v_tx.user_id;

      UPDATE public.wallet_transactions
      SET status      = 'completed',
          description = REGEXP_REPLACE(description, 'en espera', 'liberada')
      WHERE id = v_tx.id;

      UPDATE public.event_payouts
      SET payout_status = 'paid'
      WHERE reservation_id = p_reservation_id
        AND user_id        = v_tx.user_id;

      INSERT INTO public.financial_ledger
        (reservation_id, user_id, entry_type, amount, currency, description)
      VALUES
        (p_reservation_id, v_tx.user_id, 'group_transfer', v_tx.amount, 'mxn',
         'Liberación de ganancia – evento ' || v_res.event_date::TEXT);

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

      v_distributed := v_distributed + 1;
    END LOOP;

  -- ── RUTA B: acreditar directo desde event_payouts (legacy) ───────────────
  ELSE
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
           WHEN 'owner'   THEN 'group_transfer'
           WHEN 'member'  THEN 'member_transfer'
           ELSE                'talent_transfer'
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
         '💰 Pago agregado a tu billetera',
         'Tu pago del evento ha sido agregado a tu billetera.',
         jsonb_build_object(
           'reservation_id', p_reservation_id,
           'amount',         v_payout.amount,
           'screen',         'Wallet'
         ));

      v_distributed := v_distributed + 1;
    END LOOP;

    -- Sin event_payouts → todo al dueño
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
           p_reservation_id,
           'Ganancia evento ' || v_res.event_date::TEXT || ' (owner)');
        INSERT INTO public.financial_ledger
          (reservation_id, user_id, entry_type, amount, currency, description)
        VALUES
          (p_reservation_id, v_owner_id, 'group_transfer', v_group_net, 'mxn',
           'Pago evento ' || v_res.event_date::TEXT);
        INSERT INTO public.notifications
          (user_id, type, title, body, data)
        VALUES
          (v_owner_id, 'payment',
           '💰 Pago agregado a tu billetera',
           'Tu pago del evento ha sido agregado a tu billetera.',
           jsonb_build_object(
             'reservation_id', p_reservation_id,
             'amount',         v_group_net,
             'screen',         'Wallet'
           ));
        v_distributed := 1;
      END IF;
    END IF;
  END IF;

  -- Notificar a administradores
  INSERT INTO public.notifications
    (user_id, type, title, body, data)
  SELECT
    p.id, 'payment',
    '📊 Evento completado — comisión $' || v_commission::TEXT,
    'El evento del ' || v_res.event_date::TEXT ||
    ' fue completado. Comisión plataforma: $' || v_commission::TEXT || ' MXN.',
    jsonb_build_object('reservation_id', p_reservation_id, 'commission', v_commission)
  FROM public.profiles p
  WHERE p.role = 'admin';

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

SELECT '63_mp_pending_flow: mp_credit_pending_earnings + distribute_event_earnings (pending→available) ✅' AS status;
