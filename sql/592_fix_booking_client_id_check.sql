-- ============================================================
-- sql/592_fix_booking_client_id_check.sql
-- ✅ APLICADO A PRODUCCIÓN 2026-09-01 con autorización explícita del
-- usuario. Probado en transacción autorevertible: intento de suplantación
-- rechazado limpio (sin crear nada), reserva legítima funciona idéntico
-- a como funcionaba antes, sin sesión también rechazado. Confirmado por
-- REST después del deploy (HTTP 200, {"ok":false,"error":"not_owner"}).
--
-- HALLAZGO DE SEGURIDAD REAL (encontrado 2026-09-01 revisando el área
-- tocada por sql/585, NO introducido por sql/585 — es preexistente).
--
--   create_booking_with_event() recibe p_client_id como parámetro que el
--   que llama controla, y JAMÁS lo compara contra auth.uid(). Como es
--   SECURITY DEFINER, se salta por completo el RLS de `reservations` en
--   su INSERT interno — el único candado real hoy es que la APP siempre
--   manda sessionData.session.user.id (que sí es el id real y verificado
--   de la sesión). Pero nada en la base impide que alguien llame la RPC
--   directo (curl/Postman) con SU sesión real autenticada, y pase el
--   client_id de OTRA persona como p_client_id — la reserva quedaría
--   creada a nombre de la víctima sin su consentimiento.
--
--   Verificado ANTES de tocar nada: create_booking_with_event tiene UN
--   SOLO llamador en toda la app (BookingScreen.tsx línea 386), y ese
--   único llamador SIEMPRE manda p_client_id = sessionData.session.user.id
--   (el id verificado de la sesión actual — no falsificable desde el
--   cliente). Por eso este candado es 100% seguro de agregar: ningún
--   flujo legítimo cambia de comportamiento, solo se cierra la puerta a
--   una llamada directa con un client_id ajeno.
--
--   client_accept_proposal() NO tiene este problema — ya deriva el dueño
--   de event_requests.client_id comparado contra auth.uid() internamente
--   (confirmado leyendo su código, no se toca).
--
-- CAMBIO REAL: una sola verificación agregada al inicio del cuerpo,
-- mismo patrón/vocabulario de error que ya usa client_accept_proposal
-- ('error': 'not_owner'). Nada más se toca — mismo hash de referencia
-- antes del cambio: md5(prosrc) = '4a18996e61e1156248b947285bf997d6'
-- (verificado 2026-09-01).
-- ============================================================

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
  -- ÚNICO CAMBIO REAL de sql/592: p_client_id debe ser el usuario
  -- autenticado real. Sin esto, cualquiera con su propia sesión podía
  -- pasar el client_id de otra persona y crearle una reserva a su nombre.
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

COMMIT;

SELECT '592_fix_booking_client_id_check — APLICADO A PRODUCCIÓN 2026-09-01' AS status;
