-- ─────────────────────────────────────────────────────────────────────────────
-- 184_wallet_disputes.sql
-- Infraestructura de wallets profesionales, disputas y pago completo.
--
--  1.  payment_mode en reservations (full / deposit — backward compat)
--  2.  group_wallets — saldo por grupo (pending → available)
--  3.  wallet_transactions — historial inmutable de movimientos
--  4.  payout_requests — solicitudes de retiro
--  5.  disputes / dispute_messages / dispute_evidence
--  6.  RPC confirm_full_payment_and_credit_wallet  (webhook MP)
--  7.  RPC release_event_payment  (cron o manual por admin)
--  8.  RPC open_dispute / resolve_dispute
--  9.  RPC request_payout / approve_payout
-- 10.  RPC get_group_wallet_summary
-- 11.  Notificaciones: wallet y disputas
-- 12.  Índices de performance
-- ─────────────────────────────────────────────────────────────────────────────

-- ── 1. payment_mode en reservations ──────────────────────────────────────────

ALTER TABLE reservations
  ADD COLUMN IF NOT EXISTS payment_mode TEXT DEFAULT 'full'
    CONSTRAINT chk_payment_mode CHECK (payment_mode IN ('full', 'deposit'));

-- Las reservas existentes que ya tenían lógica de depósito quedan como 'deposit'.
-- Nuevas reservas serán 'full' por defecto.
UPDATE reservations
SET payment_mode = 'deposit'
WHERE payment_mode = 'full'
  AND (payment_status IN ('deposit_paid', 'deposit_pending') OR mp_preference_id IS NOT NULL)
  AND created_at < NOW();

-- ── 2. group_wallets ──────────────────────────────────────────────────────────
--
-- Una wallet por grupo. pending_balance = pagado pero en retención.
-- available_balance = liberado y retirable.
-- total_earned = acumulado histórico (nunca decrece).

CREATE TABLE IF NOT EXISTS group_wallets (
  id                UUID        DEFAULT gen_random_uuid() PRIMARY KEY,
  group_id          UUID        REFERENCES groups(id) ON DELETE CASCADE UNIQUE NOT NULL,
  pending_balance   NUMERIC(14,2) DEFAULT 0 NOT NULL CHECK (pending_balance   >= 0),
  available_balance NUMERIC(14,2) DEFAULT 0 NOT NULL CHECK (available_balance >= 0),
  total_earned      NUMERIC(14,2) DEFAULT 0 NOT NULL CHECK (total_earned      >= 0),
  created_at        TIMESTAMPTZ DEFAULT NOW(),
  updated_at        TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_group_wallets_group_id ON group_wallets(group_id);

ALTER TABLE group_wallets ENABLE ROW LEVEL SECURITY;

-- Owner del grupo ve su wallet; admin ve todas
DROP POLICY IF EXISTS gw_owner_select ON group_wallets;
CREATE POLICY gw_owner_select ON group_wallets
  FOR SELECT
  USING (
    group_id IN (SELECT id FROM groups WHERE owner_id = auth.uid())
    OR EXISTS (SELECT 1 FROM profiles WHERE id = auth.uid() AND role = 'admin')
  );

-- Solo funciones SECURITY DEFINER modifican la wallet
DROP POLICY IF EXISTS gw_no_direct_write ON group_wallets;
CREATE POLICY gw_no_direct_write ON group_wallets
  FOR ALL
  USING (FALSE);

-- Función auxiliar: crear wallet si no existe
CREATE OR REPLACE FUNCTION ensure_group_wallet(p_group_id UUID)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_wallet_id UUID;
BEGIN
  INSERT INTO group_wallets (group_id)
  VALUES (p_group_id)
  ON CONFLICT (group_id) DO NOTHING;

  SELECT id INTO v_wallet_id FROM group_wallets WHERE group_id = p_group_id;
  RETURN v_wallet_id;
END;
$$;

-- ── 3. wallet_transactions ────────────────────────────────────────────────────
--
-- Historial inmutable. Cada cambio de saldo genera una fila.
-- type: credit_pending | release_to_available | debit_payout | refund_dispute

CREATE TABLE IF NOT EXISTS wallet_transactions (
  id               UUID        DEFAULT gen_random_uuid() PRIMARY KEY,
  group_wallet_id  UUID        REFERENCES group_wallets(id) ON DELETE CASCADE NOT NULL,
  group_id         UUID        REFERENCES groups(id) NOT NULL,
  type             TEXT        NOT NULL
    CONSTRAINT chk_wt_type CHECK (
      type IN ('credit_pending','release_to_available','debit_payout','refund_dispute','adjustment')
    ),
  amount           NUMERIC(14,2) NOT NULL CHECK (amount > 0),
  reservation_id   UUID        REFERENCES reservations(id),
  payout_request_id UUID,
  dispute_id       UUID,
  mp_payment_id    TEXT,
  description      TEXT,
  balance_after    NUMERIC(14,2) NOT NULL,
  created_at       TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_wt_wallet      ON wallet_transactions(group_wallet_id);
CREATE INDEX IF NOT EXISTS idx_wt_group       ON wallet_transactions(group_id);
CREATE INDEX IF NOT EXISTS idx_wt_reservation ON wallet_transactions(reservation_id);
CREATE INDEX IF NOT EXISTS idx_wt_created_at  ON wallet_transactions(created_at DESC);

ALTER TABLE wallet_transactions ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS wt_owner_select ON wallet_transactions;
CREATE POLICY wt_owner_select ON wallet_transactions
  FOR SELECT
  USING (
    group_id IN (SELECT id FROM groups WHERE owner_id = auth.uid())
    OR EXISTS (SELECT 1 FROM profiles WHERE id = auth.uid() AND role = 'admin')
  );

DROP POLICY IF EXISTS wt_no_direct_write ON wallet_transactions;
CREATE POLICY wt_no_direct_write ON wallet_transactions
  FOR ALL
  USING (FALSE);

-- ── 4. payout_requests ────────────────────────────────────────────────────────
--
-- Solicitudes de retiro de grupos. El admin aprueba manualmente o
-- un proceso automático vía Stripe Connect / SPEI.

CREATE TABLE IF NOT EXISTS payout_requests (
  id                UUID        DEFAULT gen_random_uuid() PRIMARY KEY,
  group_id          UUID        REFERENCES groups(id) ON DELETE CASCADE NOT NULL,
  group_wallet_id   UUID        REFERENCES group_wallets(id) NOT NULL,
  amount            NUMERIC(14,2) NOT NULL CHECK (amount > 0),
  status            TEXT        DEFAULT 'pending'
    CONSTRAINT chk_pr_status CHECK (status IN ('pending','approved','paid','rejected')),
  clabe             TEXT,
  bank_name         TEXT,
  stripe_account_id TEXT,
  payout_method     TEXT        DEFAULT 'clabe'
    CONSTRAINT chk_pr_method CHECK (payout_method IN ('clabe','stripe')),
  admin_note        TEXT,
  approved_at       TIMESTAMPTZ,
  paid_at           TIMESTAMPTZ,
  created_at        TIMESTAMPTZ DEFAULT NOW(),
  updated_at        TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_pr_group  ON payout_requests(group_id);
CREATE INDEX IF NOT EXISTS idx_pr_status ON payout_requests(status);

ALTER TABLE payout_requests ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS pr_owner_select ON payout_requests;
CREATE POLICY pr_owner_select ON payout_requests
  FOR SELECT
  USING (
    group_id IN (SELECT id FROM groups WHERE owner_id = auth.uid())
    OR EXISTS (SELECT 1 FROM profiles WHERE id = auth.uid() AND role = 'admin')
  );

DROP POLICY IF EXISTS pr_no_direct_write ON payout_requests;
CREATE POLICY pr_no_direct_write ON payout_requests
  FOR ALL
  USING (FALSE);

-- ── 5. disputes / dispute_messages / dispute_evidence ─────────────────────────

CREATE TABLE IF NOT EXISTS disputes (
  id                UUID        DEFAULT gen_random_uuid() PRIMARY KEY,
  reservation_id    UUID        REFERENCES reservations(id) ON DELETE CASCADE NOT NULL,
  opened_by         UUID        REFERENCES auth.users(id) NOT NULL,
  status            TEXT        DEFAULT 'open'
    CONSTRAINT chk_disp_status CHECK (status IN ('open','under_review','resolved_client','resolved_group','closed')),
  reason            TEXT        NOT NULL,
  resolution_note   TEXT,
  resolved_by       UUID        REFERENCES auth.users(id),
  resolved_at       TIMESTAMPTZ,
  created_at        TIMESTAMPTZ DEFAULT NOW(),
  updated_at        TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_disp_reservation ON disputes(reservation_id);
CREATE INDEX IF NOT EXISTS idx_disp_status      ON disputes(status);

ALTER TABLE disputes ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS disp_participant_select ON disputes;
CREATE POLICY disp_participant_select ON disputes
  FOR SELECT
  USING (
    opened_by = auth.uid()
    OR reservation_id IN (
      SELECT r.id FROM reservations r
      JOIN groups g ON g.id = r.group_id
      WHERE r.client_id = auth.uid() OR g.owner_id = auth.uid()
    )
    OR EXISTS (SELECT 1 FROM profiles WHERE id = auth.uid() AND role = 'admin')
  );

-- ────────────────────────────────────────
CREATE TABLE IF NOT EXISTS dispute_messages (
  id          UUID        DEFAULT gen_random_uuid() PRIMARY KEY,
  dispute_id  UUID        REFERENCES disputes(id) ON DELETE CASCADE NOT NULL,
  sender_id   UUID        REFERENCES auth.users(id) NOT NULL,
  body        TEXT        NOT NULL,
  is_internal BOOLEAN     DEFAULT FALSE,
  created_at  TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_dm_dispute    ON dispute_messages(dispute_id);
CREATE INDEX IF NOT EXISTS idx_dm_created_at ON dispute_messages(created_at);

ALTER TABLE dispute_messages ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS dm_select ON dispute_messages;
CREATE POLICY dm_select ON dispute_messages
  FOR SELECT
  USING (
    dispute_id IN (
      SELECT d.id FROM disputes d
      JOIN reservations r ON r.id = d.reservation_id
      JOIN groups g ON g.id = r.group_id
      WHERE r.client_id = auth.uid() OR g.owner_id = auth.uid() OR d.opened_by = auth.uid()
    )
    OR EXISTS (SELECT 1 FROM profiles WHERE id = auth.uid() AND role = 'admin')
  );

DROP POLICY IF EXISTS dm_insert ON dispute_messages;
CREATE POLICY dm_insert ON dispute_messages
  FOR INSERT
  WITH CHECK (
    sender_id = auth.uid()
    AND (
      dispute_id IN (
        SELECT d.id FROM disputes d
        JOIN reservations r ON r.id = d.reservation_id
        JOIN groups g ON g.id = r.group_id
        WHERE r.client_id = auth.uid() OR g.owner_id = auth.uid() OR d.opened_by = auth.uid()
      )
      OR EXISTS (SELECT 1 FROM profiles WHERE id = auth.uid() AND role = 'admin')
    )
  );

-- ────────────────────────────────────────
CREATE TABLE IF NOT EXISTS dispute_evidence (
  id          UUID        DEFAULT gen_random_uuid() PRIMARY KEY,
  dispute_id  UUID        REFERENCES disputes(id) ON DELETE CASCADE NOT NULL,
  uploaded_by UUID        REFERENCES auth.users(id) NOT NULL,
  file_path   TEXT        NOT NULL,
  description TEXT,
  created_at  TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_de_dispute ON dispute_evidence(dispute_id);

ALTER TABLE dispute_evidence ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS de_select ON dispute_evidence;
CREATE POLICY de_select ON dispute_evidence
  FOR SELECT
  USING (
    dispute_id IN (
      SELECT d.id FROM disputes d
      JOIN reservations r ON r.id = d.reservation_id
      JOIN groups g ON g.id = r.group_id
      WHERE r.client_id = auth.uid() OR g.owner_id = auth.uid() OR d.opened_by = auth.uid()
    )
    OR EXISTS (SELECT 1 FROM profiles WHERE id = auth.uid() AND role = 'admin')
  );

DROP POLICY IF EXISTS de_insert ON dispute_evidence;
CREATE POLICY de_insert ON dispute_evidence
  FOR INSERT
  WITH CHECK (
    uploaded_by = auth.uid()
    AND dispute_id IN (
      SELECT d.id FROM disputes d
      JOIN reservations r ON r.id = d.reservation_id
      JOIN groups g ON g.id = r.group_id
      WHERE r.client_id = auth.uid() OR g.owner_id = auth.uid() OR d.opened_by = auth.uid()
    )
  );

-- ── 6. RPC: confirm_full_payment_and_credit_wallet ────────────────────────────
--
-- Llamado por mercadopago-webhook cuando payment.status = 'approved'.
-- • Marca la reserva como pagada (payment_status = 'paid', status = 'confirmed')
-- • Acredita group_earnings en pending_balance de la wallet del grupo
-- • Registra auditoría
-- • Idempotente: si ya fue procesado, retorna {ok:true, skipped:true}

CREATE OR REPLACE FUNCTION confirm_full_payment_and_credit_wallet(
  p_reservation_id UUID,
  p_mp_payment_id  TEXT,
  p_amount_paid    NUMERIC DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_reservation RECORD;
  v_wallet_id   UUID;
  v_group_id    UUID;
  v_earnings    NUMERIC;
  v_new_pending NUMERIC;
BEGIN
  -- Bloquear reserva para evitar doble procesamiento
  SELECT * INTO v_reservation
  FROM reservations
  WHERE id = p_reservation_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Reserva no encontrada: %', p_reservation_id;
  END IF;

  -- Idempotencia: si ya fue pagado, retornar sin error
  IF v_reservation.payment_status IN ('paid', 'fully_paid') THEN
    RETURN jsonb_build_object('ok', true, 'skipped', true, 'reason', 'already_paid');
  END IF;

  -- Idempotencia por mp_payment_id (UNIQUE constraint)
  IF v_reservation.mp_payment_id IS NOT NULL AND v_reservation.mp_payment_id != p_mp_payment_id THEN
    RETURN jsonb_build_object('ok', false, 'error', 'payment_id_mismatch');
  END IF;

  v_group_id := v_reservation.group_id;
  v_earnings := COALESCE(
    v_reservation.group_earnings,
    (v_reservation.total_price * 0.9)::NUMERIC(14,2)
  );

  -- Actualizar reserva
  UPDATE reservations
  SET
    payment_status           = 'paid',
    status                   = CASE WHEN status = 'pending' THEN 'confirmed' ELSE status END,
    mp_payment_id            = p_mp_payment_id,
    client_available_balance = v_earnings,  -- cliente puede usar para horas extra
    updated_at               = NOW()
  WHERE id = p_reservation_id;

  -- Asegurar que el grupo tiene wallet
  v_wallet_id := ensure_group_wallet(v_group_id);

  -- Acreditar pending_balance (dinero en retención hasta que se libere)
  UPDATE group_wallets
  SET
    pending_balance = pending_balance + v_earnings,
    total_earned    = total_earned    + v_earnings,
    updated_at      = NOW()
  WHERE id = v_wallet_id
  RETURNING pending_balance INTO v_new_pending;

  -- Registrar transacción
  INSERT INTO wallet_transactions (
    group_wallet_id, group_id, type, amount, reservation_id,
    mp_payment_id, description, balance_after
  ) VALUES (
    v_wallet_id, v_group_id, 'credit_pending', v_earnings, p_reservation_id,
    p_mp_payment_id,
    format('Pago completo recibido – Reserva %s', p_reservation_id),
    v_new_pending
  );

  -- Auditoría financiera
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

-- ── 7. RPC: release_event_payment ─────────────────────────────────────────────
--
-- Libera el pending_balance → available_balance después de que el evento ocurrió.
-- Se llama desde un cron (diariamente) o manualmente por el admin.
-- Protección: no libera si hay disputa abierta.
-- Período de retención: 48 horas después del event_date.

CREATE OR REPLACE FUNCTION release_event_payment(p_reservation_id UUID)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_reservation   RECORD;
  v_wallet_id     UUID;
  v_earnings      NUMERIC;
  v_new_available NUMERIC;
  v_has_dispute   BOOLEAN;
BEGIN
  SELECT * INTO v_reservation
  FROM reservations
  WHERE id = p_reservation_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Reserva no encontrada: %', p_reservation_id;
  END IF;

  -- Solo liberar si el pago fue completado
  IF v_reservation.payment_status NOT IN ('paid', 'fully_paid', 'deposit_paid') THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'not_paid');
  END IF;

  -- No liberar si el evento aún no ocurrió (+ 48h de retención)
  IF v_reservation.event_date IS NOT NULL AND
     (v_reservation.event_date::TIMESTAMPTZ + INTERVAL '48 hours') > NOW() THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'event_not_completed');
  END IF;

  -- No liberar si hay disputa abierta
  SELECT EXISTS (
    SELECT 1 FROM disputes
    WHERE reservation_id = p_reservation_id
      AND status IN ('open', 'under_review')
  ) INTO v_has_dispute;

  IF v_has_dispute THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'dispute_open');
  END IF;

  -- Verificar que hay saldo pendiente en la wallet
  SELECT gw.id, gw.pending_balance
  INTO v_wallet_id, v_earnings
  FROM group_wallets gw
  WHERE gw.group_id = v_reservation.group_id;

  IF NOT FOUND OR v_earnings <= 0 THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'no_pending_balance');
  END IF;

  -- Buscar cuánto corresponde a esta reserva en las transacciones
  SELECT COALESCE(SUM(wt.amount), 0) INTO v_earnings
  FROM wallet_transactions wt
  WHERE wt.reservation_id = p_reservation_id
    AND wt.type = 'credit_pending';

  IF v_earnings <= 0 THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'no_transaction_found');
  END IF;

  -- Mover de pending → available
  UPDATE group_wallets
  SET
    pending_balance   = GREATEST(0, pending_balance - v_earnings),
    available_balance = available_balance + v_earnings,
    updated_at        = NOW()
  WHERE group_id = v_reservation.group_id
  RETURNING available_balance INTO v_new_available;

  -- Marcar reserva como liberada
  UPDATE reservations
  SET wallet_released_at = NOW()
  WHERE id = p_reservation_id;

  -- Registrar transacción
  INSERT INTO wallet_transactions (
    group_wallet_id, group_id, type, amount, reservation_id,
    description, balance_after
  ) VALUES (
    v_wallet_id, v_reservation.group_id, 'release_to_available', v_earnings, p_reservation_id,
    format('Pago liberado post-evento – Reserva %s', p_reservation_id),
    v_new_available
  );

  -- Auditoría
  INSERT INTO financial_audit_logs (
    action, amount, reservation_id,
    before_balance, after_balance
  ) VALUES (
    'payment_released', v_earnings, p_reservation_id,
    v_new_available - v_earnings, v_new_available
  );

  -- Notificación al owner del grupo
  INSERT INTO notifications (user_id, type, title, body, data)
  SELECT
    g.owner_id,
    'wallet',
    '💰 Pago liberado a tu billetera',
    format('$%s MXN están disponibles para retiro por tu evento del %s.',
      to_char(v_earnings, 'FM999,999,990.00'), v_reservation.event_date),
    jsonb_build_object('screen', 'Wallet', 'reservation_id', p_reservation_id)
  FROM groups g
  WHERE g.id = v_reservation.group_id;

  RETURN jsonb_build_object(
    'ok',               true,
    'released_amount',  v_earnings,
    'available_balance', v_new_available
  );
END;
$$;

-- Columna para marcar cuándo se liberó el pago a la wallet
ALTER TABLE reservations
  ADD COLUMN IF NOT EXISTS wallet_released_at TIMESTAMPTZ;

-- ── 8. RPC: open_dispute / resolve_dispute ────────────────────────────────────

CREATE OR REPLACE FUNCTION open_dispute(
  p_reservation_id UUID,
  p_reason         TEXT
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_caller_id    UUID := auth.uid();
  v_reservation  RECORD;
  v_dispute_id   UUID;
BEGIN
  IF v_caller_id IS NULL THEN
    RAISE EXCEPTION 'unauthorized: sesión requerida';
  END IF;

  SELECT * INTO v_reservation FROM reservations WHERE id = p_reservation_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Reserva no encontrada';
  END IF;

  -- Solo el cliente o el dueño del grupo puede abrir disputa
  IF v_reservation.client_id != v_caller_id THEN
    IF NOT EXISTS (
      SELECT 1 FROM groups WHERE id = v_reservation.group_id AND owner_id = v_caller_id
    ) THEN
      RAISE EXCEPTION 'unauthorized: no eres parte de esta reserva';
    END IF;
  END IF;

  -- No abrir disputa si ya hay una abierta
  IF EXISTS (
    SELECT 1 FROM disputes
    WHERE reservation_id = p_reservation_id AND status IN ('open','under_review')
  ) THEN
    RAISE EXCEPTION 'Ya existe una disputa abierta para esta reserva';
  END IF;

  INSERT INTO disputes (reservation_id, opened_by, reason, status)
  VALUES (p_reservation_id, v_caller_id, p_reason, 'open')
  RETURNING id INTO v_dispute_id;

  -- Notificar al admin
  INSERT INTO notifications (user_id, type, title, body, data)
  SELECT id, 'dispute', '⚠️ Nueva disputa abierta',
    format('Se abrió una disputa para la reserva del %s.', v_reservation.event_date),
    jsonb_build_object('screen', 'Disputes', 'dispute_id', v_dispute_id, 'reservation_id', p_reservation_id)
  FROM profiles WHERE role = 'admin';

  RETURN jsonb_build_object('ok', true, 'dispute_id', v_dispute_id);
END;
$$;

-- ────────────────────────────────────────

CREATE OR REPLACE FUNCTION resolve_dispute(
  p_dispute_id      UUID,
  p_resolution      TEXT,   -- 'resolved_client' | 'resolved_group' | 'closed'
  p_resolution_note TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_caller_id  UUID := auth.uid();
  v_dispute    RECORD;
  v_reservation RECORD;
  v_wallet_id  UUID;
  v_earnings   NUMERIC;
BEGIN
  IF v_caller_id IS NULL THEN
    RAISE EXCEPTION 'unauthorized: sesión requerida';
  END IF;

  IF NOT EXISTS (SELECT 1 FROM profiles WHERE id = v_caller_id AND role = 'admin') THEN
    RAISE EXCEPTION 'unauthorized: solo admins pueden resolver disputas';
  END IF;

  SELECT * INTO v_dispute FROM disputes WHERE id = p_dispute_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Disputa no encontrada';
  END IF;

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

  -- Si se resuelve a favor del grupo: liberar el pago normalmente
  IF p_resolution = 'resolved_group' THEN
    PERFORM release_event_payment(v_dispute.reservation_id);
  END IF;

  -- Si se resuelve a favor del cliente: reembolso (mover de pending → 0, registrar refund)
  IF p_resolution = 'resolved_client' THEN
    SELECT COALESCE(SUM(wt.amount), 0) INTO v_earnings
    FROM wallet_transactions wt
    WHERE wt.reservation_id = v_dispute.reservation_id
      AND wt.type = 'credit_pending';

    IF v_earnings > 0 THEN
      SELECT id INTO v_wallet_id FROM group_wallets WHERE group_id = v_reservation.group_id;

      UPDATE group_wallets
      SET
        pending_balance = GREATEST(0, pending_balance - v_earnings),
        updated_at      = NOW()
      WHERE id = v_wallet_id;

      INSERT INTO wallet_transactions (
        group_wallet_id, group_id, type, amount, reservation_id,
        dispute_id, description, balance_after
      )
      SELECT
        gw.id, gw.group_id, 'refund_dispute', v_earnings, v_dispute.reservation_id,
        p_dispute_id,
        format('Reembolso por disputa resuelta a favor del cliente'),
        gw.pending_balance
      FROM group_wallets gw WHERE gw.id = v_wallet_id;
    END IF;
  END IF;

  -- Notificaciones
  INSERT INTO notifications (user_id, type, title, body, data)
  VALUES
    (v_reservation.client_id, 'dispute',
     CASE p_resolution WHEN 'resolved_client' THEN '✅ Disputa resuelta a tu favor' ELSE '❌ Disputa resuelta' END,
     p_resolution_note,
     jsonb_build_object('screen', 'Reservations', 'reservation_id', v_dispute.reservation_id));

  RETURN jsonb_build_object('ok', true, 'resolution', p_resolution);
END;
$$;

-- ── 9. RPC: request_payout / approve_payout ───────────────────────────────────

CREATE OR REPLACE FUNCTION request_payout(
  p_amount       NUMERIC,
  p_payout_method TEXT DEFAULT 'clabe',
  p_clabe        TEXT DEFAULT NULL,
  p_bank_name    TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_caller_id UUID := auth.uid();
  v_group_id  UUID;
  v_wallet    RECORD;
  v_payout_id UUID;
BEGIN
  IF v_caller_id IS NULL THEN
    RAISE EXCEPTION 'unauthorized: sesión requerida';
  END IF;

  SELECT id INTO v_group_id FROM groups WHERE owner_id = v_caller_id LIMIT 1;
  IF v_group_id IS NULL THEN
    RAISE EXCEPTION 'No tienes un grupo registrado';
  END IF;

  SELECT * INTO v_wallet FROM group_wallets WHERE group_id = v_group_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Wallet no encontrada';
  END IF;

  IF v_wallet.available_balance < p_amount THEN
    RAISE EXCEPTION 'Saldo insuficiente: disponible=$%, solicitado=$%',
      v_wallet.available_balance, p_amount;
  END IF;

  IF p_amount < 100 THEN
    RAISE EXCEPTION 'El monto mínimo de retiro es $100 MXN';
  END IF;

  -- Reservar el monto (descontar del available_balance)
  UPDATE group_wallets
  SET
    available_balance = available_balance - p_amount,
    updated_at        = NOW()
  WHERE id = v_wallet.id;

  INSERT INTO payout_requests (
    group_id, group_wallet_id, amount, payout_method, clabe, bank_name
  ) VALUES (
    v_group_id, v_wallet.id, p_amount, p_payout_method, p_clabe, p_bank_name
  ) RETURNING id INTO v_payout_id;

  INSERT INTO wallet_transactions (
    group_wallet_id, group_id, type, amount,
    payout_request_id, description, balance_after
  ) VALUES (
    v_wallet.id, v_group_id, 'debit_payout', p_amount,
    v_payout_id, format('Solicitud de retiro $%s MXN', p_amount),
    v_wallet.available_balance - p_amount
  );

  -- Notificar al admin
  INSERT INTO notifications (user_id, type, title, body, data)
  SELECT id, 'payout', '💸 Nueva solicitud de retiro',
    format('Un grupo solicitó retirar $%s MXN.', to_char(p_amount, 'FM999,999,990')),
    jsonb_build_object('screen', 'Withdrawals', 'payout_request_id', v_payout_id)
  FROM profiles WHERE role = 'admin';

  RETURN jsonb_build_object('ok', true, 'payout_request_id', v_payout_id, 'amount', p_amount);
END;
$$;

-- ────────────────────────────────────────

CREATE OR REPLACE FUNCTION approve_payout(
  p_payout_request_id UUID,
  p_admin_note        TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_caller_id UUID := auth.uid();
  v_payout    RECORD;
BEGIN
  IF v_caller_id IS NULL THEN
    RAISE EXCEPTION 'unauthorized: sesión requerida';
  END IF;

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

  -- Notificar al grupo
  INSERT INTO notifications (user_id, type, title, body, data)
  SELECT g.owner_id, 'payout', '✅ Retiro aprobado',
    format('Tu retiro de $%s MXN fue aprobado. Llegará pronto a tu cuenta.',
      to_char(v_payout.amount, 'FM999,999,990')),
    jsonb_build_object('screen', 'Wallet', 'payout_request_id', p_payout_request_id)
  FROM groups g WHERE g.id = v_payout.group_id;

  RETURN jsonb_build_object('ok', true, 'payout_request_id', p_payout_request_id);
END;
$$;

-- ── 10. RPC: get_group_wallet_summary ─────────────────────────────────────────

CREATE OR REPLACE FUNCTION get_group_wallet_summary(p_group_id UUID DEFAULT NULL)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_caller_id UUID := auth.uid();
  v_group_id  UUID;
  v_wallet    RECORD;
  v_recent    JSONB;
  v_pending_payouts NUMERIC;
BEGIN
  IF v_caller_id IS NULL THEN
    RAISE EXCEPTION 'unauthorized: sesión requerida';
  END IF;

  -- Determinar group_id (admin puede especificar uno; owner usa el suyo)
  IF p_group_id IS NOT NULL THEN
    IF NOT EXISTS (SELECT 1 FROM profiles WHERE id = v_caller_id AND role = 'admin') THEN
      RAISE EXCEPTION 'unauthorized: solo admins pueden ver wallets de otros grupos';
    END IF;
    v_group_id := p_group_id;
  ELSE
    SELECT id INTO v_group_id FROM groups WHERE owner_id = v_caller_id LIMIT 1;
    IF v_group_id IS NULL THEN
      RAISE EXCEPTION 'No tienes un grupo registrado';
    END IF;
  END IF;

  -- Asegurar wallet existe
  PERFORM ensure_group_wallet(v_group_id);

  SELECT * INTO v_wallet FROM group_wallets WHERE group_id = v_group_id;

  -- Últimas 10 transacciones
  SELECT COALESCE(jsonb_agg(t ORDER BY t.created_at DESC), '[]') INTO v_recent
  FROM (
    SELECT id, type, amount, description, reservation_id, created_at, balance_after
    FROM wallet_transactions
    WHERE group_id = v_group_id
    ORDER BY created_at DESC
    LIMIT 10
  ) t;

  -- Retiros pendientes
  SELECT COALESCE(SUM(amount), 0) INTO v_pending_payouts
  FROM payout_requests
  WHERE group_id = v_group_id AND status IN ('pending','approved');

  RETURN jsonb_build_object(
    'pending_balance',   v_wallet.pending_balance,
    'available_balance', v_wallet.available_balance,
    'total_earned',      v_wallet.total_earned,
    'pending_payouts',   v_pending_payouts,
    'recent_transactions', v_recent
  );
END;
$$;

-- ── 11. Índices adicionales ───────────────────────────────────────────────────

CREATE INDEX IF NOT EXISTS idx_disputes_reservation ON disputes(reservation_id);
CREATE INDEX IF NOT EXISTS idx_disputes_status      ON disputes(status);
CREATE INDEX IF NOT EXISTS idx_pr_group_status      ON payout_requests(group_id, status);
CREATE INDEX IF NOT EXISTS idx_reservations_wallet_released ON reservations(wallet_released_at)
  WHERE wallet_released_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_reservations_payment_mode ON reservations(payment_mode);

-- ── 12. Liberar pagos automáticamente (proceso batch) ─────────────────────────
--
-- RPC que libera todos los pagos elegibles (event_date + 48h, sin disputa).
-- Se llama desde un cron edge function o desde el admin dashboard.

CREATE OR REPLACE FUNCTION release_all_eligible_payments()
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_row       RECORD;
  v_released  INT := 0;
  v_skipped   INT := 0;
  v_result    JSONB;
BEGIN
  FOR v_row IN
    SELECT r.id
    FROM reservations r
    WHERE r.payment_status IN ('paid', 'fully_paid', 'deposit_paid')
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
