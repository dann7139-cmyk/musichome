-- ============================================================
-- sql/533_final_settlement_ROLLBACK.sql
-- Revierte sql/533_final_settlement.sql
--
-- Restaura admin_register_group_payment a la definición exacta
-- de P1C (firma de 5 parámetros, capturada vía pg_get_functiondef
-- antes de aplicar P1E), restaura chk_wt_type sin 'final_settlement',
-- y elimina las columnas transfer_reference / transferred_at.
--
-- Solo correr en caso de reversión deliberada de la Fase P1E.
-- ============================================================

BEGIN;

DROP FUNCTION IF EXISTS public.admin_register_group_payment(uuid, numeric, text, text, text, text, timestamptz);

CREATE FUNCTION public.admin_register_group_payment(
  p_reservation_id UUID,
  p_amount NUMERIC,
  p_kind TEXT,
  p_receipt_path TEXT DEFAULT NULL::text,
  p_note TEXT DEFAULT NULL::text
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE
  v_group_id    UUID;
  v_res         RECORD;
  v_wallet      RECORD;
  v_ya_pagado   NUMERIC;
  v_disponible  NUMERIC;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM profiles WHERE id = auth.uid() AND role = 'admin') THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_admin');
  END IF;

  IF p_kind <> 'advance' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'kind_not_available_yet');
  END IF;
  IF p_amount IS NULL OR p_amount <= 0 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_amount');
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

  IF v_res.payout_status <> 'held' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'payout_status_not_eligible',
      'payout_status', v_res.payout_status);
  END IF;

  PERFORM ensure_group_wallet(v_res.group_id);
  SELECT * INTO v_wallet FROM group_wallets WHERE group_id = v_res.group_id FOR UPDATE;

  SELECT COALESCE(SUM(amount),0) INTO v_ya_pagado
  FROM group_reservation_payments WHERE reservation_id = p_reservation_id;
  IF v_ya_pagado + p_amount > COALESCE(v_res.group_earnings,0) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'exceeds_group_earnings',
      'ya_pagado', v_ya_pagado, 'group_earnings', v_res.group_earnings);
  END IF;

  v_disponible := v_wallet.pending_balance;
  IF v_disponible < p_amount THEN
    RETURN jsonb_build_object('ok', false, 'error', 'insufficient_wallet_bucket',
      'bucket', 'pending', 'disponible', v_disponible,
      'hint', 'Este grupo ya recibió este dinero por otra vía — revisa su historial antes de continuar');
  END IF;

  UPDATE group_wallets SET pending_balance = pending_balance - p_amount, updated_at = NOW()
  WHERE id = v_wallet.id;

  INSERT INTO group_reservation_payments
    (reservation_id, group_id, amount, kind, wallet_bucket_debited, receipt_path, note, registered_by)
  VALUES (p_reservation_id, v_res.group_id, p_amount, p_kind, 'pending', p_receipt_path, p_note, auth.uid());

  INSERT INTO wallet_transactions (group_wallet_id, group_id, type, amount, reservation_id, description, balance_after, currency_code)
  SELECT gw.id, gw.group_id, 'manual_advance', p_amount, p_reservation_id,
    format('Anticipo manual registrado — reserva %s', p_reservation_id),
    gw.pending_balance,
    COALESCE(v_res.currency_code, 'MXN')
  FROM group_wallets gw WHERE gw.id = v_wallet.id;

  INSERT INTO financial_audit_logs (entity_type, entity_id, action, actor_id, actor_role, amount, notes)
  VALUES ('reservation', p_reservation_id, 'manual_advance', auth.uid(), 'admin', p_amount,
    format('bucket=pending receipt=%s', COALESCE(p_receipt_path,'n/a')));

  INSERT INTO notifications (user_id, type, title, body, data)
  SELECT g.owner_id, 'payment', '💵 Anticipo recibido',
    format('Recibiste un anticipo de $%s para tu evento del %s.', p_amount, v_res.event_date),
    jsonb_build_object('reservation_id', p_reservation_id, 'screen', 'Wallet')
  FROM groups g WHERE g.id = v_res.group_id;

  RETURN jsonb_build_object('ok', true, 'bucket_debitado', 'pending', 'total_anticipado', v_ya_pagado + p_amount);
END;
$function$;

ALTER TABLE public.wallet_transactions DROP CONSTRAINT IF EXISTS chk_wt_type;
ALTER TABLE public.wallet_transactions ADD CONSTRAINT chk_wt_type
  CHECK (type = ANY (ARRAY[
    'credit_pending','credit_available','release_to_available','debit_payout',
    'refund_dispute','adjustment','event_earning','extra_hour','withdrawal',
    'commission','refund','platform_income','debit_refund','ad_income',
    'bid_income','recommendation_income','commission_correction','manual_advance'
  ]));

ALTER TABLE public.group_reservation_payments
  DROP COLUMN IF EXISTS transfer_reference,
  DROP COLUMN IF EXISTS transferred_at;

COMMIT;

SELECT '533_final_settlement_ROLLBACK ✅' AS status;
