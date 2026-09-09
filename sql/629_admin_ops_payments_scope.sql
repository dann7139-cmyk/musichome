-- sql/629_admin_ops_payments_scope.sql
--
-- Fase 1 (cola 2/3: Pagos/transferencias) del admin con alcance por país.
-- Mismo patrón que sql/628: role='admin' sin cambios; role='admin_ops'
-- filtra las colas por país y se re-verifica el país de la fila exacta
-- antes de cualquier acción financiera.
BEGIN;

-- ── 1/8: admin_manual_refund_queue ──────────────────────────────────────
CREATE OR REPLACE FUNCTION public.admin_manual_refund_queue(p_status text DEFAULT NULL::text)
 RETURNS TABLE(id uuid, reservation_id uuid, client_id uuid, folio text, client_name text, client_phone text, country_code text, country text, state text, city text, currency text, payment_method text, amount numeric, clabe text, account_holder text, bank_name text, due_date date, status text, transfer_reference text, receipt_path text, api_error text, created_at timestamp with time zone, processed_at timestamp with time zone)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_caller_role TEXT;
BEGIN
  SELECT role INTO v_caller_role FROM profiles WHERE id = auth.uid();
  IF v_caller_role NOT IN ('admin', 'admin_ops') THEN
    RAISE EXCEPTION 'Solo administradores';
  END IF;
  RETURN QUERY
  SELECT mr.id, mr.reservation_id, mr.client_id, mr.folio,
         p.full_name, p.phone,
         country_code_of(p.country),
         COALESCE(p.country, 'México'),
         p.state, p.city,
         COALESCE(r.currency_code, 'MXN'),
         mr.payment_method, mr.amount, mr.clabe, mr.account_holder, mr.bank_name,
         mr.due_date, mr.status, mr.transfer_reference, mr.receipt_path, mr.api_error,
         mr.created_at, mr.processed_at
  FROM manual_refunds mr
  JOIN profiles p ON p.id = mr.client_id
  LEFT JOIN reservations r ON r.id = mr.reservation_id
  WHERE (p_status IS NULL OR mr.status = p_status)
    AND (v_caller_role = 'admin' OR country_code_of(p.country) = admin_ops_country())  -- [629]
  ORDER BY (mr.status = 'sent'), mr.due_date, mr.created_at;
END;
$function$;

-- ── 2/8: admin_process_manual_refund (acción) ───────────────────────────
CREATE OR REPLACE FUNCTION public.admin_process_manual_refund(p_refund_id uuid, p_action text, p_transfer_reference text DEFAULT NULL::text, p_receipt_path text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_caller_role TEXT;
  v_mr RECORD;
  v_receipt TEXT;
BEGIN
  SELECT role INTO v_caller_role FROM profiles WHERE id = auth.uid();
  IF v_caller_role NOT IN ('admin', 'admin_ops') THEN
    RETURN jsonb_build_object('ok', false, 'error', 'Solo administradores');
  END IF;
  IF p_action NOT IN ('processing', 'sent') THEN
    RETURN jsonb_build_object('ok', false, 'error', 'Acción inválida');
  END IF;

  SELECT * INTO v_mr FROM manual_refunds WHERE id = p_refund_id FOR UPDATE;
  IF NOT FOUND THEN RETURN jsonb_build_object('ok', false, 'error', 'not_found'); END IF;

  -- [629] admin_ops: el cliente del reembolso debe ser de su país de alcance
  IF v_caller_role = 'admin_ops' AND NOT EXISTS (
    SELECT 1 FROM profiles p WHERE p.id = v_mr.client_id
      AND country_code_of(p.country) = admin_ops_country()
  ) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'Solo administradores');
  END IF;

  IF v_mr.status = 'sent' THEN
    RETURN jsonb_build_object('ok', true, 'skipped', true, 'reason', 'already_sent');
  END IF;

  IF p_action = 'sent' AND COALESCE(TRIM(p_transfer_reference), '') = '' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'La referencia de la transferencia es obligatoria');
  END IF;

  UPDATE manual_refunds SET
    status             = p_action,
    transfer_reference = COALESCE(p_transfer_reference, transfer_reference),
    receipt_path       = COALESCE(p_receipt_path, receipt_path),
    processed_by       = auth.uid(),
    processed_at       = CASE WHEN p_action = 'sent' THEN NOW() ELSE processed_at END,
    updated_at         = NOW()
  WHERE id = p_refund_id;

  INSERT INTO financial_audit_logs (entity_type, entity_id, action, actor_id, actor_role, amount, notes)
  VALUES ('manual_refund', p_refund_id,
          CASE WHEN p_action = 'sent' THEN 'manual_refund_completed' ELSE 'manual_refund_processing' END,
          auth.uid(), v_caller_role, v_mr.amount,
          format('ref=%s receipt=%s', COALESCE(p_transfer_reference, 'n/a'), COALESCE(p_receipt_path, 'n/a')));

  IF p_action = 'sent' THEN
    v_receipt := COALESCE(p_receipt_path, v_mr.receipt_path);
    INSERT INTO notifications (user_id, type, title, body, data)
    VALUES (v_mr.client_id, 'payment', '✅ Tu reembolso fue enviado',
      format('Enviamos tu reembolso de $%s MXN por transferencia%s.%s',
        to_char(v_mr.amount, 'FM999,999,990.00'),
        CASE WHEN v_mr.clabe IS NOT NULL
             THEN format(' a tu cuenta terminación %s', RIGHT(v_mr.clabe, 4)) ELSE '' END,
        CASE WHEN v_receipt IS NOT NULL
             THEN ' Toca esta notificación para ver tu comprobante.' ELSE '' END),
      jsonb_build_object('screen', 'Reservations', 'reservation_id', v_mr.reservation_id,
                         'manual_refund_id', p_refund_id,
                         'receipt_path', v_receipt));
  END IF;

  RETURN jsonb_build_object('ok', true, 'status', p_action);
END;
$function$;

-- ── 3/8: admin_get_pending_group_payments ───────────────────────────────
CREATE OR REPLACE FUNCTION public.admin_get_pending_group_payments(p_limit integer DEFAULT 50)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_caller_role TEXT;
  v_result jsonb;
BEGIN
  SELECT role INTO v_caller_role FROM profiles WHERE id = auth.uid();
  IF v_caller_role NOT IN ('admin', 'admin_ops') THEN
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
        'refund_claim_status', rc.status,
        'country_code',     country_code_of(g.country),     -- [629]
        'country',          COALESCE(g.country, 'México')    -- [629]
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
      AND (v_caller_role = 'admin' OR country_code_of(g.country) = admin_ops_country())  -- [629]
    ORDER BY r.event_date DESC NULLS LAST
    LIMIT p_limit
  ) x;

  RETURN v_result;
END;
$function$;

-- ── 4/8: admin_get_pending_gift_payouts ─────────────────────────────────
CREATE OR REPLACE FUNCTION public.admin_get_pending_gift_payouts()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_caller_role TEXT;
  v_result jsonb;
BEGIN
  SELECT role INTO v_caller_role FROM profiles WHERE id = auth.uid();
  IF v_caller_role NOT IN ('admin', 'admin_ops') THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_admin');
  END IF;

  SELECT jsonb_build_object('ok', true, 'items', COALESCE(jsonb_agg(x.item ORDER BY x.requested_at DESC), '[]'::jsonb))
  INTO v_result
  FROM (
    SELECT
      r.requested_at,
      jsonb_build_object(
        'request_id',      r.id,
        'group_id',        r.group_id,
        'group_name',      g.name,
        'amount',          r.amount,
        'currency',        r.currency_code,
        'requested_at',    r.requested_at,
        'bank_clabe',      w.bank_clabe,
        'bank_name',       w.bank_name,
        'account_holder',  w.account_holder,
        'country_code',    country_code_of(g.country),     -- [629]
        'country',         COALESCE(g.country, 'México')    -- [629]
      ) AS item
    FROM public.group_gift_payout_requests r
    JOIN groups g ON g.id = r.group_id
    LEFT JOIN wallets w ON w.user_id = g.owner_id
    WHERE r.status = 'pending'
      AND (v_caller_role = 'admin' OR country_code_of(g.country) = admin_ops_country())  -- [629]
    ORDER BY r.requested_at DESC
  ) x;

  RETURN v_result;
END;
$function$;

-- ── 5/8: admin_register_group_payment (acción) ──────────────────────────
CREATE OR REPLACE FUNCTION public.admin_register_group_payment(p_reservation_id uuid, p_amount numeric, p_kind text, p_receipt_path text DEFAULT NULL::text, p_note text DEFAULT NULL::text, p_transfer_reference text DEFAULT NULL::text, p_transferred_at timestamp with time zone DEFAULT NULL::timestamp with time zone)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_caller_role    TEXT;
  v_group_id       UUID;
  v_res            RECORD;
  v_wallet         RECORD;
  v_ya_pagado      NUMERIC;
  v_saldo_restante NUMERIC;
  v_disponible     NUMERIC;
  v_bucket         TEXT;
BEGIN
  SELECT role INTO v_caller_role FROM profiles WHERE id = auth.uid();
  IF v_caller_role NOT IN ('admin', 'admin_ops') THEN
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

  -- [629] admin_ops: la reserva debe ser de su país de alcance
  IF v_caller_role = 'admin_ops' AND NOT EXISTS (
    SELECT 1 FROM groups g WHERE g.id = v_group_id
      AND country_code_of(g.country) = admin_ops_country()
  ) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_admin');
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
  VALUES ('reservation', p_reservation_id, p_kind, auth.uid(), v_caller_role, p_amount,
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

-- ── 6/8: admin_register_gift_payout (acción) ────────────────────────────
CREATE OR REPLACE FUNCTION public.admin_register_gift_payout(p_group_id uuid, p_amount numeric, p_currency_code text, p_receipt_path text DEFAULT NULL::text, p_transfer_reference text DEFAULT NULL::text, p_transferred_at timestamp with time zone DEFAULT NULL::timestamp with time zone)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_caller_role TEXT;
  v_wallet     RECORD;
  v_unpaid     NUMERIC;
  v_bal_after  NUMERIC;
BEGIN
  SELECT role INTO v_caller_role FROM profiles WHERE id = auth.uid();
  IF v_caller_role NOT IN ('admin', 'admin_ops') THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_admin');
  END IF;

  -- [629] admin_ops: el grupo debe ser de su país de alcance
  IF v_caller_role = 'admin_ops' AND NOT EXISTS (
    SELECT 1 FROM groups g WHERE g.id = p_group_id
      AND country_code_of(g.country) = admin_ops_country()
  ) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_admin');
  END IF;

  IF p_currency_code NOT IN ('MXN','USD') THEN
    RETURN jsonb_build_object('ok', false, 'error', 'unsupported_currency');
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
  IF COALESCE(trim(p_transfer_reference),'') = '' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'transfer_reference_required');
  END IF;

  PERFORM pg_advisory_xact_lock(hashtext(p_group_id::text));

  PERFORM public.ensure_group_wallet(p_group_id);
  SELECT * INTO v_wallet FROM group_wallets WHERE group_id = p_group_id FOR UPDATE;

  SELECT unpaid INTO v_unpaid FROM public.group_unpaid_gift_balance(p_group_id) WHERE currency_code = p_currency_code;
  v_unpaid := COALESCE(v_unpaid, 0);

  IF p_amount <> v_unpaid THEN
    RETURN jsonb_build_object('ok', false, 'error', 'amount_must_match_balance',
      'saldo_actual', v_unpaid, 'monto_recibido', p_amount);
  END IF;

  IF p_currency_code = 'USD' THEN
    IF v_wallet.available_balance_usd < p_amount THEN
      RETURN jsonb_build_object('ok', false, 'error', 'insufficient_wallet_bucket',
        'disponible', v_wallet.available_balance_usd);
    END IF;
    v_bal_after := v_wallet.available_balance_usd - p_amount;
    UPDATE group_wallets SET available_balance_usd = v_bal_after, updated_at = NOW() WHERE id = v_wallet.id;
  ELSE
    IF v_wallet.available_balance < p_amount THEN
      RETURN jsonb_build_object('ok', false, 'error', 'insufficient_wallet_bucket',
        'disponible', v_wallet.available_balance);
    END IF;
    v_bal_after := v_wallet.available_balance - p_amount;
    UPDATE group_wallets SET available_balance = v_bal_after, updated_at = NOW() WHERE id = v_wallet.id;
  END IF;

  INSERT INTO wallet_transactions (group_wallet_id, group_id, type, amount, description, balance_after, currency_code)
  VALUES (v_wallet.id, p_group_id, 'gift_payout', p_amount,
    format('Pago de propinas/regalos acumulados (ref %s)', p_transfer_reference),
    v_bal_after, p_currency_code);

  INSERT INTO financial_audit_logs (entity_type, entity_id, action, actor_id, actor_role, amount, notes)
  VALUES ('group_gift_payout', p_group_id, 'gift_payout', auth.uid(), v_caller_role, p_amount,
    format('currency=%s receipt=%s ref=%s transferred_at=%s', p_currency_code, p_receipt_path, p_transfer_reference, p_transferred_at));

  UPDATE public.group_gift_payout_requests SET status = 'completed'
  WHERE group_id = p_group_id AND status = 'pending' AND currency_code = p_currency_code;

  INSERT INTO notifications (user_id, type, title, body, data)
  SELECT g.owner_id, 'payment', '🎁 Propinas pagadas',
    format('Se transfirieron $%s %s de tus propinas/regalos acumulados. ¡Gracias por tu música!', p_amount, p_currency_code),
    jsonb_build_object('screen', 'Wallet')
  FROM groups g WHERE g.id = p_group_id;

  RETURN jsonb_build_object('ok', true, 'currency', p_currency_code, 'amount', p_amount, 'balance_after', v_bal_after);
END;
$function$;

-- ── 7/8: admin_withdrawals_queue ─────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.admin_withdrawals_queue(p_limit integer DEFAULT 60)
 RETURNS TABLE(id uuid, user_id uuid, owner_name text, owner_phone text, group_name text, country_code text, country text, state text, city text, currency text, expected_method text, amount numeric, status text, bank_clabe text, bank_name text, account_holder text, transfer_reference text, receipt_path text, created_at timestamp with time zone, processed_at timestamp with time zone)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_caller_role TEXT;
BEGIN
  SELECT role INTO v_caller_role FROM profiles WHERE id = auth.uid();
  IF v_caller_role NOT IN ('admin', 'admin_ops') THEN
    RAISE EXCEPTION 'Solo administradores';
  END IF;
  RETURN QUERY
  SELECT
    w.id, w.user_id,
    p.full_name, p.phone,
    g.name,
    country_code_of(COALESCE(g.country, p.country)),
    COALESCE(g.country, p.country, 'México'),
    COALESCE(g.state,  p.state),
    COALESCE(g.city,   p.city),
    CASE WHEN country_code_of(COALESCE(g.country, p.country)) = 'US' THEN 'USD' ELSE 'MXN' END,
    CASE WHEN country_code_of(COALESCE(g.country, p.country)) = 'US' THEN 'stripe_ach' ELSE 'spei' END,
    w.amount, w.status,
    w.bank_clabe, w.bank_name, w.account_holder,
    w.transfer_reference, w.receipt_path,
    w.created_at, w.processed_at
  FROM withdrawals w
  JOIN profiles p ON p.id = w.user_id
  LEFT JOIN groups g ON g.owner_id = w.user_id
  WHERE (v_caller_role = 'admin' OR country_code_of(COALESCE(g.country, p.country)) = admin_ops_country())  -- [629]
  ORDER BY (w.status IN ('pending','processing')) DESC, w.created_at DESC
  LIMIT p_limit;
END;
$function$;

-- ── 8/8: admin_complete_payout (acción) ─────────────────────────────────
CREATE OR REPLACE FUNCTION public.admin_complete_payout(p_payout_id uuid, p_transfer_reference text, p_receipt_path text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_caller_role TEXT;
  v_wd RECORD;
BEGIN
  SELECT role INTO v_caller_role FROM profiles WHERE id = auth.uid();
  IF v_caller_role NOT IN ('admin', 'admin_ops') THEN
    RETURN jsonb_build_object('ok', false, 'error', 'Solo administradores');
  END IF;

  SELECT * INTO v_wd FROM withdrawals WHERE id = p_payout_id FOR UPDATE;
  IF NOT FOUND THEN RETURN jsonb_build_object('ok', false, 'error', 'not_found'); END IF;

  -- [629] admin_ops: el retiro debe ser de un usuario/grupo de su país de alcance
  IF v_caller_role = 'admin_ops' AND NOT EXISTS (
    SELECT 1 FROM profiles p
    LEFT JOIN groups g ON g.owner_id = p.id
    WHERE p.id = v_wd.user_id
      AND country_code_of(COALESCE(g.country, p.country)) = admin_ops_country()
  ) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'Solo administradores');
  END IF;

  IF v_wd.status = 'completed' THEN
    RETURN jsonb_build_object('ok', true, 'skipped', true, 'reason', 'already_completed');
  END IF;
  IF v_wd.status = 'rejected' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'Retiro rechazado, no se puede pagar');
  END IF;
  IF COALESCE(TRIM(p_transfer_reference), '') = '' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'La referencia de la transferencia es obligatoria');
  END IF;

  UPDATE withdrawals SET
    status             = 'completed',
    transfer_reference = p_transfer_reference,
    receipt_path       = COALESCE(p_receipt_path, receipt_path),
    processed_by       = auth.uid(),
    processed_at       = NOW()
  WHERE id = p_payout_id;

  UPDATE wallet_transactions SET
    description = format('✅ Retiro transferido a tu cuenta ···%s — ref %s',
                         COALESCE(RIGHT(v_wd.bank_clabe, 4), '????'),
                         p_transfer_reference)
  WHERE id = (
    SELECT wt.id
    FROM wallet_transactions wt
    JOIN groups g ON g.id = wt.group_id
    WHERE g.owner_id = v_wd.user_id
      AND wt.type = 'debit_payout'
      AND wt.amount = v_wd.amount
      AND wt.description LIKE 'Retiro SPEI solicitado%'
    ORDER BY wt.created_at DESC
    LIMIT 1
  );

  INSERT INTO financial_audit_logs (entity_type, entity_id, action, actor_id, actor_role, amount, notes)
  VALUES ('withdrawal', p_payout_id, 'payout_completed', auth.uid(), v_caller_role, v_wd.amount,
    format('ref=%s receipt=%s', p_transfer_reference, COALESCE(p_receipt_path, 'n/a')));

  INSERT INTO notifications (user_id, type, title, body, data)
  VALUES (v_wd.user_id, 'payment', '💸 Tu retiro fue transferido',
    format('Enviamos tu retiro de $%s MXN por transferencia%s.%s',
      to_char(v_wd.amount, 'FM999,999,990.00'),
      CASE WHEN v_wd.bank_clabe IS NOT NULL
           THEN format(' a tu cuenta terminación %s', RIGHT(v_wd.bank_clabe, 4)) ELSE '' END,
      CASE WHEN COALESCE(p_receipt_path, v_wd.receipt_path) IS NOT NULL
           THEN ' Toca esta notificación para ver tu comprobante.' ELSE '' END),
    jsonb_build_object('screen', 'Wallet',
                       'withdrawal_id', p_payout_id,
                       'receipt_path', COALESCE(p_receipt_path, v_wd.receipt_path)));

  RETURN jsonb_build_object('ok', true, 'status', 'completed');
END;
$function$;

COMMIT;
