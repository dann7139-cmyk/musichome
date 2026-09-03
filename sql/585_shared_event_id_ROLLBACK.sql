-- ============================================================
-- sql/585_shared_event_id_ROLLBACK.sql
-- Revierte sql/585_shared_event_id.sql. Usar solo en emergencia
-- deliberada. Restaura create_booking_with_event() y
-- client_accept_proposal() a su definición previa (sin el parámetro
-- p_event_id), elimina las funciones nuevas y la FK.
-- ============================================================

BEGIN;

-- Auditoría final (2026-09-02): esta lista estaba incompleta — faltaban 4
-- objetos que sql/585 sí crea (trigger nuevo, su función, la RPC de sonido
-- y la columna quotes.event_id). Sin esto, un rollback "exitoso" habría
-- dejado el trigger paralelo y la columna nueva activos igual, un estado
-- híbrido no probado. Corregido antes de que este archivo se use nunca.
DROP TRIGGER IF EXISTS trg_enforce_max_groups_per_shared_event ON public.reservations;
DROP FUNCTION IF EXISTS public.enforce_max_groups_per_shared_event();
DROP FUNCTION IF EXISTS public.client_get_event_sound_context(UUID);
DROP FUNCTION IF EXISTS public.admin_get_event_detail(UUID);
DROP FUNCTION IF EXISTS public.client_get_my_events();
DROP FUNCTION IF EXISTS public.resolve_shared_event_id(UUID, UUID, DATE, TIME, TEXT);

-- client_accept_proposal: restaurar firma original (sin p_event_id)
DROP FUNCTION IF EXISTS public.client_accept_proposal(UUID, UUID);
CREATE OR REPLACE FUNCTION public.client_accept_proposal(p_request_id UUID)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $function$
DECLARE
  v_req RECORD; v_group RECORD; v_client_total NUMERIC; v_group_price NUMERIC;
  v_commission NUMERIC; v_res_id UUID; v_hours INT; v_code TEXT;
BEGIN
  SELECT * INTO v_req FROM public.event_requests WHERE id = p_request_id;
  IF NOT FOUND THEN RETURN jsonb_build_object('ok', false, 'error', 'request_not_found'); END IF;
  IF v_req.client_id <> auth.uid() THEN RETURN jsonb_build_object('ok', false, 'error', 'not_owner'); END IF;
  SELECT id INTO v_res_id FROM public.reservations WHERE event_request_id = p_request_id LIMIT 1;
  IF FOUND THEN RETURN jsonb_build_object('ok', true, 'reservation_id', v_res_id, 'already_created', true); END IF;
  IF v_req.status <> 'en_negociacion' THEN RETURN jsonb_build_object('ok', false, 'error', 'not_in_negotiation'); END IF;
  IF v_req.negotiating_group_id IS NULL THEN RETURN jsonb_build_object('ok', false, 'error', 'no_group'); END IF;
  SELECT * INTO v_group FROM public.groups WHERE owner_id = v_req.negotiating_group_id LIMIT 1;
  IF NOT FOUND THEN RETURN jsonb_build_object('ok', false, 'error', 'group_not_found'); END IF;
  v_hours := COALESCE(v_req.hours, 1);
  v_client_total := COALESCE((v_req.proposal_data->>'total_amount')::NUMERIC, (v_req.proposal_data->>'group_price')::NUMERIC, (v_req.proposal_data->>'total')::NUMERIC, 0);
  v_group_price := COALESCE((v_req.proposal_data->>'group_price')::NUMERIC, (v_req.proposal_data->>'group_earnings')::NUMERIC, ROUND(v_client_total / 1.15), 0);
  v_commission := v_client_total - v_group_price;
  v_code := LPAD(FLOOR(RANDOM() * 10000)::TEXT, 4, '0');
  INSERT INTO public.reservations (
    group_id, client_id, event_date, event_time, address, total_price, base_price,
    platform_commission, group_earnings, status, hours_count, event_request_id, break_type, arrival_code
  ) VALUES (
    v_group.id, v_req.client_id, v_req.event_date,
    COALESCE((v_req.proposal_data->>'start_time'), v_req.event_time::TEXT, '20:00')::TIME,
    COALESCE(v_req.location_address, v_req.location_city, ''),
    v_client_total, v_group_price, v_commission, v_group_price, 'accepted', v_hours, p_request_id, COALESCE(v_req.break_type, 'A'), v_code
  ) RETURNING id INTO v_res_id;
  UPDATE public.event_requests SET status = 'accepted', accepted_by_group_id = v_group.id, accepted_reservation_id = v_res_id WHERE id = p_request_id;
  RETURN jsonb_build_object('ok', true, 'reservation_id', v_res_id, 'arrival_code', v_code);
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$function$;

-- create_booking_with_event: restaurar firma original (sin p_event_id)
DROP FUNCTION IF EXISTS public.create_booking_with_event(uuid,uuid,uuid,date,time,text,numeric,text,text,numeric,text,integer,numeric,text,uuid);
CREATE OR REPLACE FUNCTION public.create_booking_with_event(
  p_client_id uuid, p_group_id uuid, p_package_id uuid, p_event_date date, p_event_time time without time zone,
  p_address text, p_total_price numeric, p_notes text DEFAULT NULL, p_break_type text DEFAULT NULL,
  p_base_price numeric DEFAULT NULL, p_installment_plan text DEFAULT NULL, p_installment_months integer DEFAULT NULL,
  p_installment_monthly_amount numeric DEFAULT NULL, p_payment_mode text DEFAULT 'full'
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $function$
DECLARE
  v_event_id UUID; v_reservation_id UUID; v_flow_version TEXT; v_distinct_groups INT;
BEGIN
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
  INSERT INTO public.events (client_id, event_date, event_time, address, status)
  VALUES (p_client_id, p_event_date, p_event_time, p_address, 'active') RETURNING id INTO v_event_id;
  INSERT INTO public.reservations (
    event_id, group_id, client_id, event_date, event_time, address, notes, break_type,
    total_price, base_price, status, payment_mode, flow_version,
    installment_plan, installment_months, installment_monthly_amount
  ) VALUES (
    v_event_id, p_group_id, p_client_id, p_event_date, p_event_time, p_address, p_notes, p_break_type,
    p_total_price, p_base_price, 'pending_payment', p_payment_mode, v_flow_version,
    p_installment_plan, p_installment_months, p_installment_monthly_amount
  ) RETURNING id INTO v_reservation_id;
  RETURN jsonb_build_object('reservation_id', v_reservation_id, 'event_id', v_event_id);
END;
$function$;

ALTER TABLE public.reservations DROP CONSTRAINT IF EXISTS reservations_event_id_fkey;

-- quotes.event_id NO se elimina por defecto: si sql/585 ya estuvo vivo en
-- producción, esa columna puede tener datos reales de vinculación evento↔
-- cotización. Borrarla es destructivo e irreversible. Descomentar la
-- siguiente línea SOLO si se confirma que no hay datos que perder:
-- ALTER TABLE public.quotes DROP COLUMN IF EXISTS event_id;

COMMIT;

SELECT '585_shared_event_id_ROLLBACK ✅' AS status;
