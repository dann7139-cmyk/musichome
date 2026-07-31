-- ============================================================
-- sql/525_fix_create_booking_with_event_package_id_ROLLBACK.sql
--
-- Restaura create_booking_with_event() EXACTAMENTE a como estaba en
-- producción antes de sql/525 (capturada vía pg_get_functiondef el
-- 2026-07-30, antes de aplicar el parche) — es decir, reintroduce el
-- INSERT a la columna inexistente reservations.package_id. Solo correr
-- en caso de reversión deliberada de esta fase correctiva.
--
-- NO se toca ninguna tabla, dato, trigger ni constraint.
--
-- ⚠️ NUNCA se corre salvo emergencia deliberada (regla del proyecto para
-- archivos *_ROLLBACK).
-- ============================================================

BEGIN;

CREATE OR REPLACE FUNCTION public.create_booking_with_event(p_client_id uuid, p_group_id uuid, p_package_id uuid, p_event_date date, p_event_time time without time zone, p_address text, p_total_price numeric, p_notes text DEFAULT NULL::text, p_break_type text DEFAULT NULL::text, p_base_price numeric DEFAULT NULL::numeric, p_installment_plan text DEFAULT NULL::text, p_installment_months integer DEFAULT NULL::integer, p_installment_monthly_amount numeric DEFAULT NULL::numeric, p_payment_mode text DEFAULT 'full'::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_event_id       UUID;
  v_reservation_id UUID;
  v_flow_version   TEXT;
BEGIN
  PERFORM pg_advisory_xact_lock(hashtext(p_group_id::text || p_event_date::text));

  IF EXISTS (
    SELECT 1 FROM group_unavailability
    WHERE group_id = p_group_id AND date = p_event_date
  ) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'date_blocked');
  END IF;

  v_flow_version := CASE
    WHEN p_payment_mode = 'full' THEN 'full_payment_v2'
    ELSE 'legacy'
  END;
  INSERT INTO public.events (client_id, event_date, event_time, address, status)
  VALUES (p_client_id, p_event_date, p_event_time, p_address, 'active')
  RETURNING id INTO v_event_id;
  INSERT INTO public.reservations (
    event_id, group_id, package_id, client_id,
    event_date, event_time, address, notes, break_type,
    total_price, base_price, status,
    payment_mode, flow_version,
    installment_plan, installment_months, installment_monthly_amount
  )
  VALUES (
    v_event_id, p_group_id, p_package_id, p_client_id,
    p_event_date, p_event_time, p_address, p_notes, p_break_type,
    p_total_price, p_base_price, 'pending_payment',
    p_payment_mode, v_flow_version,
    p_installment_plan, p_installment_months, p_installment_monthly_amount
  )
  RETURNING id INTO v_reservation_id;
  RAISE NOTICE '[CREATE_BOOKING] reservation=% mode=% msi=%',
    v_reservation_id, p_payment_mode, COALESCE(p_installment_plan, '1_pago');
  RETURN jsonb_build_object(
    'reservation_id', v_reservation_id,
    'event_id',       v_event_id
  );
END;
$function$;

COMMIT;

SELECT '525_fix_create_booking_with_event_package_id_ROLLBACK ejecutado — INSERT a package_id restaurado' AS status;
