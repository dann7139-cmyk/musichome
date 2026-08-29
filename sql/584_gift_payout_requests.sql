-- ============================================================
-- sql/584_gift_payout_requests.sql — cobro de propinas/regalos acumulados
--
-- Hasta ahora el dinero de regalos (type='gift_income' en wallet_transactions,
-- sql/567+) cae en el mismo group_wallets.available_balance que el dinero
-- de eventos, pero NINGÚN flujo permitía al grupo pedir que se le pague ese
-- saldo si no tenía además una reservación con saldo pendiente: group_
-- request_payment (sql/531) exige una reservation_id, y request_withdrawal
-- (sql/542) está bloqueado para role='group' a propósito. El dinero se
-- quedaba atorado sin ningún botón para reclamarlo.
--
-- Este archivo agrega el mismo patrón de 2 pasos que ya existe para
-- eventos (aviso administrativo → admin transfiere y sube comprobante),
-- pero para el saldo de propinas acumulado, con un mínimo de $200 MXN /
-- $12 USD antes de poder solicitarlo (evita transferencias de centavos).
--
-- El saldo "de propinas sin cobrar" se calcula del LEDGER de
-- wallet_transactions (SUM gift_income − SUM gift_payout, por moneda),
-- no de una columna aparte — así nunca se desincroniza.
--
-- Rollback: sql/584_gift_payout_requests_ROLLBACK.sql
-- ============================================================

BEGIN;

-- ── 1. Nuevo type en wallet_transactions ────────────────────────────────
ALTER TABLE public.wallet_transactions DROP CONSTRAINT chk_wt_type;

ALTER TABLE public.wallet_transactions ADD CONSTRAINT chk_wt_type CHECK (
  type = ANY (ARRAY[
    'credit_pending', 'credit_available', 'release_to_available', 'debit_payout',
    'refund_dispute', 'adjustment', 'event_earning', 'extra_hour', 'withdrawal',
    'commission', 'refund', 'platform_income', 'debit_refund', 'ad_income',
    'bid_income', 'recommendation_income', 'commission_correction', 'manual_advance',
    'final_settlement', 'gift_income', 'gift_payout'
  ])
);

-- ── 2. Tabla de solicitudes (mismo patrón que group_payment_requests) ──
CREATE TABLE public.group_gift_payout_requests (
  id                UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  group_id          UUID NOT NULL REFERENCES groups(id) ON DELETE CASCADE,
  requested_by      UUID NOT NULL REFERENCES profiles(id),
  amount            NUMERIC(14,2) NOT NULL CHECK (amount > 0),
  currency_code     TEXT NOT NULL CHECK (currency_code IN ('MXN','USD')),
  status            TEXT NOT NULL DEFAULT 'pending'
    CONSTRAINT chk_ggpr_status CHECK (status IN ('pending','completed','cancelled')),
  requested_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  seen_by_admin_at  TIMESTAMPTZ
);

-- Una sola solicitud activa por grupo (sin importar moneda — caso raro de
-- tener saldo en ambas monedas a la vez se resuelve pidiendo la segunda
-- después de que la primera se liquide).
CREATE UNIQUE INDEX uq_ggpr_active ON public.group_gift_payout_requests(group_id)
  WHERE status = 'pending';

CREATE INDEX idx_ggpr_group ON public.group_gift_payout_requests(group_id);

ALTER TABLE public.group_gift_payout_requests ENABLE ROW LEVEL SECURITY;

REVOKE INSERT, UPDATE, DELETE ON public.group_gift_payout_requests FROM authenticated, anon;
GRANT SELECT ON public.group_gift_payout_requests TO authenticated;

CREATE POLICY ggpr_admin_read ON public.group_gift_payout_requests FOR SELECT
  USING (EXISTS (SELECT 1 FROM profiles WHERE id = auth.uid() AND role = 'admin'));

CREATE POLICY ggpr_owner_read ON public.group_gift_payout_requests FOR SELECT
  USING (EXISTS (SELECT 1 FROM groups g WHERE g.id = group_id AND g.owner_id = auth.uid()));

-- ── 3. Helper: saldo de propinas sin cobrar, por moneda ─────────────────
CREATE OR REPLACE FUNCTION public.group_unpaid_gift_balance(p_group_id UUID)
RETURNS TABLE(currency_code TEXT, unpaid NUMERIC)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $function$
  SELECT cur.currency_code,
    COALESCE(SUM(wt.amount) FILTER (WHERE wt.type = 'gift_income'), 0)
      - COALESCE(SUM(wt.amount) FILTER (WHERE wt.type = 'gift_payout'), 0)
  FROM (VALUES ('MXN'), ('USD')) AS cur(currency_code)
  LEFT JOIN public.wallet_transactions wt
    ON wt.group_id = p_group_id
   AND wt.currency_code = cur.currency_code
   AND wt.type IN ('gift_income','gift_payout')
  GROUP BY cur.currency_code;
$function$;

-- ── 4. Lectura del grupo — para el botón en Wallet ──────────────────────
CREATE OR REPLACE FUNCTION public.group_get_gift_payout_status()
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $function$
DECLARE
  v_group_id UUID;
  v_unpaid_mxn NUMERIC := 0;
  v_unpaid_usd NUMERIC := 0;
  v_pending RECORD;
BEGIN
  IF auth.uid() IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_authenticated');
  END IF;

  SELECT id INTO v_group_id FROM groups WHERE owner_id = auth.uid();
  IF v_group_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'no_group');
  END IF;

  SELECT unpaid INTO v_unpaid_mxn FROM public.group_unpaid_gift_balance(v_group_id) WHERE currency_code = 'MXN';
  SELECT unpaid INTO v_unpaid_usd FROM public.group_unpaid_gift_balance(v_group_id) WHERE currency_code = 'USD';

  SELECT * INTO v_pending FROM public.group_gift_payout_requests
  WHERE group_id = v_group_id AND status = 'pending';

  RETURN jsonb_build_object(
    'ok', true,
    'unpaid_mxn', COALESCE(v_unpaid_mxn, 0),
    'unpaid_usd', COALESCE(v_unpaid_usd, 0),
    'threshold_mxn', 200,
    'threshold_usd', 12,
    'has_pending_request', v_pending.id IS NOT NULL,
    'pending_amount', v_pending.amount,
    'pending_currency', v_pending.currency_code
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.group_get_gift_payout_status() TO authenticated;

-- ── 5. Escritura del grupo — pedir el pago ──────────────────────────────
CREATE OR REPLACE FUNCTION public.group_request_gift_payout()
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $function$
DECLARE
  v_group_id    UUID;
  v_owner_id    UUID;
  v_unpaid_mxn  NUMERIC := 0;
  v_unpaid_usd  NUMERIC := 0;
  v_amount      NUMERIC;
  v_currency    TEXT;
  v_existing    RECORD;
  v_new_id      UUID;
BEGIN
  IF auth.uid() IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_authenticated');
  END IF;

  SELECT id, owner_id INTO v_group_id, v_owner_id FROM groups WHERE owner_id = auth.uid();
  IF v_group_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'no_group');
  END IF;

  SELECT * INTO v_existing FROM public.group_gift_payout_requests
  WHERE group_id = v_group_id AND status = 'pending';
  IF FOUND THEN
    RETURN jsonb_build_object('ok', true, 'already_requested', true, 'request_id', v_existing.id,
      'amount', v_existing.amount, 'currency', v_existing.currency_code);
  END IF;

  SELECT unpaid INTO v_unpaid_mxn FROM public.group_unpaid_gift_balance(v_group_id) WHERE currency_code = 'MXN';
  SELECT unpaid INTO v_unpaid_usd FROM public.group_unpaid_gift_balance(v_group_id) WHERE currency_code = 'USD';

  IF COALESCE(v_unpaid_mxn, 0) >= 200 THEN
    v_amount := v_unpaid_mxn; v_currency := 'MXN';
  ELSIF COALESCE(v_unpaid_usd, 0) >= 12 THEN
    v_amount := v_unpaid_usd; v_currency := 'USD';
  ELSE
    RETURN jsonb_build_object('ok', false, 'error', 'below_minimum',
      'unpaid_mxn', COALESCE(v_unpaid_mxn, 0), 'unpaid_usd', COALESCE(v_unpaid_usd, 0),
      'threshold_mxn', 200, 'threshold_usd', 12);
  END IF;

  -- Mismo requisito de datos bancarios que group_request_payment (sql/531).
  IF NOT EXISTS (
    SELECT 1 FROM wallets w
    WHERE w.user_id = v_owner_id
      AND w.bank_clabe IS NOT NULL AND length(w.bank_clabe) = 18 AND w.bank_clabe ~ '^\d{18}$'
      AND w.bank_name IS NOT NULL AND length(trim(w.bank_name)) > 0
      AND w.account_holder IS NOT NULL AND length(trim(w.account_holder)) > 0
  ) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'missing_bank_data');
  END IF;

  BEGIN
    INSERT INTO public.group_gift_payout_requests (group_id, requested_by, amount, currency_code, status)
    VALUES (v_group_id, auth.uid(), v_amount, v_currency, 'pending')
    RETURNING id INTO v_new_id;
  EXCEPTION WHEN unique_violation THEN
    SELECT id, amount, currency_code INTO v_new_id, v_amount, v_currency
    FROM public.group_gift_payout_requests WHERE group_id = v_group_id AND status = 'pending';
    RETURN jsonb_build_object('ok', true, 'already_requested', true, 'request_id', v_new_id,
      'amount', v_amount, 'currency', v_currency);
  END;

  INSERT INTO notifications (user_id, type, title, body, data)
  SELECT p.id, 'payment', '🎁 Grupo solicita cobrar sus propinas',
    format('%s solicita el pago de $%s %s en propinas/regalos acumulados.',
      (SELECT name FROM groups WHERE id = v_group_id), v_amount, v_currency),
    jsonb_build_object('group_id', v_group_id, 'screen', 'AdminFinancial')
  FROM profiles p WHERE p.role = 'admin';

  RETURN jsonb_build_object('ok', true, 'already_requested', false, 'request_id', v_new_id,
    'amount', v_amount, 'currency', v_currency);
END;
$function$;

GRANT EXECUTE ON FUNCTION public.group_request_gift_payout() TO authenticated;

-- ── 6. Cola del admin ────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.admin_get_pending_gift_payouts()
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $function$
DECLARE v_result jsonb;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM profiles WHERE id = auth.uid() AND role = 'admin') THEN
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
        'account_holder',  w.account_holder
      ) AS item
    FROM public.group_gift_payout_requests r
    JOIN groups g ON g.id = r.group_id
    LEFT JOIN wallets w ON w.user_id = g.owner_id
    WHERE r.status = 'pending'
    ORDER BY r.requested_at DESC
  ) x;

  RETURN v_result;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.admin_get_pending_gift_payouts() TO authenticated;

-- ── 7. Registrar el pago real (transferencia + comprobante) ─────────────
CREATE OR REPLACE FUNCTION public.admin_register_gift_payout(
  p_group_id           UUID,
  p_amount             NUMERIC,
  p_currency_code      TEXT,
  p_receipt_path       TEXT DEFAULT NULL,
  p_transfer_reference TEXT DEFAULT NULL,
  p_transferred_at     TIMESTAMPTZ DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE
  v_wallet     RECORD;
  v_unpaid     NUMERIC;
  v_bal_after  NUMERIC;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM profiles WHERE id = auth.uid() AND role = 'admin') THEN
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
  VALUES ('group_gift_payout', p_group_id, 'gift_payout', auth.uid(), 'admin', p_amount,
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

GRANT EXECUTE ON FUNCTION public.admin_register_gift_payout(UUID, NUMERIC, TEXT, TEXT, TEXT, TIMESTAMPTZ) TO authenticated;

COMMIT;

-- ── Verificación ──────────────────────────────────────────────────
SELECT proname FROM pg_proc
WHERE pronamespace = 'public'::regnamespace
  AND proname IN (
    'group_unpaid_gift_balance','group_get_gift_payout_status','group_request_gift_payout',
    'admin_get_pending_gift_payouts','admin_register_gift_payout'
  );

SELECT '584_gift_payout_requests ✅' AS status;
