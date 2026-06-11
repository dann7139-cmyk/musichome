-- 205a_hold_release.sql
-- Hold/Release system: payout_status, financial_audit_logs, atomic release, refund reversal.
-- Requiere: 184a, 184b, 184c, 204 aplicados.

-- ── 1. Columnas de payout en reservations ─────────────────────────────────────

ALTER TABLE reservations
  ADD COLUMN IF NOT EXISTS payout_status  TEXT        NOT NULL DEFAULT 'held',
  ADD COLUMN IF NOT EXISTS held_at        TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS released_at    TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS released_by    UUID        REFERENCES profiles(id),
  ADD COLUMN IF NOT EXISTS mp_payment_id  TEXT;

DO $$ BEGIN
  ALTER TABLE reservations ADD CONSTRAINT chk_payout_status
    CHECK (payout_status IN ('held','pending_release','released','blocked','refunded'));
EXCEPTION WHEN duplicate_object THEN NULL;
END; $$;

CREATE INDEX IF NOT EXISTS idx_res_payout_status
  ON reservations(payout_status);

-- Backfill: reservas que ya tienen wallet liberado
UPDATE reservations
  SET payout_status = 'released',
      released_at   = wallet_released_at
WHERE wallet_released_at IS NOT NULL
  AND payout_status = 'held';

-- Marcar held_at en reservas pagadas pendientes de release
UPDATE reservations
  SET held_at = COALESCE(updated_at, created_at)
WHERE payment_status IN ('paid','fully_paid','deposit_paid')
  AND payout_status = 'held'
  AND held_at IS NULL;

-- ── 2. financial_audit_logs ───────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS financial_audit_logs (
  id           UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  entity_type  TEXT        NOT NULL,  -- 'reservation','wallet','payout','refund','strike'
  entity_id    UUID        NOT NULL,
  action       TEXT        NOT NULL,  -- 'hold','release','cancel','refund','strike','block'
  actor_id     UUID,
  actor_role   TEXT,
  before_state JSONB,
  after_state  JSONB,
  amount       NUMERIC(12,2),
  notes        TEXT,
  created_at   TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_fin_audit_entity  ON financial_audit_logs(entity_id);
CREATE INDEX IF NOT EXISTS idx_fin_audit_action   ON financial_audit_logs(action);
CREATE INDEX IF NOT EXISTS idx_fin_audit_created  ON financial_audit_logs(created_at DESC);

ALTER TABLE financial_audit_logs ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "admin_read_fin_audit" ON financial_audit_logs;
CREATE POLICY "admin_read_fin_audit"
  ON financial_audit_logs FOR SELECT TO authenticated
  USING (EXISTS (SELECT 1 FROM profiles WHERE id = auth.uid() AND role = 'admin'));

-- ── 3. confirm_full_payment_and_credit_wallet v2 ──────────────────────────────
-- Reemplaza versión 184b. Agrega: mp_payment_id, held_at, payout_status='held'.

CREATE OR REPLACE FUNCTION public.confirm_full_payment_and_credit_wallet(
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
  v_earnings    NUMERIC;
BEGIN
  SELECT * INTO v_reservation
  FROM reservations WHERE id = p_reservation_id FOR UPDATE;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'reservation_not_found');
  END IF;

  IF v_reservation.payment_status IN ('paid','fully_paid') THEN
    RETURN jsonb_build_object('ok', true, 'skipped', true, 'reason', 'already_paid');
  END IF;

  v_earnings := COALESCE(
    v_reservation.base_price,
    ROUND(v_reservation.total_price * 0.9, 2)
  );

  PERFORM ensure_group_wallet(v_reservation.group_id);
  SELECT id INTO v_wallet_id FROM group_wallets WHERE group_id = v_reservation.group_id;

  UPDATE group_wallets
  SET pending_balance = pending_balance + v_earnings,
      total_earned    = total_earned    + v_earnings,
      updated_at      = NOW()
  WHERE id = v_wallet_id;

  UPDATE reservations SET
    payment_status = 'paid',
    payout_status  = 'held',
    held_at        = NOW(),
    mp_payment_id  = p_mp_payment_id,
    updated_at     = NOW()
  WHERE id = p_reservation_id;

  INSERT INTO wallet_transactions (
    group_wallet_id, group_id, type, amount,
    reservation_id, description, balance_after
  )
  SELECT
    gw.id, gw.group_id, 'credit_pending', v_earnings,
    p_reservation_id,
    format('Pago confirmado MP:%s — reserva %s', p_mp_payment_id, p_reservation_id),
    gw.pending_balance + v_earnings
  FROM group_wallets gw WHERE gw.id = v_wallet_id;

  INSERT INTO financial_audit_logs (
    entity_type, entity_id, action, actor_id, actor_role, amount, notes
  ) VALUES (
    'reservation', p_reservation_id, 'hold',
    NULL, 'system', v_earnings,
    format('Payment confirmed MP:%s — earnings held pending event', p_mp_payment_id)
  );

  RAISE NOTICE '[PAYMENT_CONFIRMED_HELD] reservation=% mp=% earnings=%',
    p_reservation_id, p_mp_payment_id, v_earnings;

  RETURN jsonb_build_object('ok', true, 'amount_held', v_earnings);
END;
$$;

GRANT EXECUTE ON FUNCTION public.confirm_full_payment_and_credit_wallet TO authenticated, service_role;

-- ── 4. process_refund_reversal ────────────────────────────────────────────────
-- Revierte pending_balance cuando un reembolso es procesado.
-- Idempotente: si ya está refunded, retorna skipped.

CREATE OR REPLACE FUNCTION public.process_refund_reversal(
  p_reservation_id UUID,
  p_mp_refund_id   TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_reservation RECORD;
  v_wallet      RECORD;
  v_reversal    NUMERIC;
BEGIN
  SELECT * INTO v_reservation
  FROM reservations WHERE id = p_reservation_id FOR UPDATE;

  IF NOT FOUND THEN RETURN jsonb_build_object('ok', false, 'error', 'not_found'); END IF;

  IF v_reservation.payout_status = 'refunded' THEN
    RETURN jsonb_build_object('ok', true, 'skipped', true, 'reason', 'already_refunded');
  END IF;

  v_reversal := COALESCE(
    v_reservation.base_price,
    ROUND(v_reservation.total_price * 0.9, 2)
  );

  SELECT * INTO v_wallet
  FROM group_wallets WHERE group_id = v_reservation.group_id FOR UPDATE;

  IF FOUND THEN
    UPDATE group_wallets SET
      pending_balance = GREATEST(0, pending_balance - v_reversal),
      total_earned    = GREATEST(0, total_earned    - v_reversal),
      updated_at      = NOW()
    WHERE id = v_wallet.id;

    INSERT INTO wallet_transactions (
      group_wallet_id, group_id, type, amount,
      reservation_id, description, balance_after
    ) VALUES (
      v_wallet.id, v_reservation.group_id, 'debit_refund', v_reversal,
      p_reservation_id,
      format('Reversión reembolso%s — reserva %s',
        CASE WHEN p_mp_refund_id IS NOT NULL THEN format(' MP:%s', p_mp_refund_id) ELSE '' END,
        p_reservation_id),
      GREATEST(0, v_wallet.pending_balance - v_reversal)
    );
  END IF;

  UPDATE reservations SET
    payment_status = 'refunded',
    payout_status  = 'refunded',
    updated_at     = NOW()
  WHERE id = p_reservation_id;

  INSERT INTO financial_audit_logs (
    entity_type, entity_id, action, actor_id, actor_role, amount, notes
  ) VALUES (
    'reservation', p_reservation_id, 'refund',
    NULL, 'system', v_reversal,
    format('Refund reversal — MP refund %s', COALESCE(p_mp_refund_id, 'manual'))
  );

  RAISE NOTICE '[REFUND_REVERSED] reservation=% amount=% mp_refund=%',
    p_reservation_id, v_reversal, COALESCE(p_mp_refund_id, 'n/a');

  RETURN jsonb_build_object('ok', true, 'reversed', v_reversal);
END;
$$;

GRANT EXECUTE ON FUNCTION public.process_refund_reversal TO authenticated, service_role;

-- ── 5. release_group_earnings_atomic ──────────────────────────────────────────

CREATE OR REPLACE FUNCTION public.release_group_earnings_atomic(
  p_reservation_id UUID,
  p_released_by    UUID DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_reservation RECORD;
  v_wallet      RECORD;
  v_earnings    NUMERIC;
  v_actor_role  TEXT := 'system';
BEGIN
  SELECT * INTO v_reservation
  FROM reservations WHERE id = p_reservation_id FOR UPDATE;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_found');
  END IF;

  IF v_reservation.payout_status = 'released' THEN
    RAISE NOTICE '[PAYOUT_ALREADY_RELEASED] reservation=%', p_reservation_id;
    RETURN jsonb_build_object('ok', true, 'skipped', true, 'reason', 'already_released');
  END IF;

  IF v_reservation.payout_status IN ('blocked','refunded') THEN
    RAISE NOTICE '[PAYOUT_BLOCKED] reservation=% status=%',
      p_reservation_id, v_reservation.payout_status;
    RETURN jsonb_build_object('ok', false, 'error', 'payout_blocked',
      'payout_status', v_reservation.payout_status);
  END IF;

  IF v_reservation.payment_status NOT IN ('paid','fully_paid','deposit_paid') THEN
    RETURN jsonb_build_object('ok', false, 'error', 'payment_not_confirmed');
  END IF;

  IF EXISTS (
    SELECT 1 FROM disputes
    WHERE reservation_id = p_reservation_id AND status IN ('open','under_review')
  ) THEN
    RAISE NOTICE '[PAYOUT_BLOCKED] open dispute for reservation=%', p_reservation_id;
    RETURN jsonb_build_object('ok', false, 'error', 'open_dispute_blocks_release');
  END IF;

  IF p_released_by IS NOT NULL THEN
    SELECT COALESCE(role, 'unknown') INTO v_actor_role
    FROM profiles WHERE id = p_released_by;
  END IF;

  PERFORM ensure_group_wallet(v_reservation.group_id);
  SELECT * INTO v_wallet
  FROM group_wallets WHERE group_id = v_reservation.group_id FOR UPDATE;

  v_earnings := COALESCE(
    v_reservation.base_price,
    ROUND(v_reservation.total_price * 0.9, 2)
  );

  UPDATE group_wallets SET
    pending_balance   = GREATEST(0, pending_balance - v_earnings),
    available_balance = available_balance + v_earnings,
    updated_at        = NOW()
  WHERE id = v_wallet.id;

  UPDATE reservations SET
    payout_status      = 'released',
    released_at        = NOW(),
    released_by        = p_released_by,
    wallet_released_at = NOW(),
    updated_at         = NOW()
  WHERE id = p_reservation_id;

  INSERT INTO wallet_transactions (
    group_wallet_id, group_id, type, amount,
    reservation_id, description, balance_after
  ) VALUES (
    v_wallet.id, v_reservation.group_id, 'credit_available', v_earnings,
    p_reservation_id,
    format('Ganancias liberadas post-evento — reserva %s', p_reservation_id),
    v_wallet.available_balance + v_earnings
  );

  INSERT INTO financial_audit_logs (
    entity_type, entity_id, action,
    actor_id, actor_role,
    before_state, after_state,
    amount, notes
  ) VALUES (
    'reservation', p_reservation_id, 'release',
    p_released_by, v_actor_role,
    jsonb_build_object('payout_status','held',     'available', v_wallet.available_balance),
    jsonb_build_object('payout_status','released', 'available', v_wallet.available_balance + v_earnings),
    v_earnings,
    format('Released by %s', v_actor_role)
  );

  INSERT INTO notifications (user_id, type, title, body, data)
  SELECT g.owner_id, 'payout',
    '💰 Ganancias liberadas',
    format('$%s MXN disponibles en tu billetera por el evento del %s.',
      to_char(v_earnings, 'FM999,999,990'), v_reservation.event_date),
    jsonb_build_object('screen','Wallet','reservation_id',p_reservation_id)
  FROM groups g WHERE g.id = v_reservation.group_id;

  RAISE NOTICE '[PAYOUT_RELEASED] reservation=% group=% amount=% actor=%',
    p_reservation_id, v_reservation.group_id, v_earnings, v_actor_role;

  RETURN jsonb_build_object('ok', true, 'amount_released', v_earnings, 'released_at', NOW());
END;
$$;

GRANT EXECUTE ON FUNCTION public.release_group_earnings_atomic TO authenticated, service_role;

-- Backward compat: release_event_payment ahora llama a la función atómica
CREATE OR REPLACE FUNCTION public.release_event_payment(p_reservation_id UUID)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
BEGIN
  RETURN release_group_earnings_atomic(p_reservation_id, NULL);
END;
$$;

GRANT EXECUTE ON FUNCTION public.release_event_payment TO service_role;

-- ── 6. Actualizar release_all_eligible_payments ───────────────────────────────
-- Usa payout_status='held' en lugar de wallet_released_at IS NULL.
-- Auto-release a las 12 horas post-evento.

CREATE OR REPLACE FUNCTION public.release_all_eligible_payments()
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
      AND r.payout_status = 'held'
      AND r.event_date IS NOT NULL
      AND (r.event_date::TIMESTAMPTZ + INTERVAL '12 hours') < NOW()
      AND NOT EXISTS (
        SELECT 1 FROM disputes d
        WHERE d.reservation_id = r.id AND d.status IN ('open','under_review')
      )
    FOR UPDATE SKIP LOCKED
  LOOP
    v_result := release_group_earnings_atomic(v_row.id, NULL);
    IF (v_result->>'ok')::BOOLEAN AND NOT (v_result->>'skipped')::BOOLEAN THEN
      v_released := v_released + 1;
    ELSE
      v_skipped := v_skipped + 1;
    END IF;
  END LOOP;

  RETURN jsonb_build_object('ok', true, 'released', v_released, 'skipped', v_skipped);
END;
$$;

GRANT EXECUTE ON FUNCTION public.release_all_eligible_payments TO service_role;

SELECT '205a_hold_release.sql ejecutado ✅' AS status;
