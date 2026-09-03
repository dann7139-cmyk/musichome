-- ============================================================
-- sql/535_p1f_hardening.sql — Fase P1F: hardening financiero
--
-- 1. Tabla provider_refund_claims + índice único parcial (claim atómico
--    de reembolsos automáticos vía proveedor, separado de refund_intents
--    que es el flujo MANUAL de SPEI y tiene semántica incompatible).
-- 2. claim_reservation_refund() — valida y reserva atómicamente.
-- 3. Hardening MXN/USD explícito (CASE, nunca ELSE=MXN) en las 7
--    funciones financieras activas que escriben group_wallets:
--    admin_register_group_payment, release_group_earnings_atomic,
--    confirm_full_payment_and_credit_wallet, resolve_dispute,
--    process_refund_reversal, settle_cancellation, settle_group_cancellation.
-- 4. Guard manual_payment_already_transferred en las 3 de reversión +
--    resolve_dispute. Guard refund_in_progress en admin_register_group_payment.
-- 5. Allowlist de estado (confirmed+completed para advance,
--    completed-only para final_settlement/solicitar pago/colas).
-- 6. Filtro de disputas abiertas en ambas colas + group_request_payment.
-- 7. Cierre de group_payment_requests pending->completed para
--    CUALQUIER kind que deje saldo en 0 (no solo final_settlement).
-- 8. chk_grp_pay_bucket ampliado con pending_usd/available_usd.
-- 9. Legacy: guard group_self_withdrawal_disabled en request_withdrawal;
--    RLS: quitar INSERT/UPDATE de group sobre withdrawals.
-- 10. owner_id agregado a admin_get_pending_group_payments para paths
--     de comprobantes correctos; currency_code agregado a ambas colas.
-- ============================================================

BEGIN;

-- ── 1. provider_refund_claims ─────────────────────────────────
CREATE TABLE public.provider_refund_claims (
  id                   UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  reservation_id       UUID NOT NULL REFERENCES reservations(id),
  group_id             UUID NOT NULL REFERENCES groups(id),
  provider             TEXT NOT NULL CHECK (provider IN ('stripe','conekta','mercadopago')),
  provider_payment_id  TEXT NOT NULL,
  mode                 TEXT NOT NULL CHECK (mode IN ('full','cancellation','group_cancellation')),
  currency_code        TEXT NOT NULL CHECK (currency_code IN ('MXN','USD')),
  amount               NUMERIC NOT NULL CHECK (amount > 0),
  status               TEXT NOT NULL DEFAULT 'processing'
                        CHECK (status IN ('processing','provider_succeeded','done','provider_failed')),
  needs_verification   BOOLEAN NOT NULL DEFAULT FALSE,
  provider_refund_id   TEXT,
  ambiguous_reason      TEXT,
  claimed_by            UUID NOT NULL REFERENCES profiles(id),
  created_at            TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at            TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE UNIQUE INDEX uq_provider_refund_claim_active
  ON public.provider_refund_claims (provider, provider_payment_id)
  WHERE status IN ('processing','provider_succeeded');

CREATE INDEX idx_provider_refund_claims_reservation ON public.provider_refund_claims (reservation_id);

ALTER TABLE public.provider_refund_claims ENABLE ROW LEVEL SECURITY;

CREATE POLICY prc_admin_all ON public.provider_refund_claims FOR ALL
  USING (EXISTS (SELECT 1 FROM profiles WHERE id = auth.uid() AND role = 'admin'))
  WITH CHECK (EXISTS (SELECT 1 FROM profiles WHERE id = auth.uid() AND role = 'admin'));

CREATE POLICY prc_owner_read ON public.provider_refund_claims FOR SELECT
  USING (EXISTS (SELECT 1 FROM groups g WHERE g.id = provider_refund_claims.group_id AND g.owner_id = auth.uid()));

-- ── 8. Ampliar chk_grp_pay_bucket ─────────────────────────────
ALTER TABLE public.group_reservation_payments DROP CONSTRAINT chk_grp_pay_bucket;
ALTER TABLE public.group_reservation_payments ADD CONSTRAINT chk_grp_pay_bucket
  CHECK (wallet_bucket_debited = ANY (ARRAY['pending','available','pending_usd','available_usd']));

-- ── 2. claim_reservation_refund ───────────────────────────────
CREATE FUNCTION public.claim_reservation_refund(
  p_reservation_id     UUID,
  p_mode               TEXT,
  p_amount             NUMERIC,
  p_provider            TEXT,
  p_provider_payment_id TEXT
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE
  v_group_id       UUID;
  v_res            RECORD;
  v_claim_id       UUID;
  v_ya_transferido NUMERIC;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM profiles WHERE id = auth.uid() AND role = 'admin') THEN
    -- Cliente/dueño de grupo también pueden iniciar refund (mismo criterio que process-refund):
    IF NOT EXISTS (
      SELECT 1 FROM reservations r WHERE r.id = p_reservation_id
        AND (r.client_id = auth.uid()
             OR EXISTS (SELECT 1 FROM groups g WHERE g.id = r.group_id AND g.owner_id = auth.uid()))
    ) THEN
      RETURN jsonb_build_object('ok', false, 'error', 'not_authorized');
    END IF;
  END IF;

  IF p_mode NOT IN ('full','cancellation','group_cancellation') THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_mode');
  END IF;
  IF p_amount IS NULL OR p_amount <= 0 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_amount');
  END IF;
  IF p_provider NOT IN ('stripe','conekta','mercadopago') THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_provider');
  END IF;
  IF COALESCE(TRIM(p_provider_payment_id),'') = '' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_payment_id');
  END IF;

  SELECT group_id INTO v_group_id FROM reservations WHERE id = p_reservation_id;
  IF v_group_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_found');
  END IF;

  PERFORM pg_advisory_xact_lock(hashtext(v_group_id::text));
  SELECT * INTO v_res FROM reservations WHERE id = p_reservation_id FOR UPDATE;
  IF v_res.group_id IS DISTINCT FROM v_group_id THEN
    RETURN jsonb_build_object('ok', false, 'error', 'temporary_retry');
  END IF;

  IF v_res.currency_code IS NULL OR v_res.currency_code NOT IN ('MXN','USD') THEN
    RETURN jsonb_build_object('ok', false, 'error', 'unsupported_currency', 'currency_code', v_res.currency_code);
  END IF;

  IF v_res.payment_status NOT IN ('paid','fully_paid','deposit_paid') THEN
    RETURN jsonb_build_object('ok', false, 'error', 'payment_not_eligible');
  END IF;
  IF v_res.payout_status IN ('refunded','released') THEN
    RETURN jsonb_build_object('ok', false, 'error', 'payout_status_not_eligible', 'payout_status', v_res.payout_status);
  END IF;

  IF EXISTS (SELECT 1 FROM disputes WHERE reservation_id = p_reservation_id AND status IN ('open','under_review')) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'open_dispute_blocks_refund');
  END IF;

  SELECT COALESCE(SUM(amount),0) INTO v_ya_transferido
  FROM group_reservation_payments WHERE reservation_id = p_reservation_id;
  IF v_ya_transferido > 0 THEN
    INSERT INTO financial_audit_logs (entity_type, entity_id, action, actor_id, actor_role, amount, notes)
    VALUES ('reservation', p_reservation_id, 'refund_blocked_manual_payment_exists', auth.uid(), 'system', v_ya_transferido,
      format('Claim de reembolso rechazado en precheck — ya se transfirieron $%s al músico', v_ya_transferido));
    INSERT INTO notifications (user_id, type, title, body, data)
    SELECT p.id, 'admin', '🚨 Reembolso bloqueado — ya hubo pago manual',
      format('La reserva %s ya tiene $%s transferidos al músico. Requiere reconciliación manual.', p_reservation_id, v_ya_transferido),
      jsonb_build_object('reservation_id', p_reservation_id, 'screen', 'AdminFinancial')
    FROM profiles p WHERE p.role = 'admin';
    RETURN jsonb_build_object('ok', false, 'error', 'manual_payment_already_transferred', 'amount_already_paid', v_ya_transferido);
  END IF;

  BEGIN
    INSERT INTO provider_refund_claims
      (reservation_id, group_id, provider, provider_payment_id, mode, currency_code, amount, claimed_by)
    VALUES (p_reservation_id, v_group_id, p_provider, p_provider_payment_id, p_mode, v_res.currency_code, p_amount,
            COALESCE(auth.uid(), v_res.client_id))
    RETURNING id INTO v_claim_id;
  EXCEPTION WHEN unique_violation THEN
    RETURN jsonb_build_object('ok', false, 'error', 'refund_already_in_progress');
  END;

  RETURN jsonb_build_object('ok', true, 'claim_id', v_claim_id, 'currency', v_res.currency_code);
END;
$function$;

-- ── 3-5. admin_register_group_payment ─────────────────────────
DROP FUNCTION IF EXISTS public.admin_register_group_payment(uuid, numeric, text, text, text, text, timestamptz);

CREATE FUNCTION public.admin_register_group_payment(
  p_reservation_id     UUID,
  p_amount             NUMERIC,
  p_kind               TEXT,
  p_receipt_path       TEXT DEFAULT NULL,
  p_note               TEXT DEFAULT NULL,
  p_transfer_reference TEXT DEFAULT NULL,
  p_transferred_at     TIMESTAMPTZ DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE
  v_group_id       UUID;
  v_res            RECORD;
  v_wallet         RECORD;
  v_ya_pagado      NUMERIC;
  v_saldo_restante NUMERIC;
  v_disponible     NUMERIC;
  v_bucket         TEXT;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM profiles WHERE id = auth.uid() AND role = 'admin') THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_admin');
  END IF;

  IF p_kind NOT IN ('advance','final_settlement') THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_kind');
  END IF;
  IF p_amount IS NULL OR p_amount <= 0 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_amount');
  END IF;
  IF p_receipt_path IS NULL OR trim(p_receipt_path) = '' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'receipt_required');
  END IF;
  IF p_transferred_at IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'transferred_at_required');
  END IF;
  IF p_kind = 'final_settlement' AND COALESCE(trim(p_transfer_reference),'') = '' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'transfer_reference_required');
  END IF;

  SELECT group_id INTO v_group_id FROM reservations WHERE id = p_reservation_id;
  IF v_group_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_found');
  END IF;

  PERFORM pg_advisory_xact_lock(hashtext(v_group_id::text));

  SELECT * INTO v_res FROM reservations WHERE id = p_reservation_id FOR UPDATE;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_found');
  END IF;
  IF v_res.group_id IS DISTINCT FROM v_group_id THEN
    RETURN jsonb_build_object('ok', false, 'error', 'temporary_retry');
  END IF;

  IF v_res.currency_code IS NULL OR v_res.currency_code NOT IN ('MXN','USD') THEN
    RETURN jsonb_build_object('ok', false, 'error', 'unsupported_currency', 'currency_code', v_res.currency_code);
  END IF;

  IF v_res.payment_status NOT IN ('paid','fully_paid','deposit_paid') THEN
    RETURN jsonb_build_object('ok', false, 'error', 'payment_not_confirmed');
  END IF;

  IF p_kind = 'advance' THEN
    IF v_res.status NOT IN ('confirmed','completed') THEN
      RETURN jsonb_build_object('ok', false, 'error', 'reservation_status_not_eligible', 'status', v_res.status);
    END IF;
  ELSE
    IF v_res.status <> 'completed' THEN
      RETURN jsonb_build_object('ok', false, 'error', 'reservation_status_not_eligible', 'status', v_res.status);
    END IF;
  END IF;

  IF EXISTS (SELECT 1 FROM disputes WHERE reservation_id = p_reservation_id AND status IN ('open','under_review')) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'open_dispute_blocks_payment');
  END IF;

  IF EXISTS (
    SELECT 1 FROM provider_refund_claims
    WHERE reservation_id = p_reservation_id AND status IN ('processing','provider_succeeded')
  ) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'refund_in_progress');
  END IF;

  IF p_kind = 'advance' THEN
    IF v_res.payout_status <> 'held' THEN
      RETURN jsonb_build_object('ok', false, 'error', 'payout_status_not_eligible', 'payout_status', v_res.payout_status);
    END IF;
    v_bucket := CASE v_res.currency_code WHEN 'MXN' THEN 'pending' WHEN 'USD' THEN 'pending_usd' END;
  ELSE
    IF v_res.payout_status <> 'released' THEN
      RETURN jsonb_build_object('ok', false, 'error', 'payout_status_not_eligible', 'payout_status', v_res.payout_status);
    END IF;
    v_bucket := CASE v_res.currency_code WHEN 'MXN' THEN 'available' WHEN 'USD' THEN 'available_usd' END;

    IF NOT EXISTS (
      SELECT 1 FROM wallets w
      WHERE w.user_id = (SELECT owner_id FROM groups WHERE id = v_res.group_id)
        AND w.bank_clabe IS NOT NULL AND length(w.bank_clabe) = 18 AND w.bank_clabe ~ '^\d{18}$'
        AND w.bank_name IS NOT NULL AND length(trim(w.bank_name)) > 0
        AND w.account_holder IS NOT NULL AND length(trim(w.account_holder)) > 0
    ) THEN
      RETURN jsonb_build_object('ok', false, 'error', 'missing_bank_data');
    END IF;
  END IF;

  PERFORM ensure_group_wallet(v_res.group_id);
  SELECT * INTO v_wallet FROM group_wallets WHERE group_id = v_res.group_id FOR UPDATE;

  SELECT COALESCE(SUM(amount),0) INTO v_ya_pagado
  FROM group_reservation_payments WHERE reservation_id = p_reservation_id;
  v_saldo_restante := COALESCE(v_res.group_earnings,0) - v_ya_pagado;

  IF p_kind = 'final_settlement' THEN
    IF p_amount < v_saldo_restante THEN
      RETURN jsonb_build_object('ok', false, 'error', 'final_amount_must_match_balance',
        'saldo_restante', v_saldo_restante, 'monto_recibido', p_amount);
    ELSIF p_amount > v_saldo_restante THEN
      RETURN jsonb_build_object('ok', false, 'error', 'exceeds_group_earnings',
        'saldo_restante', v_saldo_restante, 'monto_recibido', p_amount);
    END IF;
  ELSE
    IF v_ya_pagado + p_amount > COALESCE(v_res.group_earnings,0) THEN
      RETURN jsonb_build_object('ok', false, 'error', 'exceeds_group_earnings',
        'ya_pagado', v_ya_pagado, 'group_earnings', v_res.group_earnings);
    END IF;
  END IF;

  v_disponible := CASE v_bucket
    WHEN 'pending'       THEN v_wallet.pending_balance
    WHEN 'available'     THEN v_wallet.available_balance
    WHEN 'pending_usd'   THEN v_wallet.pending_balance_usd
    WHEN 'available_usd' THEN v_wallet.available_balance_usd
  END;
  IF v_disponible < p_amount THEN
    RETURN jsonb_build_object('ok', false, 'error', 'insufficient_wallet_bucket',
      'bucket', v_bucket, 'disponible', v_disponible,
      'hint', 'Este grupo ya recibió este dinero por otra vía — revisa su historial antes de continuar');
  END IF;

  IF v_bucket = 'pending' THEN
    UPDATE group_wallets SET pending_balance = pending_balance - p_amount, updated_at = NOW() WHERE id = v_wallet.id;
  ELSIF v_bucket = 'available' THEN
    UPDATE group_wallets SET available_balance = available_balance - p_amount, updated_at = NOW() WHERE id = v_wallet.id;
  ELSIF v_bucket = 'pending_usd' THEN
    UPDATE group_wallets SET pending_balance_usd = pending_balance_usd - p_amount, updated_at = NOW() WHERE id = v_wallet.id;
  ELSIF v_bucket = 'available_usd' THEN
    UPDATE group_wallets SET available_balance_usd = available_balance_usd - p_amount, updated_at = NOW() WHERE id = v_wallet.id;
  END IF;

  INSERT INTO group_reservation_payments
    (reservation_id, group_id, amount, kind, wallet_bucket_debited, receipt_path, note, transfer_reference, transferred_at, registered_by)
  VALUES (p_reservation_id, v_res.group_id, p_amount, p_kind, v_bucket, p_receipt_path, p_note, p_transfer_reference, p_transferred_at, auth.uid());

  INSERT INTO wallet_transactions (group_wallet_id, group_id, type, amount, reservation_id, description, balance_after, currency_code)
  SELECT gw.id, gw.group_id,
    CASE WHEN p_kind = 'advance' THEN 'manual_advance' ELSE 'final_settlement' END,
    p_amount, p_reservation_id,
    CASE WHEN p_kind = 'advance'
      THEN format('Anticipo manual registrado — reserva %s', p_reservation_id)
      ELSE format('Liquidación final registrada — reserva %s (ref %s)', p_reservation_id, p_transfer_reference)
    END,
    CASE v_bucket
      WHEN 'pending'       THEN gw.pending_balance
      WHEN 'available'     THEN gw.available_balance
      WHEN 'pending_usd'   THEN gw.pending_balance_usd
      WHEN 'available_usd' THEN gw.available_balance_usd
    END,
    v_res.currency_code
  FROM group_wallets gw WHERE gw.id = v_wallet.id;

  INSERT INTO financial_audit_logs (entity_type, entity_id, action, actor_id, actor_role, amount, notes)
  VALUES ('reservation', p_reservation_id, p_kind, auth.uid(), 'admin', p_amount,
    format('bucket=%s currency=%s receipt=%s ref=%s transferred_at=%s', v_bucket, v_res.currency_code, COALESCE(p_receipt_path,'n/a'), COALESCE(p_transfer_reference,'n/a'), p_transferred_at));

  IF (v_ya_pagado + p_amount) >= COALESCE(v_res.group_earnings,0) THEN
    UPDATE group_payment_requests SET status = 'completed'
    WHERE reservation_id = p_reservation_id AND status = 'pending';
  END IF;

  INSERT INTO notifications (user_id, type, title, body, data)
  SELECT g.owner_id, 'payment',
    CASE WHEN p_kind = 'advance' THEN '💵 Anticipo recibido' ELSE '✅ Pago realizado' END,
    CASE WHEN p_kind = 'advance'
      THEN format('Recibiste un anticipo de $%s %s para tu evento del %s.', p_amount, v_res.currency_code, v_res.event_date)
      ELSE format('Se transfirió el pago final de $%s %s para tu evento del %s. ¡Liquidado!', p_amount, v_res.currency_code, v_res.event_date)
    END,
    jsonb_build_object('reservation_id', p_reservation_id, 'screen', 'Wallet')
  FROM groups g WHERE g.id = v_res.group_id;

  RETURN jsonb_build_object(
    'ok', true, 'kind', p_kind, 'bucket_debitado', v_bucket, 'currency', v_res.currency_code,
    'total_pagado', v_ya_pagado + p_amount,
    'saldo_restante', COALESCE(v_res.group_earnings,0) - (v_ya_pagado + p_amount)
  );
END;
$function$;

-- ── release_group_earnings_atomic ─────────────────────────────
CREATE OR REPLACE FUNCTION public.release_group_earnings_atomic(p_reservation_id uuid, p_released_by uuid DEFAULT NULL::uuid)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE
  v_reservation RECORD;
  v_wallet      RECORD;
  v_total       NUMERIC;
  v_to_release  NUMERIC;
  v_actor_role  TEXT := 'system';
  v_currency    TEXT;
  v_ya_anticipado_pending NUMERIC;
BEGIN
  SELECT * INTO v_reservation FROM reservations WHERE id = p_reservation_id FOR UPDATE;
  IF NOT FOUND THEN RETURN jsonb_build_object('ok', false, 'error', 'not_found'); END IF;

  IF v_reservation.payout_status = 'released' THEN
    RETURN jsonb_build_object('ok', true, 'skipped', true, 'reason', 'already_released');
  END IF;
  IF v_reservation.payout_status IN ('blocked','refunded') THEN
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
    RETURN jsonb_build_object('ok', false, 'error', 'open_dispute_blocks_release');
  END IF;

  IF NOT (v_reservation.group_arrived_at IS NOT NULL OR COALESCE(v_reservation.arrival_verified, false)) THEN
    RETURN jsonb_build_object('ok', true, 'skipped', true, 'reason', 'no_arrival_verification');
  END IF;

  IF v_reservation.currency_code IS NULL OR v_reservation.currency_code NOT IN ('MXN','USD') THEN
    RETURN jsonb_build_object('ok', false, 'error', 'unsupported_currency', 'currency_code', v_reservation.currency_code);
  END IF;
  v_currency := v_reservation.currency_code;

  IF p_released_by IS NOT NULL THEN
    SELECT COALESCE(role,'unknown') INTO v_actor_role FROM profiles WHERE id = p_released_by;
  END IF;

  PERFORM ensure_group_wallet(v_reservation.group_id);
  SELECT * INTO v_wallet FROM group_wallets WHERE group_id = v_reservation.group_id FOR UPDATE;

  v_total := COALESCE(v_reservation.group_earnings,
               COALESCE(v_reservation.base_price,
                 ROUND(v_reservation.total_price * 0.9, 2)));
  v_to_release := CASE
    WHEN v_reservation.payout_status = 'half_released' THEN v_total - ROUND(v_total / 2, 2)
    ELSE v_total
  END;

  SELECT COALESCE(SUM(amount),0) INTO v_ya_anticipado_pending
  FROM group_reservation_payments
  WHERE reservation_id = p_reservation_id AND wallet_bucket_debited IN ('pending','pending_usd');

  v_to_release := GREATEST(0, v_to_release - v_ya_anticipado_pending);

  CASE v_currency
    WHEN 'MXN' THEN
      UPDATE group_wallets SET
        pending_balance   = GREATEST(0, pending_balance - v_to_release),
        available_balance = available_balance + v_to_release,
        updated_at        = NOW()
      WHERE id = v_wallet.id;
    WHEN 'USD' THEN
      UPDATE group_wallets SET
        pending_balance_usd   = GREATEST(0, pending_balance_usd - v_to_release),
        available_balance_usd = available_balance_usd + v_to_release,
        updated_at            = NOW()
      WHERE id = v_wallet.id;
  END CASE;

  UPDATE reservations SET
    payout_status = 'released', released_at = NOW(),
    released_by = p_released_by, wallet_released_at = NOW(), updated_at = NOW()
  WHERE id = p_reservation_id;

  IF v_to_release > 0 THEN
    INSERT INTO wallet_transactions
      (group_wallet_id, group_id, type, amount, reservation_id, description, balance_after, currency_code)
    VALUES (v_wallet.id, v_reservation.group_id, 'credit_available', v_to_release,
      p_reservation_id,
      CASE WHEN v_reservation.payout_status = 'half_released'
        THEN format('50%% final al terminar evento — reserva %s', p_reservation_id)
        ELSE format('Ganancias liberadas post-evento — reserva %s', p_reservation_id)
      END,
      CASE WHEN v_currency = 'USD'
        THEN v_wallet.available_balance_usd + v_to_release
        ELSE v_wallet.available_balance + v_to_release
      END,
      v_currency);
  END IF;

  INSERT INTO financial_audit_logs
    (entity_type, entity_id, action, actor_id, actor_role, amount, notes)
  VALUES ('reservation', p_reservation_id, 'release', p_released_by, v_actor_role, v_to_release,
    format('currency=%s payout_status_was=%s anticipado_pending=%s', v_currency, v_reservation.payout_status, v_ya_anticipado_pending));

  IF v_to_release > 0 THEN
    INSERT INTO notifications (user_id, type, title, body, data)
    SELECT g.owner_id, 'payout', '🎉 Ganancias liberadas',
      format('$%s %s disponibles en tu billetera.',
        to_char(v_to_release, 'FM999,999,990'), v_currency),
      jsonb_build_object('screen','Wallet','reservation_id',p_reservation_id)
    FROM groups g WHERE g.id = v_reservation.group_id;
  END IF;

  RETURN jsonb_build_object(
    'ok',            true,
    'released',      v_to_release,
    'currency',      v_currency,
    'payout_status', 'released'
  );
END;
$function$;

COMMIT;

SELECT '535_p1f_hardening PARTE 1 (tabla+claim+admin_register+release) ✅' AS status;
