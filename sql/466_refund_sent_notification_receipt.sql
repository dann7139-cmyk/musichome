-- ============================================================
-- sql/466_refund_sent_notification_receipt.sql
-- UX de cierre del reembolso manual (decisión 2026-07-11):
--   · Al completarse el reembolso, el evento SE OCULTA de "Mis Eventos"
--     del cliente (filtro en la app).
--   · Por eso, la notificación "✅ Tu reembolso fue enviado" ahora lleva
--     receipt_path en data → al TOCARLA se abre el comprobante directo
--     (URL firmada). El comprobante no se pierde aunque el evento ya no
--     esté en la lista.
-- Solo cambia el INSERT de la notificación; el resto es idéntico a 464.
-- ============================================================

CREATE OR REPLACE FUNCTION public.admin_process_manual_refund(
  p_refund_id          UUID,
  p_action             TEXT,                 -- 'processing' | 'sent'
  p_transfer_reference TEXT DEFAULT NULL,
  p_receipt_path       TEXT DEFAULT NULL
)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_mr RECORD;
  v_receipt TEXT;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM profiles WHERE id = auth.uid() AND role = 'admin') THEN
    RETURN jsonb_build_object('ok', false, 'error', 'Solo administradores');
  END IF;
  IF p_action NOT IN ('processing', 'sent') THEN
    RETURN jsonb_build_object('ok', false, 'error', 'Acción inválida');
  END IF;

  SELECT * INTO v_mr FROM manual_refunds WHERE id = p_refund_id FOR UPDATE;
  IF NOT FOUND THEN RETURN jsonb_build_object('ok', false, 'error', 'not_found'); END IF;
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
          auth.uid(), 'admin', v_mr.amount,
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
$$;

GRANT EXECUTE ON FUNCTION public.admin_process_manual_refund(UUID, TEXT, TEXT, TEXT) TO authenticated;

-- ── VERIFICACIÓN ──────────────────────────────────────────────────────────────
SELECT prosrc LIKE '%receipt_path%' AS incluye_comprobante
FROM pg_proc WHERE proname = 'admin_process_manual_refund';
-- Esperado: true

SELECT '466_refund_sent_notification_receipt.sql ejecutado ✅' AS status;
