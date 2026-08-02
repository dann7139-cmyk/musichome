-- ============================================================
-- sql/533_final_settlement.sql
-- Fase P1E — Liquidación final por reservation_id
--
-- 1. Agrega columnas transfer_reference y transferred_at a
--    group_reservation_payments (fecha bancaria real, separada
--    de created_at que es solo "cuándo se registró en Daricefy").
-- 2. Agrega 'final_settlement' a chk_wt_type.
-- 3. Reemplaza admin_register_group_payment: ahora soporta
--    kind='final_settlement' (además de 'advance'), con:
--    - comprobante (receipt_path) OBLIGATORIO para cualquier kind
--    - transferred_at OBLIGATORIO para cualquier kind
--    - transfer_reference OBLIGATORIA solo para final_settlement
--    - final_settlement debe ser EXACTAMENTE igual al saldo
--      restante (group_earnings - SUM(group_reservation_payments))
--    - final_settlement solo si payout_status='released', debita
--      available_balance (advance sigue exigiendo 'held' y
--      debita pending_balance, sin cambios de comportamiento ahí)
--    - al completar un final_settlement, cierra automáticamente
--      cualquier group_payment_requests pending de esa reserva
--
-- No toca: eventos multi-grupo, sonido/producción externa,
-- DashboardScreen/Withdraw del admin, withdrawals, request_withdrawal.
-- ============================================================

BEGIN;

-- ── 1. Columnas nuevas ─────────────────────────────────────────
ALTER TABLE public.group_reservation_payments
  ADD COLUMN IF NOT EXISTS transfer_reference TEXT,
  ADD COLUMN IF NOT EXISTS transferred_at TIMESTAMPTZ;

-- ── 2. Nuevo tipo de wallet_transactions ──────────────────────
ALTER TABLE public.wallet_transactions DROP CONSTRAINT IF EXISTS chk_wt_type;
ALTER TABLE public.wallet_transactions ADD CONSTRAINT chk_wt_type
  CHECK (type = ANY (ARRAY[
    'credit_pending','credit_available','release_to_available','debit_payout',
    'refund_dispute','adjustment','event_earning','extra_hour','withdrawal',
    'commission','refund','platform_income','debit_refund','ad_income',
    'bid_income','recommendation_income','commission_correction',
    'manual_advance','final_settlement'
  ]));

-- ── 3. admin_register_group_payment — nueva firma (7 parámetros) ─
DROP FUNCTION IF EXISTS public.admin_register_group_payment(uuid, numeric, text, text, text);

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

  -- Comprobante obligatorio para CUALQUIER kind
  IF p_receipt_path IS NULL OR trim(p_receipt_path) = '' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'receipt_required');
  END IF;

  -- Fecha real de transferencia obligatoria para CUALQUIER kind
  IF p_transferred_at IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'transferred_at_required');
  END IF;

  -- Referencia de transferencia obligatoria SOLO para liquidación final
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
      RETURN jsonb_build_object('ok', false, 'error', 'payout_status_not_eligible',
        'payout_status', v_res.payout_status);
    END IF;
    v_bucket := 'pending';
  ELSE -- final_settlement
    IF v_res.payout_status <> 'released' THEN
      RETURN jsonb_build_object('ok', false, 'error', 'payout_status_not_eligible',
        'payout_status', v_res.payout_status);
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
  ELSE -- advance
    IF v_ya_pagado + p_amount > COALESCE(v_res.group_earnings,0) THEN
      RETURN jsonb_build_object('ok', false, 'error', 'exceeds_group_earnings',
        'ya_pagado', v_ya_pagado, 'group_earnings', v_res.group_earnings);
    END IF;
  END IF;

  v_disponible := CASE WHEN v_bucket = 'available' THEN v_wallet.available_balance ELSE v_wallet.pending_balance END;
  IF v_disponible < p_amount THEN
    RETURN jsonb_build_object('ok', false, 'error', 'insufficient_wallet_bucket',
      'bucket', v_bucket, 'disponible', v_disponible,
      'hint', 'Este grupo ya recibió este dinero por otra vía — revisa su historial antes de continuar');
  END IF;

  IF v_bucket = 'available' THEN
    UPDATE group_wallets SET available_balance = available_balance - p_amount, updated_at = NOW()
    WHERE id = v_wallet.id;
  ELSE
    UPDATE group_wallets SET pending_balance = pending_balance - p_amount, updated_at = NOW()
    WHERE id = v_wallet.id;
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
    CASE WHEN v_bucket = 'available' THEN gw.available_balance ELSE gw.pending_balance END,
    COALESCE(v_res.currency_code, 'MXN')
  FROM group_wallets gw WHERE gw.id = v_wallet.id;

  INSERT INTO financial_audit_logs (entity_type, entity_id, action, actor_id, actor_role, amount, notes)
  VALUES ('reservation', p_reservation_id, p_kind, auth.uid(), 'admin', p_amount,
    format('bucket=%s receipt=%s ref=%s transferred_at=%s', v_bucket, COALESCE(p_receipt_path,'n/a'), COALESCE(p_transfer_reference,'n/a'), p_transferred_at));

  IF p_kind = 'final_settlement' THEN
    UPDATE group_payment_requests SET status = 'completed'
    WHERE reservation_id = p_reservation_id AND status = 'pending';
  END IF;

  INSERT INTO notifications (user_id, type, title, body, data)
  SELECT g.owner_id, 'payment',
    CASE WHEN p_kind = 'advance' THEN '💵 Anticipo recibido' ELSE '✅ Pago realizado' END,
    CASE WHEN p_kind = 'advance'
      THEN format('Recibiste un anticipo de $%s para tu evento del %s.', p_amount, v_res.event_date)
      ELSE format('Se transfirió el pago final de $%s para tu evento del %s. ¡Liquidado!', p_amount, v_res.event_date)
    END,
    jsonb_build_object('reservation_id', p_reservation_id, 'screen', 'Wallet')
  FROM groups g WHERE g.id = v_res.group_id;

  RETURN jsonb_build_object(
    'ok', true, 'kind', p_kind, 'bucket_debitado', v_bucket,
    'total_pagado', v_ya_pagado + p_amount,
    'saldo_restante', COALESCE(v_res.group_earnings,0) - (v_ya_pagado + p_amount)
  );
END;
$function$;

COMMIT;

SELECT '533_final_settlement ✅' AS status;
