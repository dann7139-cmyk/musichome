-- ═══════════════════════════════════════════════════════════════════════════
-- sql/685 — Fase 1 de "Mi Evento": datos básicos del evento
-- ═══════════════════════════════════════════════════════════════════════════
--
-- ADITIVO Y RETROCOMPATIBLE. Amplía el concepto de Evento que YA existe
-- (public.events, creada en sql/08 y reutilizada como contenedor
-- multi-proveedor en sql/585) con los datos que le faltaban. NO crea un
-- segundo sistema de eventos.
--
-- Qué hace:
--   1. 8 columnas nuevas en public.events, TODAS nullable y sin DEFAULT
--      → los eventos que ya existen en producción siguen abriendo igual,
--        con esos campos vacíos. Ninguna lectura existente los exige.
--   2. CHECK constraints que solo rechazan basura (NULL siempre pasa), con
--      el MISMO vocabulario que ya usa quotes.event_type — no se inventa un
--      dialecto nuevo.
--   3. RPC nueva client_update_event_details() — único punto de escritura de
--      esos 8 campos.
--   4. client_get_my_events() extendida: devuelve los campos nuevos + el
--      límite de proveedores vigente. Se AGREGAN llaves al jsonb; no se quita
--      ni renombra ninguna de las que la app ya lee.
--
-- Qué NO hace (a propósito):
--   · No toca reservations, quotes, pagos, wallets, retiros, comisiones,
--     horas extra, cancelaciones, Stripe ni Conekta.
--   · No borra ni renombra ninguna columna ni tabla.
--   · No convierte events.total_price en fuente de verdad de nada — sigue
--     siendo reservations la fuente de verdad del dinero.
--   · No permite editar event_date / event_time / address. Esos 3 son la
--     identidad del evento que usan los candados de proveedores y viven
--     duplicados en reservations/quotes: cambiarlos solo aquí los
--     desincronizaría. Eso es una fase posterior, no esta.
--
-- Orden: correr DESPUÉS de sql/684 y ANTES de sql/686.
-- ═══════════════════════════════════════════════════════════════════════════

BEGIN;

-- ── 1. Columnas nuevas ──────────────────────────────────────────────────────
-- Nombres elegidos para coincidir con el vocabulario que YA existe en el
-- proyecto, no para inventar uno nuevo:
--   event_type      → mismo nombre y mismos 6 valores que quotes.event_type
--   guest_count     → mismo nombre que event_requests.guest_count
--   budget_max      → mismo nombre que event_requests.budget_max
--   event_municipio → mismo nombre que quotes.event_municipio (= "ciudad"
--   event_estado    → mismo nombre que quotes.event_estado       en la UI)
--   end_time        → hermano de events.event_time (que es la hora de inicio)
ALTER TABLE public.events
  ADD COLUMN IF NOT EXISTS name            TEXT,
  ADD COLUMN IF NOT EXISTS event_type      TEXT,
  ADD COLUMN IF NOT EXISTS guest_count     INTEGER,
  ADD COLUMN IF NOT EXISTS budget_max      NUMERIC,
  ADD COLUMN IF NOT EXISTS budget_currency TEXT,
  ADD COLUMN IF NOT EXISTS end_time        TIME,
  ADD COLUMN IF NOT EXISTS event_municipio TEXT,
  ADD COLUMN IF NOT EXISTS event_estado    TEXT;

-- ── 1b. BUG REAL PREEXISTENTE, encontrado al probar esta fase ───────────────
-- public.events tiene desde siempre el trigger
--     set_updated_at_events BEFORE UPDATE ON public.events
--       FOR EACH ROW EXECUTE FUNCTION set_updated_at()
-- y set_updated_at() hace NEW.updated_at = NOW() ... pero la tabla NUNCA tuvo
-- la columna updated_at. Resultado: CUALQUIER UPDATE sobre public.events
-- fallaba con 42703 'record "new" has no field "updated_at"'. Nunca se notó
-- porque la app solo hacía INSERT en events — la política RLS
-- events_client_update jamás pudo aplicarse a un UPDATE exitoso.
--
-- Se arregla creando la columna que el trigger siempre esperó (y que
-- src/types/models.ts ya declaraba en la interfaz Event). NO se toca
-- set_updated_at(), que es compartida por muchas tablas: cambiarla ahí sí
-- sería un cambio de radio grande y ajeno a esta fase.
--
-- Es obligatorio para Fase 1: sin esto, client_update_event_details() fallaría
-- en TODAS las llamadas. El DEFAULT rellena las filas existentes sin reescribir
-- la tabla (operación de metadatos en PG11+).
ALTER TABLE public.events
  ADD COLUMN IF NOT EXISTS updated_at TIMESTAMPTZ DEFAULT NOW();

COMMENT ON COLUMN public.events.name            IS 'sql/685 — nombre que el cliente le da a su evento ("XV de Sofia"). NULL = evento anterior a Fase 1.';
COMMENT ON COLUMN public.events.event_type      IS 'sql/685 — mismos 6 valores que quotes.event_type.';
COMMENT ON COLUMN public.events.guest_count     IS 'sql/685 — invitados estimados del evento completo (distinto de quotes.num_personas, que es por proveedor).';
COMMENT ON COLUMN public.events.budget_max      IS 'sql/685 — presupuesto declarado por el cliente. INFORMATIVO: no se compara ni se suma contra precios reales, y NO es fuente de verdad de ningun cobro.';
COMMENT ON COLUMN public.events.budget_currency IS 'sql/685 — moneda de budget_max. Existe para no dejar un monto sin moneda (MXN/USD/CAD nunca se suman en este proyecto).';
COMMENT ON COLUMN public.events.end_time        IS 'sql/685 — hora de finalizacion estimada del evento completo. Puede ser menor que event_time (evento que cruza medianoche) — a proposito no hay constraint que lo impida.';
COMMENT ON COLUMN public.events.event_municipio IS 'sql/685 — ciudad/municipio. Mismo nombre y significado que quotes.event_municipio.';
COMMENT ON COLUMN public.events.event_estado    IS 'sql/685 — estado. Mismo nombre y significado que quotes.event_estado.';
COMMENT ON COLUMN public.events.updated_at      IS 'sql/685 — columna que el trigger set_updated_at_events esperaba desde siempre y que nunca existió: sin ella TODO UPDATE sobre events fallaba con 42703. No se lee en ninguna pantalla todavia.';

-- ── 2. CHECK constraints (NULL siempre pasa) ────────────────────────────────
-- ALTER TABLE ... ADD CONSTRAINT no soporta IF NOT EXISTS para CHECK, así que
-- se hace idempotente a mano (el archivo puede re-correrse sin dañar nada).
DO $do$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'events_event_type_check') THEN
    ALTER TABLE public.events ADD CONSTRAINT events_event_type_check
      CHECK (event_type IS NULL OR event_type = ANY (ARRAY[
        'fiesta_privada','boda','cumpleanos','graduacion','empresarial','otro'
      ]));
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'events_guest_count_check') THEN
    ALTER TABLE public.events ADD CONSTRAINT events_guest_count_check
      CHECK (guest_count IS NULL OR guest_count > 0);
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'events_budget_max_check') THEN
    ALTER TABLE public.events ADD CONSTRAINT events_budget_max_check
      CHECK (budget_max IS NULL OR budget_max >= 0);
  END IF;

  -- A propósito NO se limita a MXN/USD/CAD: si un cliente tiene
  -- profiles.country = 'España', la derivación automática daría EUR y un
  -- CHECK cerrado haría fallar el guardado. Solo se exige la forma.
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'events_budget_currency_check') THEN
    ALTER TABLE public.events ADD CONSTRAINT events_budget_currency_check
      CHECK (budget_currency IS NULL OR budget_currency ~ '^[A-Z]{3}$');
  END IF;
END
$do$;

-- ── 3. RPC de escritura ─────────────────────────────────────────────────────
-- SEMÁNTICA: reemplazo COMPLETO de los 8 campos. La pantalla de edición
-- siempre manda el formulario entero, así que "parámetro NULL" significa "el
-- cliente dejó ese campo vacío", no "no lo mandé". Documentado aquí porque es
-- la única forma de que "borrar el presupuesto" funcione.
--
-- Se hace por RPC y no por UPDATE directo (aunque la política RLS
-- events_client_update ya lo permitiría) por 3 razones reales:
--   · normaliza en un solo lugar (trim + NULLIF de cadenas vacías),
--   · nunca puede tocar status/total_price/payment_status/payment_intent_id
--     aunque la app se equivoque,
--   · devuelve el vocabulario de error jsonb {ok,error} que ya usa el resto
--     del proyecto (create_booking_with_event, client_accept_quote).
CREATE OR REPLACE FUNCTION public.client_update_event_details(
  p_event_id        UUID,
  p_name            TEXT    DEFAULT NULL,
  p_event_type      TEXT    DEFAULT NULL,
  p_guest_count     INTEGER DEFAULT NULL,
  p_budget_max      NUMERIC DEFAULT NULL,
  p_budget_currency TEXT    DEFAULT NULL,
  p_end_time        TEXT    DEFAULT NULL,
  p_municipio       TEXT    DEFAULT NULL,
  p_estado          TEXT    DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_event    RECORD;
  v_end_time TIME;
  v_currency TEXT;
  v_name     TEXT;
  v_type     TEXT;
  v_muni     TEXT;
  v_estado   TEXT;
BEGIN
  IF auth.uid() IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_authenticated');
  END IF;

  SELECT * INTO v_event FROM public.events WHERE id = p_event_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'event_not_found');
  END IF;
  IF v_event.client_id <> auth.uid() THEN
    RETURN jsonb_build_object('ok', false, 'error', 'event_not_owned_by_client');
  END IF;

  v_name   := NULLIF(TRIM(COALESCE(p_name, '')), '');
  v_type   := NULLIF(TRIM(COALESCE(p_event_type, '')), '');
  v_muni   := NULLIF(TRIM(COALESCE(p_municipio, '')), '');
  v_estado := NULLIF(TRIM(COALESCE(p_estado, '')), '');

  -- Validaciones con error limpio, antes de que salten los CHECK crudos.
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

  -- "HH:MM" desde la app (mismo formato que produce TimePickerModal). Se
  -- acepta TEXT y no TIME para que una cadena mal formada dé un error
  -- traducible en vez de que PostgREST reviente antes de entrar a la función.
  BEGIN
    v_end_time := NULLIF(TRIM(COALESCE(p_end_time, '')), '')::TIME;
  EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_end_time');
  END;

  -- Moneda del presupuesto: la que manda la app, o la del país del cliente, o
  -- MXN. Solo importa si hay monto — un presupuesto vacío no arrastra moneda.
  -- profiles.country es texto libre y countries tiene filas duplicadas por
  -- país (México ×2, España ×2), de ahí el LIMIT 1.
  IF p_budget_max IS NULL THEN
    v_currency := NULL;
  ELSE
    v_currency := NULLIF(UPPER(TRIM(COALESCE(p_budget_currency, ''))), '');
    IF v_currency IS NULL OR v_currency !~ '^[A-Z]{3}$' THEN
      SELECT c.currency_code INTO v_currency
      FROM public.profiles p
      JOIN public.countries c ON LOWER(TRIM(c.name)) = LOWER(TRIM(p.country))
      WHERE p.id = auth.uid()
      LIMIT 1;
      v_currency := COALESCE(v_currency, 'MXN');
    END IF;
  END IF;

  UPDATE public.events SET
    name            = v_name,
    event_type      = v_type,
    guest_count     = p_guest_count,
    budget_max      = p_budget_max,
    budget_currency = v_currency,
    end_time        = v_end_time,
    event_municipio = v_muni,
    event_estado    = v_estado
  WHERE id = p_event_id;

  RETURN jsonb_build_object(
    'ok',              true,
    'event_id',        p_event_id,
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
-- CREATE FUNCTION. Esta RPC verifica dueño internamente (auth.uid()), así que
-- anon no podría hacer nada con ella — pero se deja explícito de todos modos.
REVOKE EXECUTE ON FUNCTION public.client_update_event_details(UUID, TEXT, TEXT, INTEGER, NUMERIC, TEXT, TEXT, TEXT, TEXT) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.client_update_event_details(UUID, TEXT, TEXT, INTEGER, NUMERIC, TEXT, TEXT, TEXT, TEXT) TO authenticated, service_role;

-- ── 4. client_get_my_events() — mismas llaves de antes + las nuevas ─────────
-- Copia EXACTA de la versión viva en producción (sql/585 v2), con 9 llaves
-- agregadas al objeto de cada evento. Firma idéntica (sin parámetros), así que
-- CREATE OR REPLACE reemplaza de verdad — no crea un overload (la trampa que
-- documentó sql/585). Los ACL se preservan con OR REPLACE.
--
-- provider_limit viaja al cliente para que la app NO tenga que hardcodear el
-- número: eventBuilder.ts lo lee de aquí. Depende de
-- max_providers_per_event(), que crea sql/686 — de ahí el COALESCE con
-- to_regproc: si 685 se aplica y 686 todavía no, esto sigue devolviendo 3
-- (comportamiento actual, sin cambio) en vez de fallar.
CREATE OR REPLACE FUNCTION public.client_get_my_events()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_result jsonb;
  v_limit  INT;
BEGIN
  IF auth.uid() IS NULL THEN RETURN jsonb_build_object('ok', false, 'error', 'not_authenticated'); END IF;

  IF to_regproc('public.max_providers_per_event') IS NULL THEN
    v_limit := 3;
  ELSE
    EXECUTE 'SELECT public.max_providers_per_event()' INTO v_limit;
  END IF;

  SELECT jsonb_build_object('ok', true, 'items', COALESCE(jsonb_agg(x.item ORDER BY x.event_date DESC), '[]'::jsonb))
  INTO v_result
  FROM (
    SELECT e.event_date, jsonb_build_object(
      'event_id', e.id, 'event_date', e.event_date, 'event_time', e.event_time, 'address', e.address,
      -- sql/685 — datos básicos del evento (NULL en eventos anteriores)
      'name', e.name, 'event_type', e.event_type, 'guest_count', e.guest_count,
      'budget_max', e.budget_max, 'budget_currency', e.budget_currency,
      'end_time', e.end_time, 'event_municipio', e.event_municipio, 'event_estado', e.event_estado,
      'provider_limit', v_limit,
      'providers', (
        SELECT COALESCE(jsonb_agg(x2.item ORDER BY x2.created_at), '[]'::jsonb) FROM (
          SELECT r.created_at, jsonb_build_object(
            'reservation_id', r.id, 'group_id', r.group_id, 'group_name', g.name,
            'status', r.status, 'payment_status', r.payment_status, 'total_price', r.total_price,
            'currency_code', r.currency_code
          ) AS item
          FROM public.reservations r JOIN public.groups g ON g.id = r.group_id
          WHERE r.event_id = e.id
          UNION ALL
          SELECT q.created_at, jsonb_build_object(
            'reservation_id', 'quote-' || q.id, 'group_id', q.group_id, 'group_name', g2.name,
            'status', q.status, 'payment_status', NULL, 'total_price', q.total_amount,
            'currency_code', (SELECT c.currency_code FROM public.countries c WHERE c.id = g2.country_id)
          ) AS item
          FROM public.quotes q JOIN public.groups g2 ON g2.id = q.group_id
          WHERE q.event_id = e.id AND q.status IN ('pending', 'quoted')
        ) x2
      )
    ) AS item
    FROM public.events e
    WHERE e.client_id = auth.uid()
  ) x;

  RETURN v_result;
END;
$function$;

-- ── 5. Refrescar el caché de esquema de PostgREST ───────────────────────────
-- Sin esto, la app puede seguir respondiendo PGRST202 ("función no encontrada")
-- al llamar client_update_event_details() y PGRST204 al leer las columnas
-- nuevas, aunque ya existan en la base: PostgREST cachea el esquema. Mismo paso
-- que hizo falta al aplicar sql/585. Se entrega al hacer COMMIT.
NOTIFY pgrst, 'reload schema';

COMMIT;

-- ── Verificación manual sugerida después de aplicar ─────────────────────────
-- SELECT column_name, is_nullable FROM information_schema.columns
--   WHERE table_schema='public' AND table_name='events' ORDER BY ordinal_position;
-- SELECT public.client_get_my_events();   -- como cliente real
