-- ============================================================
-- sql/535d_p1f_hardening_part4.sql — continuación de 535c
-- admin_get_pending_group_payments, group_get_payable_reservations,
-- group_request_payment, request_withdrawal, RLS withdrawals.
-- ============================================================

BEGIN;

-- ── admin_get_pending_group_payments ──────────────────────────
-- + status allowlist (completed only), + filtro de disputas abiertas,
-- + filtro de provider_refund_claims activo, + currency_code, + owner_id.
CREATE OR REPLACE FUNCTION public.admin_get_pending_group_payments(p_limit integer DEFAULT 50)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE
  v_result jsonb;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM profiles WHERE id = auth.uid() AND role = 'admin') THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_admin');
  END IF;

  SELECT jsonb_build_object(
    'ok', true,
    'items', COALESCE(jsonb_agg(x.item ORDER BY x.event_date DESC NULLS LAST), '[]'::jsonb)
  )
  INTO v_result
  FROM (
    SELECT
      r.event_date,
      jsonb_build_object(
        'reservation_id',   r.id,
        'folio',            r.folio,
        'event_date',       r.event_date,
        'event_time',       r.event_time,
        'group_id',         r.group_id,
        'group_name',       g.name,
        'owner_id',         g.owner_id,
        'client_name',      p.full_name,
        'currency_code',    r.currency_code,
        'group_earnings',   r.group_earnings,
        'total_anticipado', COALESCE(gp.total_anticipado, 0),
        'saldo_pendiente',  r.group_earnings - COALESCE(gp.total_anticipado, 0),
        'bank_clabe',       w.bank_clabe,
        'bank_name',        w.bank_name,
        'account_holder',   w.account_holder,
        'bank_linked_at',   w.bank_linked_at,
        'payment_requested', (pr.id IS NOT NULL),
        'refund_claim_status', rc.status
      ) AS item
    FROM reservations r
    JOIN      groups   g ON g.id = r.group_id
    LEFT JOIN profiles p ON p.id = r.client_id
    LEFT JOIN wallets   w ON w.user_id = g.owner_id
    LEFT JOIN LATERAL (
      SELECT SUM(amount) AS total_anticipado
      FROM group_reservation_payments
      WHERE reservation_id = r.id
    ) gp ON true
    LEFT JOIN group_payment_requests pr ON pr.reservation_id = r.id AND pr.status = 'pending'
    LEFT JOIN LATERAL (
      SELECT status FROM provider_refund_claims
      WHERE reservation_id = r.id AND status IN ('processing','provider_succeeded')
      ORDER BY created_at DESC LIMIT 1
    ) rc ON true
    WHERE r.payout_status  = 'released'
      AND r.status         = 'completed'
      AND r.payment_status IN ('paid','fully_paid','deposit_paid')
      AND COALESCE(r.group_earnings, 0) > 0
      AND (r.group_earnings - COALESCE(gp.total_anticipado, 0)) > 0
      AND NOT EXISTS (
        SELECT 1 FROM disputes d WHERE d.reservation_id = r.id AND d.status IN ('open','under_review')
      )
    ORDER BY r.event_date DESC NULLS LAST
    LIMIT p_limit
  ) x;

  RETURN v_result;
END;
$function$;

-- ── group_get_payable_reservations ────────────────────────────
CREATE OR REPLACE FUNCTION public.group_get_payable_reservations()
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE v_result jsonb;
BEGIN
  IF auth.uid() IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_authenticated');
  END IF;

  SELECT jsonb_build_object('ok', true, 'items', COALESCE(jsonb_agg(x.item ORDER BY x.event_date DESC NULLS LAST), '[]'::jsonb))
  INTO v_result
  FROM (
    SELECT r.event_date, jsonb_build_object(
      'reservation_id',   r.id,
      'folio',            r.folio,
      'event_date',       r.event_date,
      'currency_code',    r.currency_code,
      'group_earnings',   r.group_earnings,
      'total_anticipado', COALESCE(gp.total_anticipado, 0),
      'saldo_pendiente',  r.group_earnings - COALESCE(gp.total_anticipado, 0),
      'payment_requested', (pr.id IS NOT NULL),
      'blocked_reason', CASE
        WHEN dp.id IS NOT NULL THEN 'dispute'
        WHEN rc.id IS NOT NULL THEN 'refund_in_progress'
        ELSE NULL
      END
    ) AS item
    FROM reservations r
    JOIN groups g ON g.id = r.group_id
    LEFT JOIN LATERAL (
      SELECT SUM(amount) AS total_anticipado FROM group_reservation_payments WHERE reservation_id = r.id
    ) gp ON true
    LEFT JOIN group_payment_requests pr ON pr.reservation_id = r.id AND pr.status = 'pending'
    LEFT JOIN LATERAL (
      SELECT id FROM disputes WHERE reservation_id = r.id AND status IN ('open','under_review') LIMIT 1
    ) dp ON true
    LEFT JOIN LATERAL (
      SELECT id FROM provider_refund_claims WHERE reservation_id = r.id AND status IN ('processing','provider_succeeded') LIMIT 1
    ) rc ON true
    WHERE g.owner_id = auth.uid()
      AND r.payout_status = 'released'
      AND r.status = 'completed'
      AND (r.group_earnings - COALESCE(gp.total_anticipado, 0)) > 0
    ORDER BY r.event_date DESC NULLS LAST
  ) x;

  RETURN v_result;
END;
$function$;

-- ── group_get_payment_history (nueva, para historial B3) ──────
CREATE FUNCTION public.group_get_payment_history(p_reservation_id UUID DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE v_result jsonb;
BEGIN
  IF auth.uid() IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_authenticated');
  END IF;

  SELECT jsonb_build_object('ok', true, 'items', COALESCE(jsonb_agg(x.item ORDER BY x.created_at DESC), '[]'::jsonb))
  INTO v_result
  FROM (
    SELECT grp.created_at, jsonb_build_object(
      'id', grp.id,
      'reservation_id', grp.reservation_id,
      'kind', grp.kind,
      'amount', grp.amount,
      'currency_code', r.currency_code,
      'transferred_at', grp.transferred_at,
      'transfer_reference', grp.transfer_reference,
      'has_receipt', grp.receipt_path IS NOT NULL,
      'receipt_path', grp.receipt_path
    ) AS item
    FROM group_reservation_payments grp
    JOIN groups g ON g.id = grp.group_id
    JOIN reservations r ON r.id = grp.reservation_id
    WHERE g.owner_id = auth.uid()
      AND (p_reservation_id IS NULL OR grp.reservation_id = p_reservation_id)
  ) x;

  RETURN v_result;
END;
$function$;

-- ── group_request_payment ─────────────────────────────────────
CREATE OR REPLACE FUNCTION public.group_request_payment(p_reservation_id uuid)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE
  v_res      RECORD;
  v_saldo    NUMERIC;
  v_existing RECORD;
  v_new_id   UUID;
BEGIN
  IF auth.uid() IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_authenticated');
  END IF;

  SELECT r.*, g.owner_id INTO v_res
  FROM reservations r JOIN groups g ON g.id = r.group_id
  WHERE r.id = p_reservation_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_found');
  END IF;

  IF v_res.owner_id <> auth.uid() THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_owner');
  END IF;

  IF v_res.status <> 'completed' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'reservation_status_not_eligible', 'status', v_res.status);
  END IF;

  IF v_res.payout_status <> 'released' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_released');
  END IF;

  IF EXISTS (SELECT 1 FROM disputes WHERE reservation_id = p_reservation_id AND status IN ('open','under_review')) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'open_dispute_blocks_payment');
  END IF;

  SELECT v_res.group_earnings - COALESCE(SUM(amount), 0) INTO v_saldo
  FROM group_reservation_payments WHERE reservation_id = p_reservation_id;
  IF v_saldo IS NULL OR v_saldo <= 0 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'no_balance_due');
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM wallets w
    WHERE w.user_id = v_res.owner_id
      AND w.bank_clabe IS NOT NULL AND length(w.bank_clabe) = 18 AND w.bank_clabe ~ '^\d{18}$'
      AND w.bank_name IS NOT NULL AND length(trim(w.bank_name)) > 0
      AND w.account_holder IS NOT NULL AND length(trim(w.account_holder)) > 0
  ) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'missing_bank_data');
  END IF;

  SELECT * INTO v_existing FROM group_payment_requests
  WHERE reservation_id = p_reservation_id AND status = 'pending';
  IF FOUND THEN
    RETURN jsonb_build_object('ok', true, 'already_requested', true, 'request_id', v_existing.id);
  END IF;

  BEGIN
    INSERT INTO group_payment_requests (reservation_id, group_id, requested_by, status)
    VALUES (p_reservation_id, v_res.group_id, auth.uid(), 'pending')
    RETURNING id INTO v_new_id;
  EXCEPTION WHEN unique_violation THEN
    SELECT id INTO v_new_id FROM group_payment_requests
    WHERE reservation_id = p_reservation_id AND status = 'pending';
    RETURN jsonb_build_object('ok', true, 'already_requested', true, 'request_id', v_new_id);
  END;

  INSERT INTO notifications (user_id, type, title, body, data)
  SELECT p.id, 'payment', '📢 Grupo solicita su pago',
    format('%s solicita el pago de su evento del %s%s.',
      (SELECT name FROM groups WHERE id = v_res.group_id),
      v_res.event_date,
      CASE WHEN v_res.folio IS NOT NULL THEN format(' (folio %s)', v_res.folio) ELSE '' END),
    jsonb_build_object('reservation_id', p_reservation_id, 'screen', 'AdminFinancial')
  FROM profiles p WHERE p.role = 'admin';

  RETURN jsonb_build_object('ok', true, 'already_requested', false, 'request_id', v_new_id);
END;
$function$;

-- ── request_withdrawal — cierre de autoservicio para group ────
CREATE OR REPLACE FUNCTION public.request_withdrawal(p_amount numeric, p_bank_clabe text, p_bank_name text, p_account_holder text)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE
  v_user_id  UUID := auth.uid();
  v_group_id UUID;
  v_wallet   RECORD;
  v_wd_id    UUID;
BEGIN
  IF v_user_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_authenticated');
  END IF;

  IF EXISTS (SELECT 1 FROM profiles WHERE id = v_user_id AND role = 'group') THEN
    RETURN jsonb_build_object('ok', false, 'error', 'group_self_withdrawal_disabled',
      'hint', 'Usa "Solicitar pago" desde tu Wallet — el admin realiza la transferencia.');
  END IF;

  SELECT id INTO v_group_id FROM public.groups WHERE owner_id = v_user_id LIMIT 1;
  IF v_group_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'no_group');
  END IF;

  SELECT * INTO v_wallet
  FROM public.group_wallets
  WHERE group_id = v_group_id
  FOR UPDATE;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'wallet_not_found');
  END IF;

  IF p_amount <= 0 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_amount');
  END IF;

  IF v_wallet.available_balance < p_amount THEN
    RETURN jsonb_build_object('ok', false, 'error', 'insufficient_balance',
      'available', v_wallet.available_balance);
  END IF;

  INSERT INTO public.withdrawals
    (user_id, amount, status, payout_method, bank_clabe, bank_name, account_holder)
  VALUES
    (v_user_id, p_amount, 'pending', 'spei', p_bank_clabe, p_bank_name, p_account_holder)
  RETURNING id INTO v_wd_id;

  UPDATE public.group_wallets
  SET available_balance = available_balance - p_amount,
      updated_at        = NOW()
  WHERE id = v_wallet.id;

  INSERT INTO public.wallet_transactions
    (group_wallet_id, group_id, type, amount, description, balance_after, currency_code)
  VALUES
    (v_wallet.id, v_group_id, 'debit_payout', p_amount,
     format('Retiro SPEI solicitado $%s MXN', p_amount),
     v_wallet.available_balance - p_amount,
     'MXN');

  INSERT INTO public.notifications (user_id, type, title, body, data)
  VALUES (
    v_user_id, 'payout',
    '🏦 Retiro en proceso',
    format('Tu retiro de $%s MXN está siendo procesado.', to_char(p_amount, 'FM999,999,990')),
    jsonb_build_object('withdrawal_id', v_wd_id, 'screen', 'Wallet')
  );

  INSERT INTO public.notifications (user_id, type, title, body, data)
  SELECT p.id, 'payout',
    format('💸 Solicitud de retiro — $%s', to_char(p_amount, 'FM999,999,990')),
    'Un grupo solicitó retirar vía SPEI.',
    jsonb_build_object('withdrawal_id', v_wd_id, 'group_id', v_group_id, 'screen', 'Withdrawals')
  FROM public.profiles p
  WHERE p.role = 'admin';

  RETURN jsonb_build_object(
    'ok',            true,
    'withdrawal_id', v_wd_id,
    'amount',        p_amount,
    'new_balance',   v_wallet.available_balance - p_amount
  );

EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$function$;

-- ── RLS withdrawals: quitar INSERT/UPDATE directo de group ────
DROP POLICY IF EXISTS wd_group_owner_insert ON public.withdrawals;
DROP POLICY IF EXISTS wd_owner_update ON public.withdrawals;

COMMIT;

SELECT '535d_p1f_hardening_part4 (colas+request_withdrawal+RLS) ✅' AS status;
