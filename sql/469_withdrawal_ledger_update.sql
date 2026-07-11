-- ============================================================
-- sql/469_withdrawal_ledger_update.sql
-- El historial del wallet del grupo debe reflejar cuando el retiro
-- YA FUE TRANSFERIDO (feedback 2026-07-11):
--
--   · request_withdrawal ya inserta el débito "Retiro SPEI solicitado…"
--     (el dinero se descuenta al solicitar — eso no cambia).
--   · admin_complete_payout ahora ACTUALIZA ese mismo renglón a
--     "✅ Retiro transferido — ref X" (no inserta un segundo débito,
--     que se leería como doble cobro).
--   + Backfill del retiro de prueba ya completado.
-- ============================================================

BEGIN;

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

  -- Historial del wallet: el débito del retiro pasa a "transferido ✓"
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
  VALUES ('withdrawal', p_payout_id, 'payout_completed', auth.uid(), 'admin', v_wd.amount,
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
$$;

GRANT EXECUTE ON FUNCTION public.admin_complete_payout(UUID, TEXT, TEXT) TO authenticated;

-- ── Backfill: actualizar el historial de retiros YA completados ──────────────
UPDATE wallet_transactions wt SET
  description = format('✅ Retiro transferido a tu cuenta ···%s — ref %s',
                       COALESCE(RIGHT(w.bank_clabe, 4), '????'),
                       COALESCE(w.transfer_reference, 's/ref'))
FROM withdrawals w
JOIN groups g ON g.owner_id = w.user_id
WHERE w.status = 'completed'
  AND wt.group_id = g.id
  AND wt.type = 'debit_payout'
  AND wt.amount = w.amount
  AND wt.description LIKE 'Retiro SPEI solicitado%';

COMMIT;

-- ── VERIFICACIÓN ──────────────────────────────────────────────────────────────
-- El historial del grupo debe mostrar "✅ Retiro transferido…"
SELECT type, amount, LEFT(description, 60), created_at
FROM wallet_transactions
WHERE type = 'debit_payout'
ORDER BY created_at DESC LIMIT 3;

SELECT '469_withdrawal_ledger_update.sql ejecutado ✅' AS status;
