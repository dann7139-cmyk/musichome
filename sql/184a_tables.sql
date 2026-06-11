-- 184a_tables.sql
-- PASO 1/3: Tablas, RLS y función auxiliar.
-- Ejecutar ANTES de 184b y 184c.

-- ── payment_mode en reservations ─────────────────────────────────────────────

ALTER TABLE reservations
  ADD COLUMN IF NOT EXISTS payment_mode TEXT DEFAULT 'full'
    CONSTRAINT chk_payment_mode CHECK (payment_mode IN ('full', 'deposit'));

UPDATE reservations
SET payment_mode = 'deposit'
WHERE payment_mode = 'full'
  AND (payment_status IN ('deposit_paid', 'deposit_pending') OR mp_preference_id IS NOT NULL)
  AND created_at < NOW();

ALTER TABLE reservations
  ADD COLUMN IF NOT EXISTS wallet_released_at TIMESTAMPTZ;

-- ── group_wallets ─────────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS group_wallets (
  id                UUID          DEFAULT gen_random_uuid() PRIMARY KEY,
  group_id          UUID          REFERENCES groups(id) ON DELETE CASCADE UNIQUE NOT NULL,
  pending_balance   NUMERIC(14,2) DEFAULT 0 NOT NULL CHECK (pending_balance   >= 0),
  available_balance NUMERIC(14,2) DEFAULT 0 NOT NULL CHECK (available_balance >= 0),
  total_earned      NUMERIC(14,2) DEFAULT 0 NOT NULL CHECK (total_earned      >= 0),
  created_at        TIMESTAMPTZ   DEFAULT NOW(),
  updated_at        TIMESTAMPTZ   DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_group_wallets_group_id ON group_wallets(group_id);
ALTER TABLE group_wallets ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS gw_owner_select    ON group_wallets;
DROP POLICY IF EXISTS gw_no_direct_write ON group_wallets;

CREATE POLICY gw_owner_select ON group_wallets FOR SELECT
  USING (
    group_id IN (SELECT id FROM groups WHERE owner_id = auth.uid())
    OR EXISTS (SELECT 1 FROM profiles WHERE id = auth.uid() AND role = 'admin')
  );

CREATE POLICY gw_no_direct_write ON group_wallets FOR ALL USING (FALSE);

CREATE OR REPLACE FUNCTION ensure_group_wallet(p_group_id UUID)
RETURNS UUID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE v_wallet_id UUID;
BEGIN
  INSERT INTO group_wallets (group_id) VALUES (p_group_id)
  ON CONFLICT (group_id) DO NOTHING;
  SELECT id INTO v_wallet_id FROM group_wallets WHERE group_id = p_group_id;
  RETURN v_wallet_id;
END;
$$;

-- ── wallet_transactions ───────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS wallet_transactions (
  id                UUID          DEFAULT gen_random_uuid() PRIMARY KEY,
  group_wallet_id   UUID          REFERENCES group_wallets(id) ON DELETE CASCADE NOT NULL,
  group_id          UUID          REFERENCES groups(id) NOT NULL,
  type              TEXT          NOT NULL
    CONSTRAINT chk_wt_type CHECK (
      type IN ('credit_pending','release_to_available','debit_payout','refund_dispute','adjustment')
    ),
  amount            NUMERIC(14,2) NOT NULL CHECK (amount > 0),
  reservation_id    UUID          REFERENCES reservations(id),
  payout_request_id UUID,
  dispute_id        UUID,
  mp_payment_id     TEXT,
  description       TEXT,
  balance_after     NUMERIC(14,2) NOT NULL,
  created_at        TIMESTAMPTZ   DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_wt_wallet      ON wallet_transactions(group_wallet_id);
CREATE INDEX IF NOT EXISTS idx_wt_group       ON wallet_transactions(group_id);
CREATE INDEX IF NOT EXISTS idx_wt_reservation ON wallet_transactions(reservation_id);
CREATE INDEX IF NOT EXISTS idx_wt_created_at  ON wallet_transactions(created_at DESC);

ALTER TABLE wallet_transactions ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS wt_owner_select    ON wallet_transactions;
DROP POLICY IF EXISTS wt_no_direct_write ON wallet_transactions;

CREATE POLICY wt_owner_select ON wallet_transactions FOR SELECT
  USING (
    group_id IN (SELECT id FROM groups WHERE owner_id = auth.uid())
    OR EXISTS (SELECT 1 FROM profiles WHERE id = auth.uid() AND role = 'admin')
  );

CREATE POLICY wt_no_direct_write ON wallet_transactions FOR ALL USING (FALSE);

-- ── payout_requests ───────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS payout_requests (
  id                UUID          DEFAULT gen_random_uuid() PRIMARY KEY,
  group_id          UUID          REFERENCES groups(id) ON DELETE CASCADE NOT NULL,
  group_wallet_id   UUID          REFERENCES group_wallets(id) NOT NULL,
  amount            NUMERIC(14,2) NOT NULL CHECK (amount > 0),
  status            TEXT          DEFAULT 'pending'
    CONSTRAINT chk_pr_status CHECK (status IN ('pending','approved','paid','rejected')),
  clabe             TEXT,
  bank_name         TEXT,
  stripe_account_id TEXT,
  payout_method     TEXT          DEFAULT 'clabe'
    CONSTRAINT chk_pr_method CHECK (payout_method IN ('clabe','stripe')),
  admin_note        TEXT,
  approved_at       TIMESTAMPTZ,
  paid_at           TIMESTAMPTZ,
  created_at        TIMESTAMPTZ   DEFAULT NOW(),
  updated_at        TIMESTAMPTZ   DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_pr_group        ON payout_requests(group_id);
CREATE INDEX IF NOT EXISTS idx_pr_status       ON payout_requests(status);
CREATE INDEX IF NOT EXISTS idx_pr_group_status ON payout_requests(group_id, status);

ALTER TABLE payout_requests ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS pr_owner_select    ON payout_requests;
DROP POLICY IF EXISTS pr_no_direct_write ON payout_requests;

CREATE POLICY pr_owner_select ON payout_requests FOR SELECT
  USING (
    group_id IN (SELECT id FROM groups WHERE owner_id = auth.uid())
    OR EXISTS (SELECT 1 FROM profiles WHERE id = auth.uid() AND role = 'admin')
  );

CREATE POLICY pr_no_direct_write ON payout_requests FOR ALL USING (FALSE);

-- ── disputes ──────────────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS disputes (
  id              UUID        DEFAULT gen_random_uuid() PRIMARY KEY,
  reservation_id  UUID        REFERENCES reservations(id) ON DELETE CASCADE NOT NULL,
  opened_by       UUID        REFERENCES auth.users(id) NOT NULL,
  status          TEXT        DEFAULT 'open'
    CONSTRAINT chk_disp_status CHECK (
      status IN ('open','under_review','resolved_client','resolved_group','closed')
    ),
  reason          TEXT        NOT NULL,
  resolution_note TEXT,
  resolved_by     UUID        REFERENCES auth.users(id),
  resolved_at     TIMESTAMPTZ,
  created_at      TIMESTAMPTZ DEFAULT NOW(),
  updated_at      TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_disp_reservation ON disputes(reservation_id);
CREATE INDEX IF NOT EXISTS idx_disp_status      ON disputes(status);

ALTER TABLE disputes ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS disp_participant_select ON disputes;
CREATE POLICY disp_participant_select ON disputes FOR SELECT
  USING (
    opened_by = auth.uid()
    OR reservation_id IN (
      SELECT r.id FROM reservations r
      JOIN groups g ON g.id = r.group_id
      WHERE r.client_id = auth.uid() OR g.owner_id = auth.uid()
    )
    OR EXISTS (SELECT 1 FROM profiles WHERE id = auth.uid() AND role = 'admin')
  );

-- ── dispute_messages ──────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS dispute_messages (
  id         UUID        DEFAULT gen_random_uuid() PRIMARY KEY,
  dispute_id UUID        REFERENCES disputes(id) ON DELETE CASCADE NOT NULL,
  sender_id  UUID        REFERENCES auth.users(id) NOT NULL,
  body       TEXT        NOT NULL,
  is_internal BOOLEAN    DEFAULT FALSE,
  created_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_dm_dispute    ON dispute_messages(dispute_id);
CREATE INDEX IF NOT EXISTS idx_dm_created_at ON dispute_messages(created_at);

ALTER TABLE dispute_messages ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS dm_select ON dispute_messages;
DROP POLICY IF EXISTS dm_insert ON dispute_messages;

CREATE POLICY dm_select ON dispute_messages FOR SELECT
  USING (
    dispute_id IN (
      SELECT d.id FROM disputes d
      JOIN reservations r ON r.id = d.reservation_id
      JOIN groups g ON g.id = r.group_id
      WHERE r.client_id = auth.uid() OR g.owner_id = auth.uid() OR d.opened_by = auth.uid()
    )
    OR EXISTS (SELECT 1 FROM profiles WHERE id = auth.uid() AND role = 'admin')
  );

CREATE POLICY dm_insert ON dispute_messages FOR INSERT
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

-- ── dispute_evidence ──────────────────────────────────────────────────────────

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
DROP POLICY IF EXISTS de_insert ON dispute_evidence;

CREATE POLICY de_select ON dispute_evidence FOR SELECT
  USING (
    dispute_id IN (
      SELECT d.id FROM disputes d
      JOIN reservations r ON r.id = d.reservation_id
      JOIN groups g ON g.id = r.group_id
      WHERE r.client_id = auth.uid() OR g.owner_id = auth.uid() OR d.opened_by = auth.uid()
    )
    OR EXISTS (SELECT 1 FROM profiles WHERE id = auth.uid() AND role = 'admin')
  );

CREATE POLICY de_insert ON dispute_evidence FOR INSERT
  WITH CHECK (
    uploaded_by = auth.uid()
    AND dispute_id IN (
      SELECT d.id FROM disputes d
      JOIN reservations r ON r.id = d.reservation_id
      JOIN groups g ON g.id = r.group_id
      WHERE r.client_id = auth.uid() OR g.owner_id = auth.uid() OR d.opened_by = auth.uid()
    )
  );

-- Índices reservations
CREATE INDEX IF NOT EXISTS idx_reservations_wallet_released ON reservations(wallet_released_at)
  WHERE wallet_released_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_reservations_payment_mode ON reservations(payment_mode);
