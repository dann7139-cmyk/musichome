-- ============================================================
-- sql/531_group_payment_requests_ROLLBACK.sql
-- Revierte sql/531_group_payment_requests.sql
--
-- Elimina la tabla/RPCs nuevas y restaura admin_get_pending_group_payments
-- a la versión de P1C (sin el campo payment_requested), capturada vía
-- pg_get_functiondef antes de este cambio.
--
-- Solo correr en caso de reversión deliberada de la Fase P1D.
-- ============================================================

BEGIN;

DROP FUNCTION IF EXISTS public.group_request_payment(UUID);
DROP FUNCTION IF EXISTS public.group_get_payable_reservations();
DROP TABLE IF EXISTS public.group_payment_requests;

CREATE OR REPLACE FUNCTION public.admin_get_pending_group_payments(p_limit integer DEFAULT 50)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE
  v_result jsonb;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM profiles WHERE id = auth.uid() AND role = 'admin') THEN
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
        'client_name',      p.full_name,
        'group_earnings',   r.group_earnings,
        'total_anticipado', COALESCE(gp.total_anticipado, 0),
        'saldo_pendiente',  r.group_earnings - COALESCE(gp.total_anticipado, 0),
        'bank_clabe',       w.bank_clabe,
        'bank_name',        w.bank_name,
        'account_holder',   w.account_holder,
        'bank_linked_at',   w.bank_linked_at
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
    WHERE r.payout_status  = 'released'
      AND r.payment_status IN ('paid','fully_paid','deposit_paid')
      AND COALESCE(r.group_earnings, 0) > 0
      AND (r.group_earnings - COALESCE(gp.total_anticipado, 0)) > 0
    ORDER BY r.event_date DESC NULLS LAST
    LIMIT p_limit
  ) x;

  RETURN v_result;
END;
$function$;

COMMIT;

SELECT '531_group_payment_requests_ROLLBACK ✅' AS status;
