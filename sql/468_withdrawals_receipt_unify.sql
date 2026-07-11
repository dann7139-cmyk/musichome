-- ============================================================
-- sql/468_withdrawals_receipt_unify.sql
-- Unificar el retiro del grupo en UNA sola cola (hallazgo 2026-07-11):
--
--   request_withdrawal escribe en `withdrawals` (sql/59+460), pero la cola
--   nueva del panel financiero leía `payout_requests` (tabla paralela vieja
--   de sql/184 que nadie alimenta). Se unifica TODO sobre `withdrawals`:
--
--   · withdrawals gana transfer_reference / receipt_path / processed_by
--   · admin_complete_payout ahora opera sobre withdrawals:
--     status → 'completed' + comprobante + notifica al grupo (el tap de la
--     notificación abre la foto — mismo mecanismo que reembolsos manuales)
-- ============================================================

BEGIN;

ALTER TABLE withdrawals ADD COLUMN IF NOT EXISTS transfer_reference TEXT;
ALTER TABLE withdrawals ADD COLUMN IF NOT EXISTS receipt_path       TEXT;
ALTER TABLE withdrawals ADD COLUMN IF NOT EXISTS processed_by       UUID;

CREATE OR REPLACE FUNCTION public.admin_complete_payout(
  p_payout_id          UUID,
  p_transfer_reference TEXT,
  p_receipt_path       TEXT DEFAULT NULL
)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_wd RECORD;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM profiles WHERE id = auth.uid() AND role = 'admin') THEN
    RETURN jsonb_build_object('ok', false, 'error', 'Solo administradores');
  END IF;

  SELECT * INTO v_wd FROM withdrawals WHERE id = p_payout_id FOR UPDATE;
  IF NOT FOUND THEN RETURN jsonb_build_object('ok', false, 'error', 'not_found'); END IF;
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

  INSERT INTO financial_audit_logs (entity_type, entity_id, action, actor_id, actor_role, amount, notes)
  VALUES ('withdrawal', p_payout_id, 'payout_completed', auth.uid(), 'admin', v_wd.amount,
    format('ref=%s receipt=%s', p_transfer_reference, COALESCE(p_receipt_path, 'n/a')));

  -- Notificar al grupo — el tap abre el comprobante (receipt_path en data)
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
$$;

GRANT EXECUTE ON FUNCTION public.admin_complete_payout(UUID, TEXT, TEXT) TO authenticated;

COMMIT;

-- ── VERIFICACIONES ────────────────────────────────────────────────────────────
-- V1: columnas nuevas en withdrawals
SELECT column_name FROM information_schema.columns
WHERE table_name = 'withdrawals'
  AND column_name IN ('transfer_reference','receipt_path','processed_by');
-- Esperado: 3 filas

-- V2: la función ahora opera sobre withdrawals
SELECT prosrc LIKE '%FROM withdrawals%' AS opera_sobre_withdrawals
FROM pg_proc WHERE proname = 'admin_complete_payout';
-- Esperado: true

-- V3: tu solicitud de prueba está en la cola
SELECT id, amount, status, bank_clabe, bank_name, account_holder
FROM withdrawals ORDER BY created_at DESC LIMIT 3;

SELECT '468_withdrawals_receipt_unify.sql ejecutado ✅' AS status;
