-- Rollback de sql/592 — restaura create_booking_with_event() exactamente
-- como estaba antes (hash confirmado 4a18996e61e1156248b947285bf997d6,
-- 2026-09-01), SIN el candado auth.uid() = p_client_id.
-- ⚠️ Revertir esto reabre el hueco de seguridad documentado en sql/592 —
-- solo usar en emergencia deliberada.

BEGIN;

CREATE OR REPLACE FUNCTION public.create_booking_with_event(
  p_client_id uuid,
  p_group_id uuid,
  p_package_id uuid,
  p_event_date date,
  p_event_time time without time zone,
  p_address text,
  p_total_price numeric,
  p_notes text DEFAULT NULL::text,
  p_break_type text DEFAULT NULL::text,
  p_base_price numeric DEFAULT NULL::numeric,
  p_installment_plan text DEFAULT NULL::text,
  p_installment_months integer DEFAULT NULL::integer,
  p_installment_monthly_amount numeric DEFAULT NULL::numeric,
  p_payment_mode text DEFAULT 'full'::text,
  p_event_id uuid DEFAULT NULL::uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_event_id        UUID;
  v_reservation_id  UUID;
  v_flow_version    TEXT;
  v_distinct_groups INT;
BEGIN
  PERFORM pg_advisory_xact_lock(hashtext(p_group_id::text || p_event_date::text));

  IF EXISTS (
    SELECT 1 FROM group_unavailability
    WHERE group_id = p_group_id AND date = p_event_date
  ) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'date_blocked');
  END IF;

  PERFORM pg_advisory_xact_lock(
    hashtext(p_client_id::text || p_event_date::text || lower(trim(p_address)))
  );

  SELECT COUNT(DISTINCT group_id) INTO v_distinct_groups
  FROM public.reservations
  WHERE client_id = p_client_id
    AND event_date = p_event_date
    AND lower(trim(address)) = lower(trim(p_address))
    AND status = ANY (public.estados_que_ocupan())
    AND group_id <> p_group_id;

  IF v_distinct_groups >= 3 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'event_group_limit_reached');
  END IF;

  v_flow_version := CASE
    WHEN p_payment_mode = 'full' THEN 'full_payment_v2'
    ELSE 'legacy'
  END;

  BEGIN
    v_event_id := public.resolve_shared_event_id(p_client_id, p_event_id, p_event_date, p_event_time, p_address);
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM LIKE 'event_group_limit_reached%' THEN
      RETURN jsonb_build_object('ok', false, 'error', 'event_group_limit_reached');
    ELSIF SQLERRM LIKE 'event_not_owned_by_client%' THEN
      RETURN jsonb_build_object('ok', false, 'error', 'event_not_owned_by_client');
    ELSIF SQLERRM LIKE 'event_not_found%' THEN
      RETURN jsonb_build_object('ok', false, 'error', 'event_not_found');
    ELSE
      RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
    END IF;
  END;

  INSERT INTO public.reservations (
    event_id, group_id, client_id,
    event_date, event_time, address, notes, break_type,
    total_price, base_price, status,
    payment_mode, flow_version,
    installment_plan, installment_months, installment_monthly_amount
  )
  VALUES (
    v_event_id, p_group_id, p_client_id,
    p_event_date, p_event_time, p_address, p_notes, p_break_type,
    p_total_price, p_base_price, 'pending_payment',
    p_payment_mode, v_flow_version,
    p_installment_plan, p_installment_months, p_installment_monthly_amount
  )
  RETURNING id INTO v_reservation_id;

  RAISE NOTICE '[CREATE_BOOKING] reservation=% mode=% msi=% event=%',
    v_reservation_id, p_payment_mode, COALESCE(p_installment_plan, '1_pago'), v_event_id;

  RETURN jsonb_build_object(
    'reservation_id', v_reservation_id,
    'event_id',       v_event_id
  );
END;
$function$;

COMMIT;

SELECT '592_fix_booking_client_id_check_ROLLBACK ✅' AS status;
