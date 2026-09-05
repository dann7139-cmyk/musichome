-- ============================================================
-- sql/603_no_break_timer_for_non_performance_categories.sql
-- ✅ APLICADO A PRODUCCIÓN 2026-09-03.
--
-- PETICIÓN REAL DEL USUARIO (2026-09-03), probando la app real en su
-- teléfono: "el grupo musical, solista saxofonista eso lo llenan
-- también luz y sonido y dj creo, pero los otros como Comediante
-- Payasos Comida renta mesas.. eso no lleva temporizador." — confirmado
-- explícitamente que se refiere a la pantalla del GRUPO durante el
-- evento en vivo (EventTimerScreen.tsx) donde hoy TODOS los proveedores,
-- sin importar su categoría, tienen que elegir un tipo de descanso
-- (A/B/D) y se les arma un calendario de tandas con descansos de 15 min
-- — algo que no tiene sentido para un comediante, payaso, servicio de
-- comida o renta de mesas/sillas.
--
-- Hallazgo real revisando el código ANTES de tocar nada: la app YA
-- tiene un modo "Sin descanso" (break_type='D', "Tocan sin parar las X
-- horas, solo visible para el grupo") completamente construido y
-- probado — EventTimerScreen.tsx YA salta el selector de descanso
-- cuando `reservation.break_type` ya viene poblado desde la reserva
-- (en vez de NULL, que es cuando hoy SIEMPRE se le pregunta al grupo).
-- Por eso este cambio es puramente de BACKEND: asignar 'D' de una vez
-- al crear la reserva para las categorías correctas, sin tocar la UI
-- del temporizador — la lógica ya existente hace el resto sola.
--
-- Nueva función interna `group_default_break_type(p_group_id)` —
-- fuente única de verdad: devuelve 'D' si `groups.genre` es
-- Comediante, Payasos, Comida, Renta de brincolines, Inflables
-- acuáticos, Renta de mesas o Renta de sillas; NULL en cualquier otro
-- caso (grupo musical, solista, DJ, luz/sonido — sin cambios, el grupo
-- sigue eligiendo su tipo de descanso como siempre).
--
-- Se usa desde los 3 caminos reales que crean una reserva
-- (client_accept_quote, create_booking_with_event,
-- client_accept_proposal — mismos 3 que ya tenían el descuento de
-- referido de sql/599) — así queda igual sin importar si el cliente
-- llegó por cotización normal, reserva directa, u otra ciudad/Express.
-- En create_booking_with_event y client_accept_proposal, el resultado
-- de esta función tiene prioridad sobre lo que mande la app
-- (`p_break_type`/`event_requests.break_type`) — si la categoría no
-- lleva temporizador, siempre gana 'D'.
--
-- También se corrigió el texto de la alerta en EventTimerScreen.tsx
-- que decía "El cliente eligió modo corrido" — ya no es preciso porque
-- ahora 'D' se asigna automáticamente por categoría, no por una
-- elección real del cliente (esa parte del formulario del cliente
-- sigue deshabilitada, como ya estaba).
--
-- Probado en transacción autorevertible: banda musical → break_type
-- queda NULL (sin cambios); payasos → 'D' automático vía
-- client_accept_quote; comida → 'D' automático vía
-- create_booking_with_event, IGNORANDO un p_break_type='A' que mandó
-- la app a propósito en la prueba (para confirmar que la categoría
-- manda). 0 residuo verificado. Aplicado para real después, verificado
-- que los 3 caminos usan la función nueva.
-- ============================================================

BEGIN;

CREATE OR REPLACE FUNCTION public.group_default_break_type(p_group_id UUID)
RETURNS TEXT
LANGUAGE sql
STABLE
SET search_path TO 'public'
AS $function$
  SELECT CASE
    WHEN g.genre = ANY(ARRAY[
      'Comediante', 'Payasos', 'Comida',
      'Renta de brincolines', 'Inflables acuáticos',
      'Renta de mesas', 'Renta de sillas'
    ]) THEN 'D'
    ELSE NULL
  END
  FROM public.groups g WHERE g.id = p_group_id;
$function$;

CREATE OR REPLACE FUNCTION public.client_accept_quote(
  p_quote_id UUID, p_event_id UUID DEFAULT NULL, p_msi_months INT DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE
  v_quote RECORD; v_address TEXT; v_event_id UUID; v_event_time TIME;
  v_reservation_id UUID; v_currency TEXT; v_final_total NUMERIC; v_break_type TEXT;
BEGIN
  IF auth.uid() IS NULL THEN RETURN jsonb_build_object('ok', false, 'error', 'not_authenticated'); END IF;
  SELECT * INTO v_quote FROM public.quotes WHERE id = p_quote_id;
  IF NOT FOUND THEN RETURN jsonb_build_object('ok', false, 'error', 'quote_not_found'); END IF;
  IF v_quote.client_id <> auth.uid() THEN RETURN jsonb_build_object('ok', false, 'error', 'not_owner'); END IF;
  IF v_quote.status = 'accepted' THEN
    SELECT id INTO v_reservation_id FROM public.reservations WHERE quote_id = p_quote_id LIMIT 1;
    IF v_reservation_id IS NOT NULL THEN
      RETURN jsonb_build_object('ok', true, 'reservation_id', v_reservation_id, 'event_id', v_quote.event_id, 'already_accepted', true);
    END IF;
  END IF;
  v_address := NULLIF(TRIM(BOTH ', ' FROM CONCAT_WS(', ', v_quote.event_address, v_quote.event_municipio, v_quote.event_estado)), '');
  v_event_time := COALESCE(v_quote.event_time, '20:00')::TIME;
  BEGIN
    v_event_id := public.resolve_shared_event_id(auth.uid(), COALESCE(v_quote.event_id, p_event_id), v_quote.event_date, v_event_time, COALESCE(v_address, ''));
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM LIKE 'event_group_limit_reached%' THEN RETURN jsonb_build_object('ok', false, 'error', 'event_group_limit_reached');
    ELSIF SQLERRM LIKE 'event_not_owned_by_client%' THEN RETURN jsonb_build_object('ok', false, 'error', 'event_not_owned_by_client');
    ELSIF SQLERRM LIKE 'event_not_found%' THEN RETURN jsonb_build_object('ok', false, 'error', 'event_not_found');
    ELSE RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
    END IF;
  END;
  SELECT COALESCE(c.currency_code, 'MXN') INTO v_currency
  FROM public.groups g LEFT JOIN public.countries c ON c.id = g.country_id WHERE g.id = v_quote.group_id;
  v_final_total := public.apply_referral_client_discount(auth.uid(), v_quote.total_amount, v_quote.base_price, v_currency);
  v_break_type := public.group_default_break_type(v_quote.group_id);
  BEGIN
    INSERT INTO public.reservations (
      event_id, client_id, group_id, event_date, event_time, address,
      base_price, total_price, status, quote_id, notes, msi_months, break_type,
      is_gift, gift_recipient_name, gift_recipient_contact, gift_message
    ) VALUES (
      v_event_id, auth.uid(), v_quote.group_id, v_quote.event_date, v_event_time, v_address,
      v_quote.base_price, v_final_total, 'accepted', v_quote.id, v_quote.comments,
      CASE WHEN COALESCE(p_msi_months, 1) > 1 THEN p_msi_months ELSE NULL END, v_break_type,
      v_quote.is_gift, v_quote.gift_recipient_name, v_quote.gift_recipient_contact, v_quote.gift_message
    ) RETURNING id INTO v_reservation_id;
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM LIKE '%date_blocked%' OR SQLERRM LIKE '%date_taken%' THEN RETURN jsonb_build_object('ok', false, 'error', 'date_blocked');
    ELSIF SQLERRM LIKE '%daily_event_limit%' THEN RETURN jsonb_build_object('ok', false, 'error', 'daily_event_limit');
    ELSIF SQLERRM LIKE '%time_overlap%' THEN RETURN jsonb_build_object('ok', false, 'error', 'time_overlap');
    ELSIF SQLERRM LIKE '%event_group_limit_reached%' THEN RETURN jsonb_build_object('ok', false, 'error', 'event_group_limit_reached');
    ELSE RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
    END IF;
  END;
  UPDATE public.quotes SET status = 'accepted' WHERE id = p_quote_id;
  RETURN jsonb_build_object('ok', true, 'reservation_id', v_reservation_id, 'event_id', v_event_id);
END;
$function$;

CREATE OR REPLACE FUNCTION public.create_booking_with_event(
  p_client_id UUID, p_group_id UUID, p_package_id UUID, p_event_date DATE, p_event_time TIME,
  p_address TEXT, p_total_price NUMERIC, p_notes TEXT DEFAULT NULL, p_break_type TEXT DEFAULT NULL,
  p_base_price NUMERIC DEFAULT NULL, p_installment_plan TEXT DEFAULT NULL, p_installment_months INT DEFAULT NULL,
  p_installment_monthly_amount NUMERIC DEFAULT NULL, p_payment_mode TEXT DEFAULT 'full', p_event_id UUID DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE
  v_event_id UUID; v_reservation_id UUID; v_flow_version TEXT; v_distinct_groups INT;
  v_currency TEXT; v_final_total NUMERIC; v_break_type TEXT;
BEGIN
  IF auth.uid() IS NULL OR p_client_id <> auth.uid() THEN RETURN jsonb_build_object('ok', false, 'error', 'not_owner'); END IF;
  PERFORM pg_advisory_xact_lock(hashtext(p_group_id::text || p_event_date::text));
  IF EXISTS (SELECT 1 FROM group_unavailability WHERE group_id = p_group_id AND date = p_event_date) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'date_blocked');
  END IF;
  PERFORM pg_advisory_xact_lock(hashtext(p_client_id::text || p_event_date::text || lower(trim(p_address))));
  SELECT COUNT(DISTINCT group_id) INTO v_distinct_groups FROM public.reservations
  WHERE client_id = p_client_id AND event_date = p_event_date AND lower(trim(address)) = lower(trim(p_address))
    AND status = ANY (public.estados_que_ocupan()) AND group_id <> p_group_id;
  IF v_distinct_groups >= 3 THEN RETURN jsonb_build_object('ok', false, 'error', 'event_group_limit_reached'); END IF;
  v_flow_version := CASE WHEN p_payment_mode = 'full' THEN 'full_payment_v2' ELSE 'legacy' END;
  BEGIN
    v_event_id := public.resolve_shared_event_id(p_client_id, p_event_id, p_event_date, p_event_time, p_address);
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM LIKE 'event_group_limit_reached%' THEN RETURN jsonb_build_object('ok', false, 'error', 'event_group_limit_reached');
    ELSIF SQLERRM LIKE 'event_not_owned_by_client%' THEN RETURN jsonb_build_object('ok', false, 'error', 'event_not_owned_by_client');
    ELSIF SQLERRM LIKE 'event_not_found%' THEN RETURN jsonb_build_object('ok', false, 'error', 'event_not_found');
    ELSE RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
    END IF;
  END;
  SELECT COALESCE(c.currency_code, 'MXN') INTO v_currency
  FROM public.groups g LEFT JOIN public.countries c ON c.id = g.country_id WHERE g.id = p_group_id;
  v_final_total := public.apply_referral_client_discount(p_client_id, p_total_price, p_base_price, v_currency);
  v_break_type := COALESCE(public.group_default_break_type(p_group_id), p_break_type);
  INSERT INTO public.reservations (
    event_id, group_id, client_id, event_date, event_time, address, notes, break_type,
    total_price, base_price, status, payment_mode, flow_version,
    installment_plan, installment_months, installment_monthly_amount
  ) VALUES (
    v_event_id, p_group_id, p_client_id, p_event_date, p_event_time, p_address, p_notes, v_break_type,
    v_final_total, p_base_price, 'pending_payment', p_payment_mode, v_flow_version,
    p_installment_plan, p_installment_months, p_installment_monthly_amount
  ) RETURNING id INTO v_reservation_id;
  RAISE NOTICE '[CREATE_BOOKING] reservation=% mode=% msi=% event=%',
    v_reservation_id, p_payment_mode, COALESCE(p_installment_plan, '1_pago'), v_event_id;
  RETURN jsonb_build_object('reservation_id', v_reservation_id, 'event_id', v_event_id);
END;
$function$;

CREATE OR REPLACE FUNCTION public.client_accept_proposal(p_request_id uuid, p_event_id uuid DEFAULT NULL::uuid)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE
  v_req          RECORD;
  v_group        RECORD;
  v_client_total NUMERIC;
  v_group_price  NUMERIC;
  v_commission   NUMERIC;
  v_res_id       UUID;
  v_hours        INT;
  v_code         TEXT;
  v_resolved_event_id UUID;
  v_break_type   TEXT;
BEGIN
  SELECT * INTO v_req FROM public.event_requests WHERE id = p_request_id;
  IF NOT FOUND THEN RETURN jsonb_build_object('ok', false, 'error', 'request_not_found'); END IF;
  IF v_req.client_id <> auth.uid() THEN RETURN jsonb_build_object('ok', false, 'error', 'not_owner'); END IF;

  SELECT id INTO v_res_id FROM public.reservations WHERE event_request_id = p_request_id LIMIT 1;
  IF FOUND THEN
    RETURN jsonb_build_object('ok', true, 'reservation_id', v_res_id, 'already_created', true);
  END IF;

  IF v_req.status <> 'en_negociacion' THEN RETURN jsonb_build_object('ok', false, 'error', 'not_in_negotiation'); END IF;
  IF v_req.negotiating_group_id IS NULL THEN RETURN jsonb_build_object('ok', false, 'error', 'no_group'); END IF;

  SELECT * INTO v_group FROM public.groups WHERE owner_id = v_req.negotiating_group_id LIMIT 1;
  IF NOT FOUND THEN RETURN jsonb_build_object('ok', false, 'error', 'group_not_found'); END IF;

  v_hours := COALESCE(v_req.hours, 1);
  v_client_total := COALESCE(
    (v_req.proposal_data->>'total_amount')::NUMERIC,
    (v_req.proposal_data->>'group_price')::NUMERIC,
    (v_req.proposal_data->>'total')::NUMERIC, 0);
  v_group_price := COALESCE(
    (v_req.proposal_data->>'group_price')::NUMERIC,
    (v_req.proposal_data->>'group_earnings')::NUMERIC,
    ROUND(v_client_total / 1.15), 0);
  v_commission := v_client_total - v_group_price;
  v_code := LPAD(FLOOR(RANDOM() * 10000)::TEXT, 4, '0');
  v_break_type := COALESCE(public.group_default_break_type(v_group.id), COALESCE(v_req.break_type, 'A'));

  IF p_event_id IS NOT NULL THEN
    v_resolved_event_id := public.resolve_shared_event_id(
      v_req.client_id, p_event_id, v_req.event_date,
      COALESCE((v_req.proposal_data->>'start_time'), v_req.event_time::TEXT, '20:00')::TIME,
      COALESCE(v_req.location_address, v_req.location_city, '')
    );
  ELSE
    v_resolved_event_id := NULL;
  END IF;

  INSERT INTO public.reservations (
    group_id, client_id, event_date, event_time, address, total_price, base_price,
    platform_commission, group_earnings, status, hours_count, event_request_id,
    break_type, arrival_code, event_id
  ) VALUES (
    v_group.id, v_req.client_id, v_req.event_date,
    COALESCE((v_req.proposal_data->>'start_time'), v_req.event_time::TEXT, '20:00')::TIME,
    COALESCE(v_req.location_address, v_req.location_city, ''),
    v_client_total, v_group_price, v_commission, v_group_price, 'accepted',
    v_hours, p_request_id, v_break_type, v_code, v_resolved_event_id
  )
  RETURNING id INTO v_res_id;

  UPDATE public.event_requests
  SET status = 'accepted', accepted_by_group_id = v_group.id, accepted_reservation_id = v_res_id
  WHERE id = p_request_id;

  RETURN jsonb_build_object('ok', true, 'reservation_id', v_res_id, 'arrival_code', v_code, 'event_id', v_resolved_event_id);
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$function$;

COMMIT;

SELECT '603_no_break_timer_for_non_performance_categories — APLICADO A PRODUCCIÓN 2026-09-03' AS status;
