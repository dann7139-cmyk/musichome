-- ═══════════════════════════════════════════════════════════════════════════
-- ROLLBACK de sql/686 — SOLO en caso de reversión deliberada
-- ═══════════════════════════════════════════════════════════════════════════
--
-- Restaura las 4 capas del límite de proveedores EXACTAMENTE a como estaban en
-- producción antes de sql/686 (capturadas vía pg_get_functiondef contra
-- sqgzyipqpewzbnfrtdqk el 2026-09-25, antes de aplicar el parche) — es decir,
-- vuelve a dejar el límite duro de 3 proveedores por evento en las 4.
--
-- Nada de tablas, datos, triggers (definición), constraints ni ACL se toca: las
-- 4 son CREATE OR REPLACE con la firma idéntica, y los triggers
-- trg_enforce_max_groups_per_event / trg_enforce_max_groups_per_shared_event
-- siguen apuntando a las mismas funciones.
--
-- OJO: si ya hay eventos reales con MÁS de 3 proveedores cuando se corra esto,
-- esas reservas NO se borran ni se invalidan (los candados solo se evalúan al
-- insertar o al reactivar una reserva) — pero el evento ya no podrá aceptar uno
-- más, y cualquier UPDATE que reactive una reserva desde un estado inactivo
-- fallará con event_group_limit_reached. Revisar antes:
--   SELECT event_id, COUNT(DISTINCT group_id) AS proveedores
--     FROM public.reservations
--    WHERE event_id IS NOT NULL AND status = ANY (public.estados_que_ocupan())
--    GROUP BY event_id HAVING COUNT(DISTINCT group_id) > 3;
--
-- Después de correr esto, el lado app queda inconsistente a propósito
-- (eventBuilder.ts seguiría ofreciendo cupo hasta 20 si sql/685 sigue vivo,
-- porque client_get_my_events() manda provider_limit = 20): revertir también el
-- commit de la app, o correr además 685_ROLLBACK.
-- ═══════════════════════════════════════════════════════════════════════════

BEGIN;

CREATE OR REPLACE FUNCTION public.enforce_max_groups_per_event()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
DECLARE
  v_norm_address    TEXT;
  v_distinct_groups INT;
BEGIN
  -- Si el nuevo estado no ocupa un lugar, no hay nada que limitar.
  IF NOT (NEW.status = ANY (public.estados_que_ocupan())) THEN
    RETURN NEW;
  END IF;

  -- Si ya ocupaba antes (UPDATE que no reactiva desde un estado inactivo),
  -- no es una "nueva ocupación" — no se vuelve a evaluar en cada UPDATE
  -- posterior (ej. pending_payment → confirmed).
  IF TG_OP = 'UPDATE' AND (OLD.status = ANY (public.estados_que_ocupan())) THEN
    RETURN NEW;
  END IF;

  IF NEW.client_id IS NULL OR NEW.event_date IS NULL OR NEW.address IS NULL THEN
    RETURN NEW;
  END IF;

  v_norm_address := lower(trim(NEW.address));

  -- Serializa contrataciones simultáneas para el mismo cliente+fecha+dirección.
  PERFORM pg_advisory_xact_lock(
    hashtext(NEW.client_id::text || NEW.event_date::text || v_norm_address)
  );

  SELECT COUNT(DISTINCT group_id) INTO v_distinct_groups
  FROM public.reservations
  WHERE client_id = NEW.client_id
    AND event_date = NEW.event_date
    AND lower(trim(address)) = v_norm_address
    AND status = ANY (public.estados_que_ocupan())
    AND group_id <> NEW.group_id
    AND id <> NEW.id;

  IF v_distinct_groups >= 3 THEN
    RAISE EXCEPTION 'event_group_limit_reached: Ya hay 3 grupos contratados para este evento.';
  END IF;

  RETURN NEW;
END;
$function$;

CREATE OR REPLACE FUNCTION public.enforce_max_groups_per_shared_event()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
DECLARE
  v_distinct_groups INT;
BEGIN
  IF NEW.event_id IS NULL THEN
    RETURN NEW;
  END IF;
  IF NOT (NEW.status = ANY (public.estados_que_ocupan())) THEN
    RETURN NEW;
  END IF;
  IF TG_OP = 'UPDATE' AND (OLD.status = ANY (public.estados_que_ocupan())) AND OLD.event_id IS NOT DISTINCT FROM NEW.event_id THEN
    RETURN NEW;
  END IF;

  PERFORM pg_advisory_xact_lock(hashtext('shared_event:' || NEW.event_id::text));

  SELECT COUNT(DISTINCT group_id) INTO v_distinct_groups
  FROM public.reservations
  WHERE event_id = NEW.event_id
    AND status = ANY (public.estados_que_ocupan())
    AND group_id <> NEW.group_id
    AND id <> NEW.id;

  IF v_distinct_groups >= 3 THEN
    RAISE EXCEPTION 'event_group_limit_reached: Ya hay 3 proveedores contratados para este evento.';
  END IF;

  RETURN NEW;
END;
$function$;

CREATE OR REPLACE FUNCTION public.resolve_shared_event_id(p_client_id uuid, p_event_id uuid, p_event_date date, p_event_time time without time zone, p_address text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_event RECORD;
  v_new_id UUID;
BEGIN
  IF p_event_id IS NOT NULL THEN
    SELECT * INTO v_event FROM public.events WHERE id = p_event_id;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'event_not_found: %', p_event_id;
    END IF;
    IF v_event.client_id <> p_client_id THEN
      RAISE EXCEPTION 'event_not_owned_by_client';
    END IF;
    IF (SELECT COUNT(DISTINCT group_id) FROM public.reservations
        WHERE event_id = p_event_id AND status = ANY (public.estados_que_ocupan())) >= 3 THEN
      RAISE EXCEPTION 'event_group_limit_reached: Ya hay 3 proveedores contratados para este evento.';
    END IF;
    RETURN p_event_id;
  END IF;

  INSERT INTO public.events (client_id, event_date, event_time, address, status)
  VALUES (p_client_id, p_event_date, p_event_time, p_address, 'active')
  RETURNING id INTO v_new_id;
  RETURN v_new_id;
END;
$function$;

CREATE OR REPLACE FUNCTION public.create_booking_with_event(p_client_id uuid, p_group_id uuid, p_package_id uuid, p_event_date date, p_event_time time without time zone, p_address text, p_total_price numeric, p_notes text DEFAULT NULL::text, p_break_type text DEFAULT NULL::text, p_base_price numeric DEFAULT NULL::numeric, p_installment_plan text DEFAULT NULL::text, p_installment_months integer DEFAULT NULL::integer, p_installment_monthly_amount numeric DEFAULT NULL::numeric, p_payment_mode text DEFAULT 'full'::text, p_event_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
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

-- Se borra al final, cuando ya nadie la referencia. Si sql/685 sigue aplicado,
-- client_get_my_events() la busca con to_regproc y cae a 3 sola — no falla.
DROP FUNCTION IF EXISTS public.max_providers_per_event();

COMMIT;
