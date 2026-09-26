-- ═══════════════════════════════════════════════════════════════════════════
-- sql/686 — Límite de proveedores por evento: 3 → 20, con UNA fuente de verdad
-- ═══════════════════════════════════════════════════════════════════════════
--
-- CONTEXTO REAL (revisado contra producción antes de escribir esto).
-- El límite de "3 proveedores por evento" NO vivía en un lugar: vivía en 4
-- lugares distintos en la base, más 1 en la app:
--
--   L1  enforce_max_groups_per_event()          trigger en reservations,
--       (sql/556)                               llave = client_id + event_date
--                                               + lower(trim(address))
--   L2  enforce_max_groups_per_shared_event()   trigger en reservations,
--       (sql/585)                               llave = event_id
--   L3  resolve_shared_event_id()               pre-chequeo, llave = event_id
--       (sql/585)
--   L4  create_booking_with_event()             pre-chequeo, llave = cliente
--       (sql/556)                               + fecha + dirección
--   L5  src/utils/eventBuilder.ts               filtro de la app (fuera de
--                                               este archivo)
--
-- POR QUÉ EXISTEN (no son redundancia accidental, y por eso NO se borran):
--   · L1 nació ANTES de que existiera events.event_id — es la misma regla de
--     negocio expresada sobre texto de dirección. Sigue siendo la ÚNICA capa
--     que cubre reservas SIN event_id (express/legacy), que L2 no puede ver.
--   · L2 es la misma regla sobre el concepto nuevo (event_id compartido).
--     sql/585 las dejó conviviendo a propósito.
--   · L3 y L4 son pre-chequeos: existen para que el cliente reciba
--     'event_group_limit_reached' como jsonb limpio y traducido, en vez de una
--     excepción cruda del trigger a media transacción.
--   Ninguna de las 4 es una restricción técnica — es regla de producto. Por
--   eso la corrección segura es subir el número en las 4 A LA VEZ, no quitar
--   capas: si se quita una, se pierde cobertura real; si se sube en solo
--   algunas, la capa olvidada sigue rechazando al 4º proveedor.
--
-- QUÉ CAMBIA AQUÍ: el número, y nada más. Las 4 capas siguen existiendo, con
-- la misma llave, el mismo advisory lock, el mismo COUNT(DISTINCT group_id),
-- el mismo código de error 'event_group_limit_reached' (la app ya lo traduce
-- en 3 pantallas y no se toca) y el mismo comportamiento en UPDATE. Lo único
-- distinto es que el 3 literal se reemplaza por max_providers_per_event().
--
-- QUÉ NO CAMBIA:
--   · Varios proveedores de la MISMA categoría ya estaban permitidos: las 4
--     capas cuentan COUNT(DISTINCT group_id) y ninguna mira género/categoría.
--     No hacía falta cambiar nada para eso (verificado también en la app:
--     EventCategoryPickerScreen no filtra categorías ya usadas).
--   · El umbral >= 2 de admin_get_events_needing_review() NO es un límite, es
--     la señal de "evento multi-grupo que el admin debe revisar". Se deja.
--   · Cada reserva sigue siendo independiente: un event_id compartido no une
--     pagos, wallets, comisiones ni retiros. Aquí no se toca ninguno.
--   · Nada de horas extra, cancelaciones, Stripe ni Conekta.
--
-- Orden: correr DESPUÉS de sql/685.
-- ═══════════════════════════════════════════════════════════════════════════

BEGIN;

-- ── 0. Fuente de verdad única ───────────────────────────────────────────────
-- 20 es un límite general razonable para una fiesta real (mariachi + grupo +
-- DJ + comida + fotografía + decoración + brincolín + casino + ... ). No hay
-- ninguna razón técnica para un número más bajo: las 4 capas hacen un
-- COUNT(DISTINCT group_id) sobre reservations serializado por advisory lock, y
-- client_get_my_events() agrega los proveedores con subconsultas correlacionadas
-- — ambos son O(proveedores del evento), irrelevante en 20.
--
-- OJO CON EL ACL: los dos triggers (L1, L2) son SECURITY INVOKER — corren como
-- el rol que inserta la reserva, es decir 'authenticated'. Si a esta función se
-- le revoca EXECUTE a authenticated, TODA inserción de reserva falla con
-- permission denied. Por eso se deja con los grants default de Postgres, igual
-- que estados_que_ocupan(), a la que estos mismos triggers ya llaman (ACL real
-- verificado: {=X/postgres,anon=X,authenticated=X,service_role=X}). No es fuga
-- de información: devuelve una constante.
CREATE OR REPLACE FUNCTION public.max_providers_per_event()
RETURNS integer
LANGUAGE sql
IMMUTABLE
AS $function$ SELECT 20 $function$;

COMMENT ON FUNCTION public.max_providers_per_event() IS
  'sql/686 — máximo de proveedores (grupos distintos) por evento. Única fuente de verdad: la leen los 2 triggers, resolve_shared_event_id(), create_booking_with_event() y client_get_my_events() (que la manda a la app). Para cambiar el límite se cambia SOLO aquí. No revocarle EXECUTE a authenticated: los triggers son SECURITY INVOKER.';

-- ── L1. Trigger legacy por cliente+fecha+dirección (sql/556) ────────────────
-- Copia exacta de la versión viva, con el 3 → max_providers_per_event().
-- Se conserva porque es la única capa que cubre reservas sin event_id.
CREATE OR REPLACE FUNCTION public.enforce_max_groups_per_event()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
DECLARE
  v_norm_address    TEXT;
  v_distinct_groups INT;
  v_limit           INT := public.max_providers_per_event();
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

  IF v_distinct_groups >= v_limit THEN
    RAISE EXCEPTION 'event_group_limit_reached: el evento ya alcanzó el máximo de % proveedores.', v_limit;
  END IF;

  RETURN NEW;
END;
$function$;

-- ── L2. Trigger por event_id compartido (sql/585) ───────────────────────────
CREATE OR REPLACE FUNCTION public.enforce_max_groups_per_shared_event()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
DECLARE
  v_distinct_groups INT;
  v_limit           INT := public.max_providers_per_event();
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

  IF v_distinct_groups >= v_limit THEN
    RAISE EXCEPTION 'event_group_limit_reached: el evento ya alcanzó el máximo de % proveedores.', v_limit;
  END IF;

  RETURN NEW;
END;
$function$;

-- ── L3. Pre-chequeo al reusar un evento existente (sql/585) ─────────────────
-- Firma idéntica (5 parámetros, mismos tipos y orden) — CREATE OR REPLACE
-- reemplaza de verdad, no crea overload. Tampoco se le agrega verificación de
-- auth.uid(): sigue protegida indirectamente por create_booking_with_event()
-- (sql/592) y client_accept_quote(), tal como quedó documentado. Cambiar eso
-- aquí sería un cambio de seguridad ajeno a esta fase.
CREATE OR REPLACE FUNCTION public.resolve_shared_event_id(p_client_id uuid, p_event_id uuid, p_event_date date, p_event_time time without time zone, p_address text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_event RECORD;
  v_new_id UUID;
  v_limit INT := public.max_providers_per_event();
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
        WHERE event_id = p_event_id AND status = ANY (public.estados_que_ocupan())) >= v_limit THEN
      RAISE EXCEPTION 'event_group_limit_reached: el evento ya alcanzó el máximo de % proveedores.', v_limit;
    END IF;
    RETURN p_event_id;
  END IF;

  INSERT INTO public.events (client_id, event_date, event_time, address, status)
  VALUES (p_client_id, p_event_date, p_event_time, p_address, 'active')
  RETURNING id INTO v_new_id;
  RETURN v_new_id;
END;
$function$;

-- ── L4. Pre-chequeo al crear reserva desde BookingScreen (sql/556/592) ──────
-- Copia exacta de la versión viva (15 parámetros, incluido el candado de
-- suplantación de sql/592 y el package_id de sql/525). ÚNICO cambio: el 3 →
-- v_limit. No se toca precio, comisión, moneda, referidos, break_type,
-- flow_version, MSI ni el INSERT.
CREATE OR REPLACE FUNCTION public.create_booking_with_event(p_client_id uuid, p_group_id uuid, p_package_id uuid, p_event_date date, p_event_time time without time zone, p_address text, p_total_price numeric, p_notes text DEFAULT NULL::text, p_break_type text DEFAULT NULL::text, p_base_price numeric DEFAULT NULL::numeric, p_installment_plan text DEFAULT NULL::text, p_installment_months integer DEFAULT NULL::integer, p_installment_monthly_amount numeric DEFAULT NULL::numeric, p_payment_mode text DEFAULT 'full'::text, p_event_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_event_id UUID; v_reservation_id UUID; v_flow_version TEXT; v_distinct_groups INT;
  v_currency TEXT; v_final_total NUMERIC; v_break_type TEXT;
  v_limit INT := public.max_providers_per_event();
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
  IF v_distinct_groups >= v_limit THEN RETURN jsonb_build_object('ok', false, 'error', 'event_group_limit_reached'); END IF;
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

COMMIT;

-- ── Verificación manual sugerida después de aplicar ─────────────────────────
-- SELECT public.max_providers_per_event();                      -- → 20
-- SELECT p.proname FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
--   WHERE n.nspname = 'public' AND p.prosrc LIKE '%>= 3%'
--     AND p.proname IN ('enforce_max_groups_per_event','enforce_max_groups_per_shared_event',
--                       'resolve_shared_event_id','create_booking_with_event');  -- → 0 filas
-- SELECT count(*) FROM pg_proc WHERE proname = 'create_booking_with_event';       -- → 1 (sin overload)
-- SELECT count(*) FROM pg_proc WHERE proname = 'resolve_shared_event_id';         -- → 1 (sin overload)
