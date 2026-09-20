-- ============================================================================
-- sql/660_admin_ops_limited_role_and_claims.sql
--
-- 1) admin_can_manage_payouts — nueva bandera en profiles. Antes CUALQUIER
--    admin_ops podía mover dinero (retiros, pagos a grupos, propinas). Ahora
--    solo puede quien tenga esta bandera en true. La cuenta admin_ops de
--    EE.UU. que ya existe (Daricefy Admin US) se marca en true (ya hacía
--    transferencias, no se le quita nada). Un admin_ops NUEVO nace en false
--    — sin acceso a dinero, solo operativo (no-shows, fotos, cotizaciones
--    de conserjería, solicitudes de proveedores).
--
-- 2) admin_claims — "en trabajo": para que dos personas del equipo no
--    atiendan el mismo caso dos veces. Tabla genérica (sirve para
--    no-shows, fotos, cotizaciones y solicitudes sin crear una tabla por
--    cada cola) + 3 RPC: tomar, liberar, consultar. Un claim se considera
--    vencido solo a los 30 minutos (por si alguien cierra la app sin
--    liberarlo) — nadie queda bloqueado para siempre por accidente.
-- ============================================================================

ALTER TABLE public.profiles
  ADD COLUMN IF NOT EXISTS admin_can_manage_payouts boolean NOT NULL DEFAULT false;

UPDATE public.profiles
  SET admin_can_manage_payouts = true
  WHERE role = 'admin_ops' AND admin_country_scope = 'US';

-- Hasta hoy admin_ops solo se permitía para US/CA (México siempre lo
-- manejaba la cuenta admin completa). Se amplía a MX porque ahora sí
-- habrá una cuenta operativa (sin dinero) también en México.
ALTER TABLE public.profiles DROP CONSTRAINT IF EXISTS profiles_admin_country_scope_check;
ALTER TABLE public.profiles ADD CONSTRAINT profiles_admin_country_scope_check
  CHECK (admin_country_scope IS NULL OR admin_country_scope IN ('MX', 'US', 'CA'));

-- ── admin_claims ────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.admin_claims (
  item_type       text NOT NULL,   -- 'no_show' | 'media' | 'concierge_quote' | 'provider_application'
  item_id         text NOT NULL,
  claimed_by      uuid NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  claimed_by_name text,
  claimed_at      timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (item_type, item_id)
);

ALTER TABLE public.admin_claims ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS admin_claims_admin_select ON public.admin_claims;
CREATE POLICY admin_claims_admin_select ON public.admin_claims
FOR SELECT
USING (
  EXISTS (SELECT 1 FROM public.profiles p WHERE p.id = auth.uid() AND p.role IN ('admin', 'admin_ops'))
);
-- Sin política de INSERT/UPDATE/DELETE a propósito — solo las RPC
-- (SECURITY DEFINER) escriben aquí.

CREATE OR REPLACE FUNCTION public.admin_claim_item(p_item_type text, p_item_id text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_caller_role TEXT;
  v_caller_name TEXT;
  v_existing    RECORD;
BEGIN
  SELECT role, full_name INTO v_caller_role, v_caller_name FROM public.profiles WHERE id = auth.uid();
  IF v_caller_role NOT IN ('admin', 'admin_ops') THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_admin');
  END IF;

  SELECT * INTO v_existing FROM public.admin_claims WHERE item_type = p_item_type AND item_id = p_item_id FOR UPDATE;

  IF FOUND AND v_existing.claimed_by <> auth.uid() AND v_existing.claimed_at > NOW() - INTERVAL '30 minutes' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'already_claimed', 'claimed_by_name', v_existing.claimed_by_name, 'claimed_at', v_existing.claimed_at);
  END IF;

  INSERT INTO public.admin_claims (item_type, item_id, claimed_by, claimed_by_name, claimed_at)
  VALUES (p_item_type, p_item_id, auth.uid(), COALESCE(v_caller_name, 'Admin'), NOW())
  ON CONFLICT (item_type, item_id) DO UPDATE
    SET claimed_by = EXCLUDED.claimed_by, claimed_by_name = EXCLUDED.claimed_by_name, claimed_at = EXCLUDED.claimed_at;

  RETURN jsonb_build_object('ok', true);
END;
$function$;

CREATE OR REPLACE FUNCTION public.admin_release_claim(p_item_type text, p_item_id text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_caller_role TEXT;
BEGIN
  SELECT role INTO v_caller_role FROM public.profiles WHERE id = auth.uid();
  IF v_caller_role NOT IN ('admin', 'admin_ops') THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_admin');
  END IF;

  -- El admin completo puede liberar cualquier claim (por si alguien se fue
  -- y dejó algo atorado); admin_ops solo puede liberar el suyo propio.
  DELETE FROM public.admin_claims
  WHERE item_type = p_item_type AND item_id = p_item_id
    AND (claimed_by = auth.uid() OR v_caller_role = 'admin');

  RETURN jsonb_build_object('ok', true);
END;
$function$;

CREATE OR REPLACE FUNCTION public.admin_get_claims(p_item_type text, p_item_ids text[])
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_caller_role TEXT;
  v_result      JSONB;
BEGIN
  SELECT role INTO v_caller_role FROM public.profiles WHERE id = auth.uid();
  IF v_caller_role NOT IN ('admin', 'admin_ops') THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_admin');
  END IF;

  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'item_id', item_id,
    'claimed_by', claimed_by,
    'claimed_by_name', claimed_by_name,
    'claimed_at', claimed_at,
    'is_mine', claimed_by = auth.uid()
  )), '[]'::jsonb)
  INTO v_result
  FROM public.admin_claims
  WHERE item_type = p_item_type
    AND item_id = ANY(p_item_ids)
    AND claimed_at > NOW() - INTERVAL '30 minutes';

  RETURN jsonb_build_object('ok', true, 'items', v_result);
END;
$function$;

GRANT EXECUTE ON FUNCTION public.admin_claim_item(text, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_release_claim(text, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_get_claims(text, text[]) TO authenticated;

-- ── Candado de dinero en las 3 acciones que de verdad mueven dinero ────────
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

  IF v_caller_role = 'admin_ops' AND NOT COALESCE((SELECT admin_can_manage_payouts FROM profiles WHERE id = auth.uid()), false) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_authorized_payouts');
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

  IF v_caller_role = 'admin_ops' AND NOT COALESCE((SELECT admin_can_manage_payouts FROM profiles WHERE id = auth.uid()), false) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_authorized_payouts');
  END IF;

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

  IF v_caller_role = 'admin_ops' AND NOT COALESCE((SELECT admin_can_manage_payouts FROM profiles WHERE id = auth.uid()), false) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'Solo administradores');
  END IF;

  SELECT * INTO v_wd FROM withdrawals WHERE id = p_payout_id FOR UPDATE;
  IF NOT FOUND THEN RETURN jsonb_build_object('ok', false, 'error', 'not_found'); END IF;

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
