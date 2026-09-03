-- ============================================================
-- 556_max_3_groups_per_event.sql
--
-- PROPÓSITO
--   Imponer un máximo de 3 grupos distintos contratados para el
--   mismo evento (cliente + fecha + dirección), a prueba de bypass
--   desde el frontend y de condiciones de carrera.
--
-- DEFINICIÓN DE "MISMO EVENTO" (confirmada por el usuario)
--   (client_id, event_date, lower(trim(address))). reservations.event_id
--   NO sirve para esto: create_booking_with_event inserta una fila
--   NUEVA en public.events en CADA llamada — event_id es 1:1 con la
--   reserva, no un identificador compartido entre reservas del mismo
--   evento real. Sin geolocalización por ahora (decisión explícita).
--
-- MECANISMO
--   1. Trigger BEFORE INSERT OR UPDATE OF status ON public.reservations
--      (enforce_max_groups_per_event) — AUTORIDAD REAL. Cubre TODAS las
--      rutas que insertan en reservations, incluida la inserción directa
--      desde el cliente en QuotePaymentScreen.tsx (sin RPC, sin ningún
--      otro control de servidor) y cualquier ruta futura.
--   2. Pre-check amistoso dentro de create_booking_with_event — mismo
--      criterio, pero retorna jsonb {ok:false, error:'event_group_limit_reached'}
--      en vez de dejar que el trigger lance la excepción cruda. El
--      trigger sigue siendo la autoridad real (protege incluso si este
--      pre-check tuviera un bug).
--
-- QUÉ CUENTA HACIA EL LÍMITE (canceladas/rechazadas/completadas)
--   Se reutiliza estados_que_ocupan() — la misma función que ya usa
--   enforce_group_availability()/excl_group_busy_range para decidir
--   qué reservas "ocupan" un slot: pending, pending_payment,
--   pending_group_confirmation, accepted, confirmed, in_progress (+live).
--   rejected/cancelled/completed/expired quedan excluidas automáticamente
--   — cancelar uno de los 3 grupos libera un lugar sin lógica adicional.
--   Se cuenta COUNT(DISTINCT group_id), no COUNT(*) de filas: volver a
--   reservar el mismo grupo nunca cuenta como un "4º grupo".
--
-- INSERT + UPDATE OF status (confirmado por el usuario)
--   El trigger solo evalúa el límite cuando NEW.status pasa a ser
--   "ocupante" Y no lo era ya antes (INSERT con estado ocupante, o
--   UPDATE que reactiva una reserva rechazada/cancelada) — así una
--   reserva ya contada no se vuelve a evaluar en cada UPDATE posterior
--   (ej. pending_payment → confirmed), y liberar un lugar (confirmed →
--   cancelled) nunca se bloquea.
--
-- CONCURRENCIA
--   pg_advisory_xact_lock(hashtext(client_id || event_date || address
--   normalizada)) ANTES de contar — mismo patrón ya usado en
--   create_booking_with_event para group_id+event_date (protege doble-
--   reserva del mismo grupo). Serializa dos contrataciones simultáneas
--   para el mismo cliente+fecha+dirección: la segunda transacción espera
--   a que la primera termine antes de leer el conteo, así nunca pueden
--   "verse" ambas con 2 grupos existentes y colarse las dos como el 3º.
--   Es reentrante dentro de la misma transacción (el pre-check del RPC y
--   el trigger, en la misma llamada, no se bloquean entre sí).
--
-- MENSAJE (confirmado por el usuario)
--   'event_group_limit_reached: Ya hay 3 grupos contratados para este evento.'
--   — mismo texto tanto en el jsonb del pre-check como en la excepción
--   del trigger, para que el frontend lo detecte en ambos casos
--   (bookingResult.error o error.message, según la ruta).
--
-- ALCANCE
--   Solo agrega: 1 función trigger nueva + 1 trigger nuevo sobre
--   reservations + 1 pre-check dentro de create_booking_with_event.
--   No modifica estados_que_ocupan(), enforce_group_availability(),
--   excl_group_busy_range, ni ninguna función de wallets/pagos.
--
-- SEGURIDAD: PRE-CHECK DE VERSIÓN (para create_booking_with_event)
--   Igual que sql/550-554: se verifica el md5() del código fuente
--   desplegado contra el auditado antes de reemplazar. Si no coincide,
--   aborta completo sin tocar nada. El trigger es nuevo (no reemplaza
--   nada existente) — se verifica en su lugar que aún no exista.
--
-- NO EJECUTAR hasta autorización explícita. Este archivo se entrega
-- primero para revisión.
-- ============================================================

BEGIN;

-- ── Pre-check: create_booking_with_event debe ser EXACTAMENTE la auditada,
-- y el trigger nuevo no debe existir ya ──────────────────────────────────
DO $$
DECLARE
  v_current_hash  TEXT;
  v_expected_hash CONSTANT TEXT := '1c8453f725b75acd0b41509be42ed3ec';
BEGIN
  SELECT md5(prosrc) INTO v_current_hash
  FROM   pg_proc p
  JOIN   pg_namespace n ON n.oid = p.pronamespace
  WHERE  n.nspname = 'public' AND p.proname = 'create_booking_with_event';

  IF v_current_hash IS NULL THEN
    RAISE EXCEPTION 'ABORT: create_booking_with_event no existe en esta base';
  END IF;

  IF v_current_hash <> v_expected_hash THEN
    RAISE EXCEPTION 'ABORT: la definición actual de create_booking_with_event (md5=%) no coincide con la auditada (md5=%). Revisar manualmente antes de reemplazarla.',
      v_current_hash, v_expected_hash;
  END IF;

  IF EXISTS (
    SELECT 1 FROM pg_trigger
    WHERE tgname = 'trg_enforce_max_groups_per_event'
      AND tgrelid = 'public.reservations'::regclass
  ) THEN
    RAISE EXCEPTION 'ABORT: el trigger trg_enforce_max_groups_per_event ya existe — no se debe recrear a ciegas';
  END IF;

  IF EXISTS (
    SELECT 1 FROM pg_proc WHERE proname = 'enforce_max_groups_per_event' AND pronamespace = 'public'::regnamespace
  ) THEN
    RAISE EXCEPTION 'ABORT: la función enforce_max_groups_per_event ya existe — no se debe reemplazar a ciegas en este archivo';
  END IF;

  RAISE NOTICE 'Pre-check OK: create_booking_with_event sin cambios, trigger/función nuevos aún no existen';
END $$;

-- ── 1. Función trigger (nueva) ──────────────────────────────────────────
CREATE FUNCTION public.enforce_max_groups_per_event()
RETURNS TRIGGER
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

-- ── 2. Trigger (nuevo) ───────────────────────────────────────────────────
CREATE TRIGGER trg_enforce_max_groups_per_event
BEFORE INSERT OR UPDATE OF status ON public.reservations
FOR EACH ROW
EXECUTE FUNCTION public.enforce_max_groups_per_event();

-- ── 3. Pre-check amistoso dentro de create_booking_with_event ───────────
-- Reemplazo completo, sin abreviar. Único cambio: el bloque nuevo entre
-- el chequeo de date_blocked y la asignación de v_flow_version.
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
  p_payment_mode text DEFAULT 'full'::text
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

  -- Límite de 3 grupos por evento (sql/556): pre-check amistoso — devuelve
  -- JSON limpio en vez de dejar que el trigger enforce_max_groups_per_event
  -- lance la excepción cruda más abajo. El trigger sigue siendo la
  -- autoridad real (protege incluso si este pre-check tuviera un bug, y
  -- cubre además la ruta de inserción directa de QuotePaymentScreen.tsx,
  -- que no pasa por este RPC).
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
  INSERT INTO public.events (client_id, event_date, event_time, address, status)
  VALUES (p_client_id, p_event_date, p_event_time, p_address, 'active')
  RETURNING id INTO v_event_id;
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
  RAISE NOTICE '[CREATE_BOOKING] reservation=% mode=% msi=%',
    v_reservation_id, p_payment_mode, COALESCE(p_installment_plan, '1_pago');
  RETURN jsonb_build_object(
    'reservation_id', v_reservation_id,
    'event_id',       v_event_id
  );
END;
$function$;

COMMIT;

-- ============================================================
-- VERIFICACIÓN POST-FIX (ejecutar por separado después del COMMIT,
-- NO se auto-ejecuta — todo lo siguiente está comentado)
-- ============================================================

-- V1: trigger y función existen, con la definición esperada
-- SELECT tgname, tgtype, pg_get_triggerdef(oid) FROM pg_trigger
-- WHERE tgname = 'trg_enforce_max_groups_per_event' AND tgrelid = 'public.reservations'::regclass;
-- Esperado: BEFORE INSERT OR UPDATE OF status

-- V2: create_booking_with_event incluye el pre-check nuevo
-- SELECT prosrc ILIKE '%event_group_limit_reached%' FROM pg_proc
-- WHERE proname='create_booking_with_event' AND pronamespace='public'::regnamespace;
-- Esperado: true

-- V3: funciones/triggers hermanos sin cambios (enforce_group_availability,
-- excl_group_busy_range, estados_que_ocupan) — comparar hash si se auditó antes
-- SELECT proname, md5(prosrc) FROM pg_proc
-- WHERE proname IN ('estados_que_ocupan','enforce_group_availability')
--   AND pronamespace='public'::regnamespace;

-- V4: QA funcional en vivo (fuera de este archivo, requiere autorización
-- aparte, mismo protocolo de IDs QA sintéticos ya usado en sql/553/555):
-- crear 3 reservas activas para el mismo (client_id, event_date, address)
-- con 3 grupos distintos, confirmar que un 4º grupo es rechazado con
-- event_group_limit_reached, que cancelar una de las 3 libera el lugar
-- para un reemplazo, y que dos intentos concurrentes de "4º grupo" no
-- logran colarse ambos.

SELECT '556_max_3_groups_per_event preparado — NO EJECUTADO' AS status;
