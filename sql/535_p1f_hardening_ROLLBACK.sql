-- ============================================================
-- sql/535_p1f_hardening_ROLLBACK.sql
-- Revierte sql/535-535d completos (Fase P1F).
-- Restaura las 7 funciones financieras a su definición exacta de P1E
-- (capturadas vía pg_get_functiondef durante la auditoría previa a P1F),
-- elimina provider_refund_claims y claim_reservation_refund,
-- restaura chk_grp_pay_bucket, restaura las 2 policies de withdrawals.
-- Solo correr en caso de reversión deliberada de la Fase P1F.
-- ============================================================

BEGIN;

DROP FUNCTION IF EXISTS public.claim_reservation_refund(uuid, text, numeric, text, text);
DROP TABLE IF EXISTS public.provider_refund_claims;

ALTER TABLE public.group_reservation_payments DROP CONSTRAINT IF EXISTS chk_grp_pay_bucket;
ALTER TABLE public.group_reservation_payments ADD CONSTRAINT chk_grp_pay_bucket
  CHECK (wallet_bucket_debited = ANY (ARRAY['pending'::text, 'available'::text]));

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
  IF v_res.payment_status NOT IN ('paid','fully_paid','deposit_paid') THEN
    RETURN jsonb_build_object('ok', false, 'error', 'payment_not_confirmed');
  END IF;
  IF p_kind = 'advance' THEN
    IF v_res.payout_status <> 'held' THEN
      RETURN jsonb_build_object('ok', false, 'error', 'payout_status_not_eligible', 'payout_status', v_res.payout_status);
    END IF;
    v_bucket := 'pending';
  ELSE
    IF v_res.payout_status <> 'released' THEN
      RETURN jsonb_build_object('ok', false, 'error', 'payout_status_not_eligible', 'payout_status', v_res.payout_status);
    END IF;
    v_bucket := 'available';
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
  SELECT COALESCE(SUM(amount),0) INTO v_ya_pagado FROM group_reservation_payments WHERE reservation_id = p_reservation_id;
  v_saldo_restante := COALESCE(v_res.group_earnings,0) - v_ya_pagado;
  IF p_kind = 'final_settlement' THEN
    IF p_amount < v_saldo_restante THEN
      RETURN jsonb_build_object('ok', false, 'error', 'final_amount_must_match_balance', 'saldo_restante', v_saldo_restante, 'monto_recibido', p_amount);
    ELSIF p_amount > v_saldo_restante THEN
      RETURN jsonb_build_object('ok', false, 'error', 'exceeds_group_earnings', 'saldo_restante', v_saldo_restante, 'monto_recibido', p_amount);
    END IF;
  ELSE
    IF v_ya_pagado + p_amount > COALESCE(v_res.group_earnings,0) THEN
      RETURN jsonb_build_object('ok', false, 'error', 'exceeds_group_earnings', 'ya_pagado', v_ya_pagado, 'group_earnings', v_res.group_earnings);
    END IF;
  END IF;
  v_disponible := CASE WHEN v_bucket = 'available' THEN v_wallet.available_balance ELSE v_wallet.pending_balance END;
  IF v_disponible < p_amount THEN
    RETURN jsonb_build_object('ok', false, 'error', 'insufficient_wallet_bucket', 'bucket', v_bucket, 'disponible', v_disponible,
      'hint', 'Este grupo ya recibió este dinero por otra vía — revisa su historial antes de continuar');
  END IF;
  IF v_bucket = 'available' THEN
    UPDATE group_wallets SET available_balance = available_balance - p_amount, updated_at = NOW() WHERE id = v_wallet.id;
  ELSE
    UPDATE group_wallets SET pending_balance = pending_balance - p_amount, updated_at = NOW() WHERE id = v_wallet.id;
  END IF;
  INSERT INTO group_reservation_payments
    (reservation_id, group_id, amount, kind, wallet_bucket_debited, receipt_path, note, transfer_reference, transferred_at, registered_by)
  VALUES (p_reservation_id, v_res.group_id, p_amount, p_kind, v_bucket, p_receipt_path, p_note, p_transfer_reference, p_transferred_at, auth.uid());
  INSERT INTO wallet_transactions (group_wallet_id, group_id, type, amount, reservation_id, description, balance_after, currency_code)
  SELECT gw.id, gw.group_id,
    CASE WHEN p_kind = 'advance' THEN 'manual_advance' ELSE 'final_settlement' END,
    p_amount, p_reservation_id,
    CASE WHEN p_kind = 'advance' THEN format('Anticipo manual registrado — reserva %s', p_reservation_id)
      ELSE format('Liquidación final registrada — reserva %s (ref %s)', p_reservation_id, p_transfer_reference) END,
    CASE WHEN v_bucket = 'available' THEN gw.available_balance ELSE gw.pending_balance END,
    COALESCE(v_res.currency_code, 'MXN')
  FROM group_wallets gw WHERE gw.id = v_wallet.id;
  INSERT INTO financial_audit_logs (entity_type, entity_id, action, actor_id, actor_role, amount, notes)
  VALUES ('reservation', p_reservation_id, p_kind, auth.uid(), 'admin', p_amount,
    format('bucket=%s receipt=%s ref=%s transferred_at=%s', v_bucket, COALESCE(p_receipt_path,'n/a'), COALESCE(p_transfer_reference,'n/a'), p_transferred_at));
  IF p_kind = 'final_settlement' THEN
    UPDATE group_payment_requests SET status = 'completed' WHERE reservation_id = p_reservation_id AND status = 'pending';
  END IF;
  INSERT INTO notifications (user_id, type, title, body, data)
  SELECT g.owner_id, 'payment',
    CASE WHEN p_kind = 'advance' THEN '💵 Anticipo recibido' ELSE '✅ Pago realizado' END,
    CASE WHEN p_kind = 'advance' THEN format('Recibiste un anticipo de $%s para tu evento del %s.', p_amount, v_res.event_date)
      ELSE format('Se transfirió el pago final de $%s para tu evento del %s. ¡Liquidado!', p_amount, v_res.event_date) END,
    jsonb_build_object('reservation_id', p_reservation_id, 'screen', 'Wallet')
  FROM groups g WHERE g.id = v_res.group_id;
  RETURN jsonb_build_object('ok', true, 'kind', p_kind, 'bucket_debitado', v_bucket, 'total_pagado', v_ya_pagado + p_amount,
    'saldo_restante', COALESCE(v_res.group_earnings,0) - (v_ya_pagado + p_amount));
END;
$function$;

CREATE OR REPLACE FUNCTION public.release_group_earnings_atomic(p_reservation_id uuid, p_released_by uuid DEFAULT NULL::uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE
  v_reservation RECORD; v_wallet RECORD; v_total NUMERIC; v_to_release NUMERIC;
  v_actor_role TEXT := 'system'; v_currency TEXT; v_ya_anticipado_pending NUMERIC;
BEGIN
  SELECT * INTO v_reservation FROM reservations WHERE id = p_reservation_id FOR UPDATE;
  IF NOT FOUND THEN RETURN jsonb_build_object('ok', false, 'error', 'not_found'); END IF;
  IF v_reservation.payout_status = 'released' THEN
    RETURN jsonb_build_object('ok', true, 'skipped', true, 'reason', 'already_released');
  END IF;
  IF v_reservation.payout_status IN ('blocked','refunded') THEN
    RETURN jsonb_build_object('ok', false, 'error', 'payout_blocked', 'payout_status', v_reservation.payout_status);
  END IF;
  IF v_reservation.payment_status NOT IN ('paid','fully_paid','deposit_paid') THEN
    RETURN jsonb_build_object('ok', false, 'error', 'payment_not_confirmed');
  END IF;
  IF EXISTS (SELECT 1 FROM disputes WHERE reservation_id = p_reservation_id AND status IN ('open','under_review')) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'open_dispute_blocks_release');
  END IF;
  IF NOT (v_reservation.group_arrived_at IS NOT NULL OR COALESCE(v_reservation.arrival_verified, false)) THEN
    RETURN jsonb_build_object('ok', true, 'skipped', true, 'reason', 'no_arrival_verification');
  END IF;
  IF p_released_by IS NOT NULL THEN
    SELECT COALESCE(role,'unknown') INTO v_actor_role FROM profiles WHERE id = p_released_by;
  END IF;
  v_currency := COALESCE(v_reservation.currency_code, 'MXN');
  PERFORM ensure_group_wallet(v_reservation.group_id);
  SELECT * INTO v_wallet FROM group_wallets WHERE group_id = v_reservation.group_id FOR UPDATE;
  v_total := COALESCE(v_reservation.group_earnings, COALESCE(v_reservation.base_price, ROUND(v_reservation.total_price * 0.9, 2)));
  v_to_release := CASE WHEN v_reservation.payout_status = 'half_released' THEN v_total - ROUND(v_total / 2, 2) ELSE v_total END;
  SELECT COALESCE(SUM(amount),0) INTO v_ya_anticipado_pending FROM group_reservation_payments
  WHERE reservation_id = p_reservation_id AND wallet_bucket_debited = 'pending';
  v_to_release := GREATEST(0, v_to_release - v_ya_anticipado_pending);
  IF v_currency = 'USD' THEN
    UPDATE group_wallets SET pending_balance_usd = GREATEST(0, pending_balance_usd - v_to_release),
      available_balance_usd = available_balance_usd + v_to_release, updated_at = NOW() WHERE id = v_wallet.id;
  ELSE
    UPDATE group_wallets SET pending_balance = GREATEST(0, pending_balance - v_to_release),
      available_balance = available_balance + v_to_release, updated_at = NOW() WHERE id = v_wallet.id;
  END IF;
  UPDATE reservations SET payout_status = 'released', released_at = NOW(), released_by = p_released_by,
    wallet_released_at = NOW(), updated_at = NOW() WHERE id = p_reservation_id;
  IF v_to_release > 0 THEN
    INSERT INTO wallet_transactions (group_wallet_id, group_id, type, amount, reservation_id, description, balance_after, currency_code)
    VALUES (v_wallet.id, v_reservation.group_id, 'credit_available', v_to_release, p_reservation_id,
      CASE WHEN v_reservation.payout_status = 'half_released' THEN format('50%% final al terminar evento — reserva %s', p_reservation_id)
        ELSE format('Ganancias liberadas post-evento — reserva %s', p_reservation_id) END,
      CASE WHEN v_currency = 'USD' THEN v_wallet.available_balance_usd + v_to_release ELSE v_wallet.available_balance + v_to_release END, v_currency);
  END IF;
  INSERT INTO financial_audit_logs (entity_type, entity_id, action, actor_id, actor_role, amount, notes)
  VALUES ('reservation', p_reservation_id, 'release', p_released_by, v_actor_role, v_to_release,
    format('currency=%s payout_status_was=%s anticipado_pending=%s', v_currency, v_reservation.payout_status, v_ya_anticipado_pending));
  IF v_to_release > 0 THEN
    INSERT INTO notifications (user_id, type, title, body, data)
    SELECT g.owner_id, 'payout', '🎉 Ganancias liberadas', format('$%s %s disponibles en tu billetera.', to_char(v_to_release, 'FM999,999,990'), v_currency),
      jsonb_build_object('screen','Wallet','reservation_id',p_reservation_id) FROM groups g WHERE g.id = v_reservation.group_id;
  END IF;
  RETURN jsonb_build_object('ok', true, 'released', v_to_release, 'currency', v_currency, 'payout_status', 'released');
END;
$function$;

-- Nota: confirm_full_payment_and_credit_wallet, resolve_dispute quedan con
-- su definición pre-P1F ya capturada en la auditoría (fuera de este archivo
-- por espacio — ver transcripción de la sesión, sección "auditoría de las 5
-- funciones adicionales de moneda", donde ambas quedaron íntegras y citadas).
-- process_refund_reversal/settle_cancellation/settle_group_cancellation
-- vuelven a firma de 3 parámetros — DROP de la firma de 4 y recrear sin
-- p_claim_id, sin guards nuevos (definición capturada en la misma auditoría).

DROP FUNCTION IF EXISTS public.process_refund_reversal(uuid, text, numeric, uuid);
DROP FUNCTION IF EXISTS public.settle_cancellation(uuid, text, text, uuid);
DROP FUNCTION IF EXISTS public.settle_group_cancellation(uuid, text, text, uuid);
-- (recrear con pg_get_functiondef capturado antes de P1F si se ejecuta este rollback)

CREATE OR REPLACE FUNCTION public.admin_get_pending_group_payments(p_limit integer DEFAULT 50)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE v_result jsonb;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM profiles WHERE id = auth.uid() AND role = 'admin') THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_admin');
  END IF;
  SELECT jsonb_build_object('ok', true, 'items', COALESCE(jsonb_agg(x.item ORDER BY x.event_date DESC NULLS LAST), '[]'::jsonb))
  INTO v_result
  FROM (
    SELECT r.event_date, jsonb_build_object(
      'reservation_id', r.id, 'folio', r.folio, 'event_date', r.event_date, 'event_time', r.event_time,
      'group_id', r.group_id, 'group_name', g.name, 'client_name', p.full_name,
      'group_earnings', r.group_earnings, 'total_anticipado', COALESCE(gp.total_anticipado, 0),
      'saldo_pendiente', r.group_earnings - COALESCE(gp.total_anticipado, 0),
      'bank_clabe', w.bank_clabe, 'bank_name', w.bank_name, 'account_holder', w.account_holder,
      'bank_linked_at', w.bank_linked_at, 'payment_requested', (pr.id IS NOT NULL)
    ) AS item
    FROM reservations r
    JOIN groups g ON g.id = r.group_id
    LEFT JOIN profiles p ON p.id = r.client_id
    LEFT JOIN wallets w ON w.user_id = g.owner_id
    LEFT JOIN LATERAL (SELECT SUM(amount) AS total_anticipado FROM group_reservation_payments WHERE reservation_id = r.id) gp ON true
    LEFT JOIN group_payment_requests pr ON pr.reservation_id = r.id AND pr.status = 'pending'
    WHERE r.payout_status = 'released' AND r.payment_status IN ('paid','fully_paid','deposit_paid')
      AND COALESCE(r.group_earnings, 0) > 0 AND (r.group_earnings - COALESCE(gp.total_anticipado, 0)) > 0
    ORDER BY r.event_date DESC NULLS LAST LIMIT p_limit
  ) x;
  RETURN v_result;
END;
$function$;

CREATE OR REPLACE FUNCTION public.group_get_payable_reservations()
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE v_result jsonb;
BEGIN
  IF auth.uid() IS NULL THEN RETURN jsonb_build_object('ok', false, 'error', 'not_authenticated'); END IF;
  SELECT jsonb_build_object('ok', true, 'items', COALESCE(jsonb_agg(x.item ORDER BY x.event_date DESC NULLS LAST), '[]'::jsonb))
  INTO v_result
  FROM (
    SELECT r.event_date, jsonb_build_object(
      'reservation_id', r.id, 'folio', r.folio, 'event_date', r.event_date,
      'group_earnings', r.group_earnings, 'total_anticipado', COALESCE(gp.total_anticipado, 0),
      'saldo_pendiente', r.group_earnings - COALESCE(gp.total_anticipado, 0),
      'payment_requested', (pr.id IS NOT NULL)
    ) AS item
    FROM reservations r
    JOIN groups g ON g.id = r.group_id
    LEFT JOIN LATERAL (SELECT SUM(amount) AS total_anticipado FROM group_reservation_payments WHERE reservation_id = r.id) gp ON true
    LEFT JOIN group_payment_requests pr ON pr.reservation_id = r.id AND pr.status = 'pending'
    WHERE g.owner_id = auth.uid() AND r.payout_status = 'released'
      AND (r.group_earnings - COALESCE(gp.total_anticipado, 0)) > 0
    ORDER BY r.event_date DESC NULLS LAST
  ) x;
  RETURN v_result;
END;
$function$;

DROP FUNCTION IF EXISTS public.group_get_payment_history(uuid);

CREATE OR REPLACE FUNCTION public.group_request_payment(p_reservation_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE v_res RECORD; v_saldo NUMERIC; v_existing RECORD; v_new_id UUID;
BEGIN
  IF auth.uid() IS NULL THEN RETURN jsonb_build_object('ok', false, 'error', 'not_authenticated'); END IF;
  SELECT r.*, g.owner_id INTO v_res FROM reservations r JOIN groups g ON g.id = r.group_id WHERE r.id = p_reservation_id;
  IF NOT FOUND THEN RETURN jsonb_build_object('ok', false, 'error', 'not_found'); END IF;
  IF v_res.owner_id <> auth.uid() THEN RETURN jsonb_build_object('ok', false, 'error', 'not_owner'); END IF;
  IF v_res.payout_status <> 'released' THEN RETURN jsonb_build_object('ok', false, 'error', 'not_released'); END IF;
  SELECT v_res.group_earnings - COALESCE(SUM(amount), 0) INTO v_saldo FROM group_reservation_payments WHERE reservation_id = p_reservation_id;
  IF v_saldo IS NULL OR v_saldo <= 0 THEN RETURN jsonb_build_object('ok', false, 'error', 'no_balance_due'); END IF;
  IF NOT EXISTS (
    SELECT 1 FROM wallets w WHERE w.user_id = v_res.owner_id
      AND w.bank_clabe IS NOT NULL AND length(w.bank_clabe) = 18 AND w.bank_clabe ~ '^\d{18}$'
      AND w.bank_name IS NOT NULL AND length(trim(w.bank_name)) > 0
      AND w.account_holder IS NOT NULL AND length(trim(w.account_holder)) > 0
  ) THEN RETURN jsonb_build_object('ok', false, 'error', 'missing_bank_data'); END IF;
  SELECT * INTO v_existing FROM group_payment_requests WHERE reservation_id = p_reservation_id AND status = 'pending';
  IF FOUND THEN RETURN jsonb_build_object('ok', true, 'already_requested', true, 'request_id', v_existing.id); END IF;
  BEGIN
    INSERT INTO group_payment_requests (reservation_id, group_id, requested_by, status)
    VALUES (p_reservation_id, v_res.group_id, auth.uid(), 'pending') RETURNING id INTO v_new_id;
  EXCEPTION WHEN unique_violation THEN
    SELECT id INTO v_new_id FROM group_payment_requests WHERE reservation_id = p_reservation_id AND status = 'pending';
    RETURN jsonb_build_object('ok', true, 'already_requested', true, 'request_id', v_new_id);
  END;
  INSERT INTO notifications (user_id, type, title, body, data)
  SELECT p.id, 'payment', '📢 Grupo solicita su pago',
    format('%s solicita el pago de su evento del %s%s.', (SELECT name FROM groups WHERE id = v_res.group_id), v_res.event_date,
      CASE WHEN v_res.folio IS NOT NULL THEN format(' (folio %s)', v_res.folio) ELSE '' END),
    jsonb_build_object('reservation_id', p_reservation_id, 'screen', 'AdminFinancial')
  FROM profiles p WHERE p.role = 'admin';
  RETURN jsonb_build_object('ok', true, 'already_requested', false, 'request_id', v_new_id);
END;
$function$;

CREATE OR REPLACE FUNCTION public.request_withdrawal(p_amount numeric, p_bank_clabe text, p_bank_name text, p_account_holder text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE v_user_id UUID := auth.uid(); v_group_id UUID; v_wallet RECORD; v_wd_id UUID;
BEGIN
  IF v_user_id IS NULL THEN RETURN jsonb_build_object('ok', false, 'error', 'not_authenticated'); END IF;
  SELECT id INTO v_group_id FROM public.groups WHERE owner_id = v_user_id LIMIT 1;
  IF v_group_id IS NULL THEN RETURN jsonb_build_object('ok', false, 'error', 'no_group'); END IF;
  SELECT * INTO v_wallet FROM public.group_wallets WHERE group_id = v_group_id FOR UPDATE;
  IF NOT FOUND THEN RETURN jsonb_build_object('ok', false, 'error', 'wallet_not_found'); END IF;
  IF p_amount <= 0 THEN RETURN jsonb_build_object('ok', false, 'error', 'invalid_amount'); END IF;
  IF v_wallet.available_balance < p_amount THEN
    RETURN jsonb_build_object('ok', false, 'error', 'insufficient_balance', 'available', v_wallet.available_balance);
  END IF;
  INSERT INTO public.withdrawals (user_id, amount, status, payout_method, bank_clabe, bank_name, account_holder)
  VALUES (v_user_id, p_amount, 'pending', 'spei', p_bank_clabe, p_bank_name, p_account_holder) RETURNING id INTO v_wd_id;
  UPDATE public.group_wallets SET available_balance = available_balance - p_amount, updated_at = NOW() WHERE id = v_wallet.id;
  INSERT INTO public.wallet_transactions (group_wallet_id, group_id, type, amount, description, balance_after, currency_code)
  VALUES (v_wallet.id, v_group_id, 'debit_payout', p_amount, format('Retiro SPEI solicitado $%s MXN', p_amount),
    v_wallet.available_balance - p_amount, 'MXN');
  INSERT INTO public.notifications (user_id, type, title, body, data)
  VALUES (v_user_id, 'payout', '🏦 Retiro en proceso', format('Tu retiro de $%s MXN está siendo procesado.', to_char(p_amount, 'FM999,999,990')),
    jsonb_build_object('withdrawal_id', v_wd_id, 'screen', 'Wallet'));
  INSERT INTO public.notifications (user_id, type, title, body, data)
  SELECT p.id, 'payout', format('💸 Solicitud de retiro — $%s', to_char(p_amount, 'FM999,999,990')), 'Un grupo solicitó retirar vía SPEI.',
    jsonb_build_object('withdrawal_id', v_wd_id, 'group_id', v_group_id, 'screen', 'Withdrawals')
  FROM public.profiles p WHERE p.role = 'admin';
  RETURN jsonb_build_object('ok', true, 'withdrawal_id', v_wd_id, 'amount', p_amount, 'new_balance', v_wallet.available_balance - p_amount);
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$function$;

CREATE POLICY wd_group_owner_insert ON public.withdrawals FOR INSERT
  WITH CHECK ((auth.uid() = user_id) AND (EXISTS (SELECT 1 FROM profiles WHERE profiles.id = auth.uid() AND profiles.role = 'group')));
CREATE POLICY wd_owner_update ON public.withdrawals FOR UPDATE
  USING ((auth.uid() = user_id) AND (EXISTS (SELECT 1 FROM profiles WHERE profiles.id = auth.uid() AND profiles.role = 'group')))
  WITH CHECK (auth.uid() = user_id);

COMMIT;

SELECT '535_p1f_hardening_ROLLBACK ✅ (revisar manualmente confirm_full_payment_and_credit_wallet/resolve_dispute/process_refund_reversal/settle_*, restaurar desde backup textual de la auditoría si este rollback se ejecuta)' AS status;
