-- 204_payment_event_logs.sql
-- Tabla de auditoría de todos los eventos de pago MP + constraint payment_status.
-- Requiere: 184a (group_wallets, reservations.payment_mode), 203 (flow_version).

-- ── 1. Constraint payment_status (no aplicó en 203) ──────────────────────────

DO $$ BEGIN ALTER TABLE reservations DROP CONSTRAINT IF EXISTS reservations_payment_status_check; EXCEPTION WHEN OTHERS THEN NULL; END; $$;
DO $$ BEGIN ALTER TABLE reservations DROP CONSTRAINT IF EXISTS chk_payment_status;               EXCEPTION WHEN OTHERS THEN NULL; END; $$;
DO $$ BEGIN ALTER TABLE reservations DROP CONSTRAINT IF EXISTS chk_res_payment_status;           EXCEPTION WHEN OTHERS THEN NULL; END; $$;
DO $$ BEGIN ALTER TABLE reservations DROP CONSTRAINT IF EXISTS chk_payment_status_v2;            EXCEPTION WHEN OTHERS THEN NULL; END; $$;
DO $$ BEGIN ALTER TABLE reservations DROP CONSTRAINT IF EXISTS chk_payment_status_v3;            EXCEPTION WHEN OTHERS THEN NULL; END; $$;

ALTER TABLE reservations
  ADD CONSTRAINT chk_payment_status_v3 CHECK (
    payment_status IN (
      'unpaid', 'pending', 'pending_payment',
      'deposit_pending', 'deposit_paid', 'remaining_pending',
      'fully_paid', 'paid',
      'payment_failed', 'refunded', 'cancelled'
    )
  );

-- ── 2. Tabla payment_event_logs ───────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS payment_event_logs (
  id                 UUID          PRIMARY KEY DEFAULT gen_random_uuid(),
  mp_payment_id      TEXT          NOT NULL,
  external_ref       TEXT,
  reservation_id     UUID          REFERENCES reservations(id) ON DELETE SET NULL,
  mp_status          TEXT          NOT NULL,
  mp_amount          NUMERIC(12,2),
  expected_amount    NUMERIC(12,2),
  amount_diff        NUMERIC(12,2),
  is_mismatch        BOOLEAN       DEFAULT FALSE,
  payment_mode       TEXT,
  installment_months INT,
  installment_plan   TEXT,
  event_type         TEXT          NOT NULL,
  notes              TEXT,
  raw_data           JSONB,
  created_at         TIMESTAMPTZ   DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_paylogs_reservation
  ON payment_event_logs(reservation_id);
CREATE INDEX IF NOT EXISTS idx_paylogs_mp_payment_id
  ON payment_event_logs(mp_payment_id);
CREATE INDEX IF NOT EXISTS idx_paylogs_is_mismatch
  ON payment_event_logs(is_mismatch) WHERE is_mismatch = TRUE;
CREATE INDEX IF NOT EXISTS idx_paylogs_event_type
  ON payment_event_logs(event_type);
CREATE INDEX IF NOT EXISTS idx_paylogs_created_at
  ON payment_event_logs(created_at DESC);

ALTER TABLE payment_event_logs ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "admin_read_payment_logs" ON payment_event_logs;
CREATE POLICY "admin_read_payment_logs"
  ON payment_event_logs FOR SELECT
  TO authenticated
  USING (
    EXISTS (SELECT 1 FROM profiles WHERE id = auth.uid() AND role = 'admin')
  );

-- ── 3. RPC log_payment_event (llamado por webhook via REST con service_role) ──

CREATE OR REPLACE FUNCTION public.log_payment_event(
  p_mp_payment_id    TEXT,
  p_external_ref     TEXT        DEFAULT NULL,
  p_reservation_id   UUID        DEFAULT NULL,
  p_mp_status        TEXT        DEFAULT 'unknown',
  p_mp_amount        NUMERIC     DEFAULT NULL,
  p_expected_amount  NUMERIC     DEFAULT NULL,
  p_payment_mode     TEXT        DEFAULT NULL,
  p_installment_months INT       DEFAULT NULL,
  p_installment_plan TEXT        DEFAULT NULL,
  p_event_type       TEXT        DEFAULT 'webhook_event',
  p_notes            TEXT        DEFAULT NULL,
  p_raw_data         JSONB       DEFAULT NULL
)
RETURNS UUID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_diff     NUMERIC(12,2);
  v_mismatch BOOLEAN := FALSE;
  v_log_id   UUID;
BEGIN
  IF p_mp_amount IS NOT NULL AND p_expected_amount IS NOT NULL THEN
    v_diff     := ROUND(ABS(p_mp_amount - p_expected_amount), 2);
    v_mismatch := v_diff > 1.0;
  END IF;

  INSERT INTO payment_event_logs (
    mp_payment_id, external_ref, reservation_id,
    mp_status, mp_amount, expected_amount, amount_diff, is_mismatch,
    payment_mode, installment_months, installment_plan,
    event_type, notes, raw_data
  ) VALUES (
    p_mp_payment_id, p_external_ref, p_reservation_id,
    p_mp_status, p_mp_amount, p_expected_amount, v_diff, v_mismatch,
    p_payment_mode, p_installment_months, p_installment_plan,
    p_event_type, p_notes, p_raw_data
  )
  RETURNING id INTO v_log_id;

  IF v_mismatch THEN
    INSERT INTO notifications (user_id, type, title, body, data)
    SELECT
      pr.id,
      'payment_mismatch',
      '⚠️ Discrepancia de pago',
      format('Reserva %s: esperado $%s MXN, recibido $%s MXN (dif $%s)',
        COALESCE(p_reservation_id::TEXT, p_external_ref),
        p_expected_amount, p_mp_amount, v_diff),
      jsonb_build_object(
        'screen',         'FinancialScreen',
        'log_id',         v_log_id,
        'reservation_id', p_reservation_id,
        'mp_payment_id',  p_mp_payment_id
      )
    FROM profiles pr WHERE pr.role = 'admin';
  END IF;

  RETURN v_log_id;
END;
$$;

GRANT EXECUTE ON FUNCTION public.log_payment_event TO authenticated, service_role;

-- ── 4. RPC admin_payment_mismatches ──────────────────────────────────────────

CREATE OR REPLACE FUNCTION public.admin_payment_mismatches(
  p_limit  INT DEFAULT 50,
  p_offset INT DEFAULT 0
)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_caller_id UUID := auth.uid();
  v_rows      JSONB;
  v_total     INT;
BEGIN
  IF v_caller_id IS NULL THEN RAISE EXCEPTION 'unauthorized'; END IF;
  IF NOT EXISTS (SELECT 1 FROM profiles WHERE id = v_caller_id AND role = 'admin') THEN
    RAISE EXCEPTION 'unauthorized: solo admins';
  END IF;

  SELECT COUNT(*) INTO v_total FROM payment_event_logs WHERE is_mismatch = TRUE;

  SELECT COALESCE(jsonb_agg(row ORDER BY row.created_at DESC), '[]') INTO v_rows
  FROM (
    SELECT
      id, mp_payment_id, reservation_id, external_ref,
      mp_status, mp_amount, expected_amount, amount_diff,
      payment_mode, installment_months, event_type, notes, created_at
    FROM payment_event_logs
    WHERE is_mismatch = TRUE
    ORDER BY created_at DESC
    LIMIT p_limit OFFSET p_offset
  ) row;

  RETURN jsonb_build_object('total', v_total, 'rows', v_rows);
END;
$$;

GRANT EXECUTE ON FUNCTION public.admin_payment_mismatches TO authenticated;

SELECT '204_payment_event_logs.sql ejecutado ✅' AS status;
