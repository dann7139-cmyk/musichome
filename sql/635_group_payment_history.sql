-- sql/635_group_payment_history.sql
--
-- Historial de pagos CON comprobante para el propio grupo — hoy la única
-- forma de ver un comprobante es tocando la notificación en el momento
-- en que llega; si el grupo la borra o pasa el tiempo, no hay forma de
-- volver a verlo (confirmado revisando WalletScreen/EarningsScreen: no
-- hay ninguna pantalla de historial de transacciones con comprobante).
--
-- Mismo patrón que admin_get_payment_history (sql/634) pero acotado a
-- SOLO el grupo del que llama — nunca puede ver el de otro grupo.
BEGIN;

CREATE OR REPLACE FUNCTION public.group_get_payment_history(p_limit integer DEFAULT 50)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_group_id UUID;
  v_result   JSONB;
BEGIN
  SELECT id INTO v_group_id FROM groups WHERE owner_id = auth.uid();
  IF v_group_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'no_group');
  END IF;

  SELECT jsonb_build_object('ok', true, 'items', COALESCE(jsonb_agg(y.item ORDER BY y.created_at DESC), '[]'::jsonb))
  INTO v_result
  FROM (
    SELECT x.created_at, x.item
    FROM (
      -- Pagos de eventos (advance / final_settlement)
      SELECT
        fal.created_at,
        jsonb_build_object(
          'id',           fal.id,
          'kind',         'evento',
          'amount',       fal.amount,
          'created_at',   fal.created_at,
          'folio',        r.folio,
          'event_date',   r.event_date,
          'receipt_path', substring(fal.notes from 'receipt=([^ ]+)'),
          'transfer_ref', substring(fal.notes from 'ref=([^ ]+)')
        ) AS item
      FROM financial_audit_logs fal
      JOIN reservations r ON r.id = fal.entity_id
      WHERE fal.entity_type = 'reservation'
        AND fal.action IN ('advance', 'final_settlement')
        AND r.group_id = v_group_id

      UNION ALL

      -- Propinas/regalos acumulados pagados
      SELECT
        fal.created_at,
        jsonb_build_object(
          'id',           fal.id,
          'kind',         'propina',
          'amount',       fal.amount,
          'created_at',   fal.created_at,
          'folio',        NULL,
          'event_date',   NULL,
          'receipt_path', substring(fal.notes from 'receipt=([^ ]+)'),
          'transfer_ref', substring(fal.notes from 'ref=([^ ]+)')
        ) AS item
      FROM financial_audit_logs fal
      WHERE fal.entity_type = 'group_gift_payout'
        AND fal.action = 'gift_payout'
        AND fal.entity_id = v_group_id

      UNION ALL

      -- Retiros generales (SPEI/ACH) — solo los del dueño de este grupo
      SELECT
        fal.created_at,
        jsonb_build_object(
          'id',           fal.id,
          'kind',         'retiro',
          'amount',       fal.amount,
          'created_at',   fal.created_at,
          'folio',        NULL,
          'event_date',   NULL,
          'receipt_path', substring(fal.notes from 'receipt=([^ ]+)'),
          'transfer_ref', substring(fal.notes from 'ref=([^ ]+)')
        ) AS item
      FROM financial_audit_logs fal
      JOIN withdrawals w ON w.id = fal.entity_id
      JOIN groups g      ON g.owner_id = w.user_id
      WHERE fal.entity_type = 'withdrawal'
        AND fal.action = 'payout_completed'
        AND g.id = v_group_id
    ) x
    ORDER BY x.created_at DESC
    LIMIT p_limit
  ) y;

  RETURN v_result;
END;
$function$;

COMMIT;
