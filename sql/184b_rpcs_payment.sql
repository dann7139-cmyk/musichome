-- 184b_rpcs_payment.sql
-- PASO 2/3: RPCs de pago — confirm_full_payment_and_credit_wallet + release_event_payment.
-- Requiere que 184a ya esté aplicado.

-- ── RPC: confirm_full_payment_and_credit_wallet ───────────────────────────────

CREATE OR REPLACE FUNCTION confirm_full_payment_and_credit_wallet(
  p_reservation_id UUID,
  p_mp_payment_id  TEXT,
  p_amount_paid    NUMERIC DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_reservation RECORD;
  v_wallet_id   UUID;
  v_group_id    UUID;
  v_earnings    NUMERIC;
  v_new_pending NUMERIC;
BEGIN
  SELECT * INTO v_reservation
  FROM reservations WHERE id = p_reservation_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Reserva no encontrada: %', p_reservation_id;
  END IF;

  IF v_reservation.payment_status IN ('paid', 'fully_paid') THEN
    RETURN jsonb_build_object('ok', true, 'skipped', true, 'reason', 'already_paid');
  END IF;

  IF v_reservation.mp_payment_id IS NOT NULL AND v_reservation.mp_payment_id != p_mp_payment_id THEN
    RETURN jsonb_build_object('ok', false, 'error', 'payment_id_mismatch');
  END IF;

  v_group_id := v_reservation.group_id;
  v_earnings := COALESCE(
    v_reservation.group_earnings,
    (v_reservation.total_price * 0.9)::NUMERIC(14,2)
  );

  UPDATE reservations
  SET
    payment_status           = 'paid',
    status                   = CASE WHEN status = 'pending' THEN 'confirmed' ELSE status END,
    mp_payment_id            = p_mp_payment_id,
    client_available_balance = v_earnings,
    updated_at               = NOW()
  WHERE id = p_reservation_id;

  v_wallet_id := ensure_group_wallet(v_group_id);

  UPDATE group_wallets
  SET
    pending_balance = pending_balance + v_earnings,
    total_earned    = total_earned    + v_earnings,
    updated_at      = NOW()
  WHERE id = v_wallet_id
  RETURNING pending_balance INTO v_new_pending;

  INSERT INTO wallet_transactions (
    group_wallet_id, group_id, type, amount, reservation_id,
    mp_payment_id, description, balance_after
  ) VALUES (
    v_wallet_id, v_group_id, 'credit_pending', v_earnings, p_reservation_id,
    p_mp_payment_id,
    format('Pago completo recibido – Reserva %s', p_reservation_id),
    v_new_pending
  );

  INSERT INTO financial_audit_logs (
    actor_id, action, amount, reservation_id, payment_intent_id,
    before_balance, after_balance
  ) VALUES (
    NULL, 'full_payment_confirmed', v_earnings, p_reservation_id,
    p_mp_payment_id,
    v_new_pending - v_earnings,
    v_new_pending
  );

  RETURN jsonb_build_object(
    'ok',              true,
    'skipped',         false,
    'group_earnings',  v_earnings,
    'pending_balance', v_new_pending
  );
END;
$$;

-- ── RPC: release_event_payment ────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION release_event_payment(p_reservation_id UUID)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_reservation   RECORD;
  v_wallet_id     UUID;
  v_earnings      NUMERIC;
  v_new_available NUMERIC;
  v_has_dispute   BOOLEAN;
BEGIN
  SELECT * INTO v_reservation
  FROM reservations WHERE id = p_reservation_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Reserva no encontrada: %', p_reservation_id;
  END IF;

  IF v_reservation.payment_status NOT IN ('paid', 'fully_paid', 'deposit_paid') THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'not_paid');
  END IF;

  IF v_reservation.event_date IS NOT NULL AND
     (v_reservation.event_date::TIMESTAMPTZ + INTERVAL '48 hours') > NOW() THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'event_not_completed');
  END IF;

  SELECT EXISTS (
    SELECT 1 FROM disputes
    WHERE reservation_id = p_reservation_id AND status IN ('open','under_review')
  ) INTO v_has_dispute;

  IF v_has_dispute THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'dispute_open');
  END IF;

  SELECT gw.id, gw.pending_balance
  INTO v_wallet_id, v_earnings
  FROM group_wallets gw
  WHERE gw.group_id = v_reservation.group_id;

  IF NOT FOUND OR v_earnings <= 0 THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'no_pending_balance');
  END IF;

  SELECT COALESCE(SUM(wt.amount), 0) INTO v_earnings
  FROM wallet_transactions wt
  WHERE wt.reservation_id = p_reservation_id AND wt.type = 'credit_pending';

  IF v_earnings <= 0 THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'no_transaction_found');
  END IF;

  UPDATE group_wallets
  SET
    pending_balance   = GREATEST(0, pending_balance - v_earnings),
    available_balance = available_balance + v_earnings,
    updated_at        = NOW()
  WHERE group_id = v_reservation.group_id
  RETURNING available_balance INTO v_new_available;

  UPDATE reservations SET wallet_released_at = NOW() WHERE id = p_reservation_id;

  INSERT INTO wallet_transactions (
    group_wallet_id, group_id, type, amount, reservation_id,
    description, balance_after
  ) VALUES (
    v_wallet_id, v_reservation.group_id, 'release_to_available', v_earnings, p_reservation_id,
    format('Pago liberado post-evento – Reserva %s', p_reservation_id),
    v_new_available
  );

  INSERT INTO financial_audit_logs (
    action, amount, reservation_id, before_balance, after_balance
  ) VALUES (
    'payment_released', v_earnings, p_reservation_id,
    v_new_available - v_earnings, v_new_available
  );

  INSERT INTO notifications (user_id, type, title, body, data)
  SELECT
    g.owner_id, 'wallet', '💰 Pago liberado a tu billetera',
    format('$%s MXN están disponibles para retiro por tu evento del %s.',
      to_char(v_earnings, 'FM999,999,990.00'), v_reservation.event_date),
    jsonb_build_object('screen', 'Wallet', 'reservation_id', p_reservation_id)
  FROM groups g WHERE g.id = v_reservation.group_id;

  RETURN jsonb_build_object(
    'ok',                true,
    'released_amount',   v_earnings,
    'available_balance', v_new_available
  );
END;
$$;
