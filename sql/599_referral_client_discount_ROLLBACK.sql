-- ============================================================
-- sql/599_referral_client_discount_ROLLBACK.sql
-- JAMÁS correr salvo emergencia deliberada.
-- Revierte sql/599: client_accept_quote y create_booking_with_event
-- regresan a como estaban (sin descuento de referido), se elimina la
-- función interna apply_referral_client_discount y las columnas nuevas
-- de referral_events.
-- ============================================================

BEGIN;

CREATE OR REPLACE FUNCTION public.client_accept_quote(
  p_quote_id   UUID,
  p_event_id   UUID DEFAULT NULL,
  p_msi_months INT  DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_quote RECORD;
  v_address TEXT;
  v_event_id UUID;
  v_event_time TIME;
  v_reservation_id UUID;
BEGIN
  IF auth.uid() IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_authenticated');
  END IF;

  SELECT * INTO v_quote FROM public.quotes WHERE id = p_quote_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'quote_not_found');
  END IF;
  IF v_quote.client_id <> auth.uid() THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_owner');
  END IF;

  IF v_quote.status = 'accepted' THEN
    SELECT id INTO v_reservation_id FROM public.reservations WHERE quote_id = p_quote_id LIMIT 1;
    IF v_reservation_id IS NOT NULL THEN
      RETURN jsonb_build_object(
        'ok', true, 'reservation_id', v_reservation_id,
        'event_id', v_quote.event_id, 'already_accepted', true
      );
    END IF;
  END IF;

  v_address := NULLIF(TRIM(BOTH ', ' FROM
    CONCAT_WS(', ', v_quote.event_address, v_quote.event_municipio, v_quote.event_estado)
  ), '');
  v_event_time := COALESCE(v_quote.event_time, '20:00')::TIME;

  BEGIN
    v_event_id := public.resolve_shared_event_id(
      auth.uid(), COALESCE(v_quote.event_id, p_event_id), v_quote.event_date, v_event_time, COALESCE(v_address, '')
    );
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

  BEGIN
    INSERT INTO public.reservations (
      event_id, client_id, group_id, event_date, event_time, address,
      total_price, status, quote_id, notes, msi_months,
      is_gift, gift_recipient_name, gift_recipient_contact, gift_message
    ) VALUES (
      v_event_id, auth.uid(), v_quote.group_id, v_quote.event_date, v_event_time, v_address,
      v_quote.total_amount, 'accepted', v_quote.id, v_quote.comments,
      CASE WHEN COALESCE(p_msi_months, 1) > 1 THEN p_msi_months ELSE NULL END,
      v_quote.is_gift, v_quote.gift_recipient_name, v_quote.gift_recipient_contact, v_quote.gift_message
    ) RETURNING id INTO v_reservation_id;
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM LIKE '%date_blocked%' OR SQLERRM LIKE '%date_taken%' THEN
      RETURN jsonb_build_object('ok', false, 'error', 'date_blocked');
    ELSIF SQLERRM LIKE '%daily_event_limit%' THEN
      RETURN jsonb_build_object('ok', false, 'error', 'daily_event_limit');
    ELSIF SQLERRM LIKE '%time_overlap%' THEN
      RETURN jsonb_build_object('ok', false, 'error', 'time_overlap');
    ELSIF SQLERRM LIKE '%event_group_limit_reached%' THEN
      RETURN jsonb_build_object('ok', false, 'error', 'event_group_limit_reached');
    ELSE
      RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
    END IF;
  END;

  UPDATE public.quotes SET status = 'accepted' WHERE id = p_quote_id;

  RETURN jsonb_build_object('ok', true, 'reservation_id', v_reservation_id, 'event_id', v_event_id);
END;
$function$;

CREATE OR REPLACE FUNCTION public.create_booking_with_event(
  p_client_id UUID,
  p_group_id UUID,
  p_package_id UUID,
  p_event_date DATE,
  p_event_time TIME,
  p_address TEXT,
  p_total_price NUMERIC,
  p_notes TEXT DEFAULT NULL,
  p_break_type TEXT DEFAULT NULL,
  p_base_price NUMERIC DEFAULT NULL,
  p_installment_plan TEXT DEFAULT NULL,
  p_installment_months INT DEFAULT NULL,
  p_installment_monthly_amount NUMERIC DEFAULT NULL,
  p_payment_mode TEXT DEFAULT 'full',
  p_event_id UUID DEFAULT NULL
) RETURNS jsonb
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
  IF auth.uid() IS NULL OR p_client_id <> auth.uid() THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_owner');
  END IF;

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

DROP FUNCTION IF EXISTS public.apply_referral_client_discount(UUID, NUMERIC, NUMERIC, TEXT);

ALTER TABLE public.referral_events
  DROP COLUMN IF EXISTS client_discount_applied,
  DROP COLUMN IF EXISTS client_discount_amount,
  DROP COLUMN IF EXISTS client_discount_currency;

COMMIT;

SELECT '599_referral_client_discount — REVERTIDO' AS status;
