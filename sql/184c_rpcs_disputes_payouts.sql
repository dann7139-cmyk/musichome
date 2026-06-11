-- 184c_rpcs_disputes_payouts.sql
-- PASO 3/3: RPCs de disputas, retiros y batch.
-- Requiere que 184a y 184b ya estén aplicados.

-- ── RPC: open_dispute ─────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION open_dispute(
  p_reservation_id UUID,
  p_reason         TEXT
)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_caller_id   UUID := auth.uid();
  v_reservation RECORD;
  v_dispute_id  UUID;
BEGIN
  IF v_caller_id IS NULL THEN
    RAISE EXCEPTION 'unauthorized: sesión requerida';
  END IF;

  SELECT * INTO v_reservation FROM reservations WHERE id = p_reservation_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Reserva no encontrada'; END IF;

  IF v_reservation.client_id != v_caller_id THEN
    IF NOT EXISTS (
      SELECT 1 FROM groups WHERE id = v_reservation.group_id AND owner_id = v_caller_id
    ) THEN
      RAISE EXCEPTION 'unauthorized: no eres parte de esta reserva';
    END IF;
  END IF;

  IF EXISTS (
    SELECT 1 FROM disputes
    WHERE reservation_id = p_reservation_id AND status IN ('open','under_review')
  ) THEN
    RAISE EXCEPTION 'Ya existe una disputa abierta para esta reserva';
  END IF;

  INSERT INTO disputes (reservation_id, opened_by, reason, status)
  VALUES (p_reservation_id, v_caller_id, p_reason, 'open')
  RETURNING id INTO v_dispute_id;

  INSERT INTO notifications (user_id, type, title, body, data)
  SELECT id, 'dispute', '⚠️ Nueva disputa abierta',
    format('Se abrió una disputa para la reserva del %s.', v_reservation.event_date),
    jsonb_build_object('screen','Disputes','dispute_id',v_dispute_id,'reservation_id',p_reservation_id)
  FROM profiles WHERE role = 'admin';

  RETURN jsonb_build_object('ok', true, 'dispute_id', v_dispute_id);
END;
$$;

-- ── RPC: resolve_dispute ──────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION resolve_dispute(
  p_dispute_id      UUID,
  p_resolution      TEXT,
  p_resolution_note TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_caller_id   UUID := auth.uid();
  v_dispute     RECORD;
  v_reservation RECORD;
  v_wallet_id   UUID;
  v_earnings    NUMERIC;
BEGIN
  IF v_caller_id IS NULL THEN RAISE EXCEPTION 'unauthorized: sesión requerida'; END IF;

  IF NOT EXISTS (SELECT 1 FROM profiles WHERE id = v_caller_id AND role = 'admin') THEN
    RAISE EXCEPTION 'unauthorized: solo admins pueden resolver disputas';
  END IF;

  SELECT * INTO v_dispute FROM disputes WHERE id = p_dispute_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Disputa no encontrada'; END IF;

  IF v_dispute.status NOT IN ('open','under_review') THEN
    RAISE EXCEPTION 'Esta disputa ya fue resuelta';
  END IF;

  SELECT * INTO v_reservation FROM reservations WHERE id = v_dispute.reservation_id;

  UPDATE disputes
  SET
    status          = p_resolution,
    resolution_note = p_resolution_note,
    resolved_by     = v_caller_id,
    resolved_at     = NOW(),
    updated_at      = NOW()
  WHERE id = p_dispute_id;

  IF p_resolution = 'resolved_group' THEN
    PERFORM release_event_payment(v_dispute.reservation_id);
  END IF;

  IF p_resolution = 'resolved_client' THEN
    SELECT COALESCE(SUM(wt.amount), 0) INTO v_earnings
    FROM wallet_transactions wt
    WHERE wt.reservation_id = v_dispute.reservation_id AND wt.type = 'credit_pending';

    IF v_earnings > 0 THEN
      SELECT id INTO v_wallet_id FROM group_wallets WHERE group_id = v_reservation.group_id;

      UPDATE group_wallets
      SET pending_balance = GREATEST(0, pending_balance - v_earnings), updated_at = NOW()
      WHERE id = v_wallet_id;

      INSERT INTO wallet_transactions (
        group_wallet_id, group_id, type, amount, reservation_id,
        dispute_id, description, balance_after
      )
      SELECT
        gw.id, gw.group_id, 'refund_dispute', v_earnings, v_dispute.reservation_id,
        p_dispute_id,
        'Reembolso por disputa resuelta a favor del cliente',
        gw.pending_balance
      FROM group_wallets gw WHERE gw.id = v_wallet_id;
    END IF;
  END IF;

  INSERT INTO notifications (user_id, type, title, body, data)
  VALUES (
    v_reservation.client_id, 'dispute',
    CASE p_resolution WHEN 'resolved_client' THEN '✅ Disputa resuelta a tu favor' ELSE '❌ Disputa resuelta' END,
    p_resolution_note,
    jsonb_build_object('screen','Reservations','reservation_id',v_dispute.reservation_id)
  );

  RETURN jsonb_build_object('ok', true, 'resolution', p_resolution);
END;
$$;

-- ── RPC: request_payout ───────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION request_payout(
  p_amount        NUMERIC,
  p_payout_method TEXT    DEFAULT 'clabe',
  p_clabe         TEXT    DEFAULT NULL,
  p_bank_name     TEXT    DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_caller_id UUID := auth.uid();
  v_group_id  UUID;
  v_wallet    RECORD;
  v_payout_id UUID;
BEGIN
  IF v_caller_id IS NULL THEN RAISE EXCEPTION 'unauthorized: sesión requerida'; END IF;

  SELECT id INTO v_group_id FROM groups WHERE owner_id = v_caller_id LIMIT 1;
  IF v_group_id IS NULL THEN RAISE EXCEPTION 'No tienes un grupo registrado'; END IF;

  SELECT * INTO v_wallet FROM group_wallets WHERE group_id = v_group_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Wallet no encontrada'; END IF;

  IF v_wallet.available_balance < p_amount THEN
    RAISE EXCEPTION 'Saldo insuficiente: disponible=$%, solicitado=$%',
      v_wallet.available_balance, p_amount;
  END IF;

  IF p_amount < 100 THEN
    RAISE EXCEPTION 'El monto mínimo de retiro es $100 MXN';
  END IF;

  UPDATE group_wallets
  SET available_balance = available_balance - p_amount, updated_at = NOW()
  WHERE id = v_wallet.id;

  INSERT INTO payout_requests (group_id, group_wallet_id, amount, payout_method, clabe, bank_name)
  VALUES (v_group_id, v_wallet.id, p_amount, p_payout_method, p_clabe, p_bank_name)
  RETURNING id INTO v_payout_id;

  INSERT INTO wallet_transactions (
    group_wallet_id, group_id, type, amount,
    payout_request_id, description, balance_after
  ) VALUES (
    v_wallet.id, v_group_id, 'debit_payout', p_amount,
    v_payout_id,
    format('Solicitud de retiro $%s MXN', p_amount),
    v_wallet.available_balance - p_amount
  );

  INSERT INTO notifications (user_id, type, title, body, data)
  SELECT id, 'payout', '💸 Nueva solicitud de retiro',
    format('Un grupo solicitó retirar $%s MXN.', to_char(p_amount,'FM999,999,990')),
    jsonb_build_object('screen','Withdrawals','payout_request_id',v_payout_id)
  FROM profiles WHERE role = 'admin';

  RETURN jsonb_build_object('ok', true, 'payout_request_id', v_payout_id, 'amount', p_amount);
END;
$$;

-- ── RPC: approve_payout ───────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION approve_payout(
  p_payout_request_id UUID,
  p_admin_note        TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_caller_id UUID := auth.uid();
  v_payout    RECORD;
BEGIN
  IF v_caller_id IS NULL THEN RAISE EXCEPTION 'unauthorized: sesión requerida'; END IF;

  IF NOT EXISTS (SELECT 1 FROM profiles WHERE id = v_caller_id AND role = 'admin') THEN
    RAISE EXCEPTION 'unauthorized: solo admins pueden aprobar retiros';
  END IF;

  SELECT * INTO v_payout FROM payout_requests WHERE id = p_payout_request_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Solicitud no encontrada'; END IF;

  IF v_payout.status != 'pending' THEN
    RAISE EXCEPTION 'Esta solicitud ya fue procesada (status: %)', v_payout.status;
  END IF;

  UPDATE payout_requests
  SET status = 'approved', approved_at = NOW(), admin_note = p_admin_note, updated_at = NOW()
  WHERE id = p_payout_request_id;

  INSERT INTO notifications (user_id, type, title, body, data)
  SELECT g.owner_id, 'payout', '✅ Retiro aprobado',
    format('Tu retiro de $%s MXN fue aprobado. Llegará pronto a tu cuenta.',
      to_char(v_payout.amount,'FM999,999,990')),
    jsonb_build_object('screen','Wallet','payout_request_id',p_payout_request_id)
  FROM groups g WHERE g.id = v_payout.group_id;

  RETURN jsonb_build_object('ok', true, 'payout_request_id', p_payout_request_id);
END;
$$;

-- ── RPC: get_group_wallet_summary ─────────────────────────────────────────────

CREATE OR REPLACE FUNCTION get_group_wallet_summary(p_group_id UUID DEFAULT NULL)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_caller_id       UUID := auth.uid();
  v_group_id        UUID;
  v_wallet          RECORD;
  v_recent          JSONB;
  v_pending_payouts NUMERIC;
BEGIN
  IF v_caller_id IS NULL THEN RAISE EXCEPTION 'unauthorized: sesión requerida'; END IF;

  IF p_group_id IS NOT NULL THEN
    IF NOT EXISTS (SELECT 1 FROM profiles WHERE id = v_caller_id AND role = 'admin') THEN
      RAISE EXCEPTION 'unauthorized: solo admins pueden ver wallets de otros grupos';
    END IF;
    v_group_id := p_group_id;
  ELSE
    SELECT id INTO v_group_id FROM groups WHERE owner_id = v_caller_id LIMIT 1;
    IF v_group_id IS NULL THEN RAISE EXCEPTION 'No tienes un grupo registrado'; END IF;
  END IF;

  PERFORM ensure_group_wallet(v_group_id);
  SELECT * INTO v_wallet FROM group_wallets WHERE group_id = v_group_id;

  SELECT COALESCE(jsonb_agg(t ORDER BY t.created_at DESC), '[]') INTO v_recent
  FROM (
    SELECT id, type, amount, description, reservation_id, created_at, balance_after
    FROM wallet_transactions
    WHERE group_id = v_group_id
    ORDER BY created_at DESC LIMIT 10
  ) t;

  SELECT COALESCE(SUM(amount), 0) INTO v_pending_payouts
  FROM payout_requests
  WHERE group_id = v_group_id AND status IN ('pending','approved');

  RETURN jsonb_build_object(
    'pending_balance',     v_wallet.pending_balance,
    'available_balance',   v_wallet.available_balance,
    'total_earned',        v_wallet.total_earned,
    'pending_payouts',     v_pending_payouts,
    'recent_transactions', v_recent
  );
END;
$$;

-- ── RPC: release_all_eligible_payments ────────────────────────────────────────

CREATE OR REPLACE FUNCTION release_all_eligible_payments()
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_row      RECORD;
  v_released INT := 0;
  v_skipped  INT := 0;
  v_result   JSONB;
BEGIN
  FOR v_row IN
    SELECT r.id
    FROM reservations r
    WHERE r.payment_status IN ('paid','fully_paid','deposit_paid')
      AND r.wallet_released_at IS NULL
      AND r.event_date IS NOT NULL
      AND (r.event_date::TIMESTAMPTZ + INTERVAL '48 hours') < NOW()
      AND NOT EXISTS (
        SELECT 1 FROM disputes d
        WHERE d.reservation_id = r.id AND d.status IN ('open','under_review')
      )
    FOR UPDATE SKIP LOCKED
  LOOP
    v_result := release_event_payment(v_row.id);
    IF (v_result->>'ok')::BOOLEAN THEN
      v_released := v_released + 1;
    ELSE
      v_skipped := v_skipped + 1;
    END IF;
  END LOOP;

  RETURN jsonb_build_object('ok', true, 'released', v_released, 'skipped', v_skipped);
END;
$$;
