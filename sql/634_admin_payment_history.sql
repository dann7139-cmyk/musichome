-- sql/634_admin_payment_history.sql
--
-- Historial de pagos con comprobante — para la cuenta admin completa y
-- para admin_ops (cada quien ve lo suyo: admin_ops solo su país). Lee
-- financial_audit_logs, que YA registra cada pago con su `receipt` en el
-- texto de `notes` (no hay tabla de comprobantes separada) — se extrae
-- con una expresión regular en vez de agregar columnas nuevas.
--
-- Tipos que aparecen, separados por `kind` para que la pantalla los
-- muestre en secciones distintas (pedido explícito: "que se dividan los
-- regalos"):
--   'evento'   → advance / final_settlement  (pago a un grupo por su evento)
--   'propina'  → gift_payout                 (pago de propinas/regalos acumulados)
--   'retiro'   → payout_completed            (retiro general vía SPEI/ACH)
--   'reembolso'→ manual_refund_completed     (reembolso a un cliente)
BEGIN;

CREATE OR REPLACE FUNCTION public.admin_get_payment_history(p_limit integer DEFAULT 100)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_caller_role TEXT;
  v_country     TEXT;
  v_result      JSONB;
BEGIN
  SELECT role INTO v_caller_role FROM profiles WHERE id = auth.uid();
  IF v_caller_role NOT IN ('admin', 'admin_ops') THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_admin');
  END IF;
  IF v_caller_role = 'admin_ops' THEN
    v_country := admin_ops_country();
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
        'id',            fal.id,
        'kind',          'evento',
        'action',        fal.action,
        'amount',        fal.amount,
        'created_at',    fal.created_at,
        'group_name',    g.name,
        'country_code',  country_code_of(g.country),
        'receipt_path',  substring(fal.notes from 'receipt=([^ ]+)'),
        'transfer_ref',  substring(fal.notes from 'ref=([^ ]+)')
      ) AS item
    FROM financial_audit_logs fal
    JOIN reservations r ON r.id = fal.entity_id
    JOIN groups g       ON g.id = r.group_id
    WHERE fal.entity_type = 'reservation'
      AND fal.action IN ('advance', 'final_settlement')
      AND (v_caller_role = 'admin' OR country_code_of(g.country) = v_country)

    UNION ALL

    -- Propinas/regalos acumulados pagados
    SELECT
      fal.created_at,
      jsonb_build_object(
        'id',            fal.id,
        'kind',          'propina',
        'action',        fal.action,
        'amount',        fal.amount,
        'created_at',    fal.created_at,
        'group_name',    g.name,
        'country_code',  country_code_of(g.country),
        'receipt_path',  substring(fal.notes from 'receipt=([^ ]+)'),
        'transfer_ref',  substring(fal.notes from 'ref=([^ ]+)')
      ) AS item
    FROM financial_audit_logs fal
    JOIN groups g ON g.id = fal.entity_id
    WHERE fal.entity_type = 'group_gift_payout'
      AND fal.action = 'gift_payout'
      AND (v_caller_role = 'admin' OR country_code_of(g.country) = v_country)

    UNION ALL

    -- Retiros generales (SPEI/ACH)
    SELECT
      fal.created_at,
      jsonb_build_object(
        'id',            fal.id,
        'kind',          'retiro',
        'action',        fal.action,
        'amount',        fal.amount,
        'created_at',    fal.created_at,
        'group_name',    COALESCE(g.name, p.full_name),
        'country_code',  country_code_of(COALESCE(g.country, p.country)),
        'receipt_path',  substring(fal.notes from 'receipt=([^ ]+)'),
        'transfer_ref',  substring(fal.notes from 'ref=([^ ]+)')
      ) AS item
    FROM financial_audit_logs fal
    JOIN withdrawals w   ON w.id = fal.entity_id
    JOIN profiles p      ON p.id = w.user_id
    LEFT JOIN groups g   ON g.owner_id = w.user_id
    WHERE fal.entity_type = 'withdrawal'
      AND fal.action = 'payout_completed'
      AND (v_caller_role = 'admin' OR country_code_of(COALESCE(g.country, p.country)) = v_country)

    UNION ALL

    -- Reembolsos manuales enviados
    SELECT
      fal.created_at,
      jsonb_build_object(
        'id',            fal.id,
        'kind',          'reembolso',
        'action',        fal.action,
        'amount',        fal.amount,
        'created_at',    fal.created_at,
        'group_name',    p.full_name,
        'country_code',  country_code_of(p.country),
        'receipt_path',  substring(fal.notes from 'receipt=([^ ]+)'),
        'transfer_ref',  substring(fal.notes from 'ref=([^ ]+)')
      ) AS item
    FROM financial_audit_logs fal
    JOIN manual_refunds mr ON mr.id = fal.entity_id
    JOIN profiles p        ON p.id = mr.client_id
    WHERE fal.entity_type = 'manual_refund'
      AND fal.action = 'manual_refund_completed'
      AND (v_caller_role = 'admin' OR country_code_of(p.country) = v_country)
    ) x
    ORDER BY x.created_at DESC
    LIMIT p_limit
  ) y;

  RETURN v_result;
END;
$function$;

COMMIT;
