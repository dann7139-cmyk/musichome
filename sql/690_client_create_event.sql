-- ═══════════════════════════════════════════════════════════════════════════
-- sql/690 — Fase 2 "Arma tu fiesta": creación atómica del evento
-- ═══════════════════════════════════════════════════════════════════════════
--
-- ADITIVO. Una sola RPC nueva. NO toca ninguna tabla ni función existente.
--
-- POR QUÉ EXISTE. Hoy la app crea eventos con un INSERT directo a `events`
-- (QuoteFormScreen, permitido por la política RLS events_client_insert) y luego,
-- si hace falta, llama a client_update_event_details() para los campos de
-- Fase 1. Para "Arma tu fiesta" eso serían DOS viajes: si el segundo falla, el
-- cliente queda con un evento a medias (sin nombre, sin invitados, sin
-- presupuesto) que además ya aparece en su lista. Esta función lo hace en una
-- sola transacción.
--
-- QUÉ NO HACE (a propósito):
--   · No crea reservaciones ni cotizaciones.
--   · No cobra nada, no toca wallets, payouts, retiros, comisiones ni Stripe/
--     Conekta/MSI.
--   · No toca proveedores ni `groups`.
--   · No escribe events.total_price / payment_status / payment_intent_id —
--     events sigue SIN ser fuente financiera.
--   · No reemplaza resolve_shared_event_id(): esa sigue siendo el único punto
--     de verdad para "reusar vs crear" durante una contratación. Esta se usa
--     solo cuando el cliente arranca un evento desde cero.
--
-- VALIDACIÓN DE FECHA — decisión deliberada: NO se rechaza una fecha pasada.
-- `CURRENT_DATE` en Postgres es UTC y va adelantado respecto a México, así que
-- un candado `event_date >= CURRENT_DATE` rechazaría un evento creado para "hoy"
-- a partir de las ~18:00 hora de México. Ninguna otra ruta del proyecto valida
-- esto en la base, así que aquí tampoco — la app puede sugerirlo en la UI.
--
-- Orden: correr DESPUÉS de sql/689. Probar con sql/691 (autorevertible).
-- ═══════════════════════════════════════════════════════════════════════════

BEGIN;

CREATE OR REPLACE FUNCTION public.client_create_event(
  p_event_date      DATE,
  p_event_time      TEXT,
  p_address         TEXT,
  p_name            TEXT    DEFAULT NULL,
  p_event_type      TEXT    DEFAULT NULL,
  p_municipio       TEXT    DEFAULT NULL,
  p_estado          TEXT    DEFAULT NULL,
  p_guest_count     INTEGER DEFAULT NULL,
  p_budget_max      NUMERIC DEFAULT NULL,
  p_budget_currency TEXT    DEFAULT NULL,
  p_end_time        TEXT    DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_uid        UUID;
  v_name       TEXT;
  v_type       TEXT;
  v_address    TEXT;
  v_muni       TEXT;
  v_estado     TEXT;
  v_time       TIME;
  v_end_time   TIME;
  v_currency   TEXT;
  v_event_id   UUID;
  v_reused     BOOLEAN := false;
BEGIN
  v_uid := auth.uid();
  IF v_uid IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_authenticated');
  END IF;

  -- ── Normalización ────────────────────────────────────────────────────────
  v_name    := NULLIF(TRIM(COALESCE(p_name, '')), '');
  v_type    := NULLIF(TRIM(COALESCE(p_event_type, '')), '');
  v_address := NULLIF(TRIM(COALESCE(p_address, '')), '');
  v_muni    := NULLIF(TRIM(COALESCE(p_municipio, '')), '');
  v_estado  := NULLIF(TRIM(COALESCE(p_estado, '')), '');

  -- ── Obligatorios (son NOT NULL en public.events) ─────────────────────────
  IF p_event_date IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'missing_event_date');
  END IF;
  IF v_address IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'missing_address');
  END IF;

  -- "HH:MM" desde la app (mismo formato que produce TimePickerModal). Se acepta
  -- TEXT y no TIME para que una cadena mal formada dé un error traducible en
  -- vez de que PostgREST reviente antes de entrar a la función.
  BEGIN
    v_time := NULLIF(TRIM(COALESCE(p_event_time, '')), '')::TIME;
  EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_event_time');
  END;
  IF v_time IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'missing_event_time');
  END IF;

  BEGIN
    v_end_time := NULLIF(TRIM(COALESCE(p_end_time, '')), '')::TIME;
  EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_end_time');
  END;

  -- ── Validaciones de contenido (mismo vocabulario que Fase 1, sql/685) ────
  IF v_type IS NOT NULL AND NOT (v_type = ANY (ARRAY[
       'fiesta_privada','boda','cumpleanos','graduacion','empresarial','otro'])) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_event_type');
  END IF;
  IF p_guest_count IS NOT NULL AND p_guest_count <= 0 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_guest_count');
  END IF;
  IF p_budget_max IS NOT NULL AND p_budget_max < 0 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_budget');
  END IF;

  -- ── Moneda del presupuesto ───────────────────────────────────────────────
  -- Idéntico criterio que client_update_event_details (sql/685): la que manda
  -- la app, o la del país del cliente, o MXN. Solo importa si hay monto.
  -- profiles.country es texto libre y countries tiene filas duplicadas por país
  -- (México ×2, España ×2), de ahí el LIMIT 1.
  IF p_budget_max IS NULL THEN
    v_currency := NULL;
  ELSE
    v_currency := NULLIF(UPPER(TRIM(COALESCE(p_budget_currency, ''))), '');
    IF v_currency IS NULL OR v_currency !~ '^[A-Z]{3}$' THEN
      SELECT c.currency_code INTO v_currency
      FROM public.profiles p
      JOIN public.countries c ON LOWER(TRIM(c.name)) = LOWER(TRIM(p.country))
      WHERE p.id = v_uid
      LIMIT 1;
      v_currency := COALESCE(v_currency, 'MXN');
    END IF;
  END IF;

  -- ── Guarda contra duplicados por doble toque ─────────────────────────────
  -- Si el cliente ya tiene un evento en la MISMA fecha y dirección que todavía
  -- está VACÍO (cero cotizaciones y cero reservas), se reutiliza esa fila en vez
  -- de crear otra cáscara vacía. Un evento que ya tenga proveedores NUNCA se
  -- reutiliza aquí — para eso existe resolve_shared_event_id(), que además
  -- aplica el límite de proveedores. El advisory lock serializa dos toques
  -- simultáneos del mismo cliente.
  PERFORM pg_advisory_xact_lock(hashtext('create_event:' || v_uid::text || p_event_date::text || lower(v_address)));

  SELECT e.id INTO v_event_id
  FROM public.events e
  WHERE e.client_id = v_uid
    AND e.event_date = p_event_date
    AND lower(trim(e.address)) = lower(v_address)
    AND NOT EXISTS (SELECT 1 FROM public.reservations r WHERE r.event_id = e.id)
    AND NOT EXISTS (SELECT 1 FROM public.quotes q      WHERE q.event_id = e.id)
  ORDER BY e.created_at DESC
  LIMIT 1;

  IF v_event_id IS NOT NULL THEN
    v_reused := true;
    UPDATE public.events SET
      event_time      = v_time,
      name            = v_name,
      event_type      = v_type,
      guest_count     = p_guest_count,
      budget_max      = p_budget_max,
      budget_currency = v_currency,
      end_time        = v_end_time,
      event_municipio = v_muni,
      event_estado    = v_estado
    WHERE id = v_event_id;
  ELSE
    INSERT INTO public.events (
      client_id, event_date, event_time, address, status,
      name, event_type, guest_count, budget_max, budget_currency,
      end_time, event_municipio, event_estado
    ) VALUES (
      v_uid, p_event_date, v_time, v_address, 'active',
      v_name, v_type, p_guest_count, p_budget_max, v_currency,
      v_end_time, v_muni, v_estado
    )
    RETURNING id INTO v_event_id;
  END IF;

  RETURN jsonb_build_object(
    'ok',              true,
    'event_id',        v_event_id,
    'reused',          v_reused,
    'event_date',      p_event_date,
    'event_time',      v_time,
    'address',         v_address,
    'name',            v_name,
    'event_type',      v_type,
    'guest_count',     p_guest_count,
    'budget_max',      p_budget_max,
    'budget_currency', v_currency,
    'end_time',        v_end_time,
    'event_municipio', v_muni,
    'event_estado',    v_estado
  );
END;
$function$;

-- Lección de sql/591: Postgres otorga EXECUTE a PUBLIC por default en cada
-- CREATE FUNCTION. Esta RPC escribe como dueño (SECURITY DEFINER) y toma el
-- client_id de auth.uid(), nunca de un parámetro — así no hay suplantación
-- posible. Igual se deja el REVOKE explícito.
REVOKE EXECUTE ON FUNCTION public.client_create_event(DATE, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, INTEGER, NUMERIC, TEXT, TEXT) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.client_create_event(DATE, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, INTEGER, NUMERIC, TEXT, TEXT) TO authenticated, service_role;

COMMENT ON FUNCTION public.client_create_event(DATE, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, INTEGER, NUMERIC, TEXT, TEXT) IS
  'sql/690 (Fase 2, "Arma tu fiesta") — crea el evento del cliente completo en una sola transacción. client_id SIEMPRE de auth.uid(). No crea reservas ni cotizaciones, no cobra, no toca wallets ni proveedores, y no escribe events.total_price. Reutiliza un evento propio de la misma fecha+dirección solo si está VACÍO (0 cotizaciones y 0 reservas), para que un doble toque no deje cáscaras duplicadas.';

-- Refresca el caché de esquema de PostgREST: sin esto la app puede recibir
-- PGRST202 ("función no encontrada") aunque ya exista. Mismo paso que hizo
-- falta en sql/585 y sql/685.
NOTIFY pgrst, 'reload schema';

COMMIT;
