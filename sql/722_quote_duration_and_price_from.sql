-- ═══════════════════════════════════════════════════════════════════════════
-- 722 — ETAPA 3.5: la duración cotizada llega a la reserva, y price_from editable
-- ═══════════════════════════════════════════════════════════════════════════
--
-- ── PARTE 1: EL DEFECTO DE DURACIÓN ───────────────────────────────────────
-- `client_accept_quote` inserta en `reservations` SIN `hours_count`. La columna
-- no tiene default y es nullable, así que queda NULL, y el trigger
-- `trg_01_set_busy_range` → `set_reservation_busy_range` → `make_busy_range`
-- hace `GREATEST(COALESCE(p_hours, 3), 1)`.
-- Resultado real: una cotización de 10 h generaba una reserva que solo apartaba
-- 3 h + 30 min antes + 45 min después en el calendario, así que `can_schedule`
-- dejaba contratar al mismo proveedor encima de su propio evento.
--
-- Se corrige EN EL ORIGEN: se copia `quotes.duration_hours` a
-- `reservations.hours_count`. NO se toca `make_busy_range` — su COALESCE sigue
-- siendo el único lugar donde vive el "3", y así sigue protegiendo filas legacy.
--
-- ── QUIÉN MÁS ESCRIBE hours_count (auditado antes de tocar nada) ──────────
-- Solo 4 funciones crean reservaciones:
--   · `instant_accept_request`  (Express instantáneo) → `COALESCE(v_req.hours, 3)` ✔ ya lo escribe
--   · `client_accept_proposal`  (Express, propuesta)  → `v_hours`                  ✔ ya lo escribe
--   · `client_accept_quote`     (cotizaciones)        → NO LO ESCRIBE  ← esto se corrige
--   · `create_booking_with_event` (contratación directa) → NO LO ESCRIBE, y ADEMÁS
--     no tiene ningún parámetro de duración, así que no se puede corregir sin
--     cambiar su firma y la pantalla que la llama. QUEDA REPORTADO, NO TOCADO.
-- Express no se modifica: se prueba que sigue igual.
--
-- ── QUÉ CAMBIA DE COMPORTAMIENTO (y qué no) ───────────────────────────────
-- Consumidores que YA caían al valor de la quote → el resultado es IDÉNTICO:
--   · `complete_event`             COALESCE(hours_count, quote_hours, 3)
--   · `admin_force_start_event`    COALESCE(hours_count, (SELECT duration_hours …), 3)
--   · `mark_abandoned_reservations` COALESCE(hours_count, qte.duration_hours, 4)
-- Consumidores que caían a 3 → ahora usan la duración real (esto es el arreglo):
--   · `make_busy_range` (el calendario), `auto_finalize_stuck_events`,
--     `notify_break_transitions`, `_check_event_compliance`.
-- DINERO: ninguna función de precio/comisión/payout lee `hours_count`. La única
-- que lo usaba para un precio era `request_overtime`, y está MUERTA: hace
-- `LEFT JOIN public.packages` y lee `r.package_id`, y ni la tabla ni la columna
-- existen (la tabla packages fue erradicada). El sistema vivo de horas extra
-- (`request_extra_hours_client`, `admin_propose_extra_hours`,
-- `group_confirm_extra_hours`…) no lee `hours_count`. No se conecta nada con
-- `extra_hours`: las horas cotizadas antes del contrato y las horas adicionales
-- durante el evento siguen siendo cosas separadas.
--
-- ── duration_hours EN NULL: CUÁL ES EL COMPORTAMIENTO Y QUÉ SE PROPONE ────
-- `quotes.duration_hours` es `integer NOT NULL` con
-- `CHECK (duration_hours >= 3 AND duration_hours <= 12)` (validado, no NOT VALID),
-- así que HOY UN NULL ES IMPOSIBLE — y 5.5 h tampoco se puede expresar: el tipo
-- es entero y el CHECK acota a 3..12. (`reservations.hours_count` sí es numeric,
-- así que el día que se quieran medias horas solo hay que cambiar la quote.)
-- Fallback elegido: se asigna `v_quote.duration_hours` TAL CUAL, sin COALESCE.
-- Si algún día apareciera un NULL, `hours_count` quedaría NULL y
-- `make_busy_range` seguiría aplicando su 3 de siempre: exactamente el
-- comportamiento actual, sin inventar ninguna regla nueva ni duplicar el "3".
--
-- ── PARTE 2: price_from EDITABLE ──────────────────────────────────────────
-- Auditoría: `groups.price_from numeric`, sin CHECK, sin índice, y NINGUNA UI lo
-- escribe (1 de 17 grupos lo tiene, puesto a mano). Lo leen 6 funciones:
--   · `get_discovery_sections`, `get_groups_ranked_by_city`, `get_top_recommendation`,
--     `get_personalized_recommendations`, `get_active_recommendations` → solo lo
--     EXPONEN en listados (y la web ordena por él: price_asc / price_desc).
--   · `get_dynamic_price_suggestion` lo usa como "precio de referencia del grupo"
--     para SUGERIR un precio (con fallback al promedio de la ciudad o 1500). No
--     escribe nada y NINGUNA pantalla la llama (solo existe desde sql/148).
-- O sea: la semántica vigente ya es "precio desde / referencia". No hay conflicto.
-- Se agrega al mismo editor de catálogo (Admin y proveedor) y al registro, con
-- CHECK de no-negativo. NO se conecta al cálculo de quotes, comisión, reserva ni
-- pagos: la quote real sigue mandando. NO se inventa para los 16 grupos sin dato.
--
-- ── ORDEN DE APLICACIÓN: 724 VA ANTES QUE ESTA ────────────────────────────
-- sql/724 (ETAPA 3.6A) cerró los ALTER DEFAULT PRIVILEGES del esquema: una
-- función nueva ya NO nace con EXECUTE para PUBLIC ni para anon (sí para
-- authenticated y service_role). Eso cambia dos cosas aquí:
--   · `submit_provider_application` se recrea con DROP+CREATE, así que su ACL
--     se reconstruye desde el default. Como el registro es PÚBLICO y sin sesión,
--     el GRANT a `anon` de más abajo dejó de ser decorativo: AHORA ES LO ÚNICO
--     que lo mantiene vivo. No quitarlo.
--   · `set_group_commercial_catalog` con 6 argumentos también es una firma nueva;
--     su REVOKE/GRANT explícito de más abajo la deja solo para authenticated y
--     service_role, que es lo correcto.
-- Las otras tres (`client_accept_quote`, `admin_approve_provider_application`,
-- `admin_get_provider_applications`) se editan con CREATE OR REPLACE, que
-- CONSERVA el ACL existente: no hay nada que reponer.
-- El bloque de verificación final comprueba las tres cosas, para que 722 no
-- pueda reabrir lo que 724 cerró.
--
-- ── CAPACIDAD Y RENTA ─────────────────────────────────────────────────────
-- No se migra `category_details.capacity` (terraza) en esta migración: hacerlo
-- exige tocar archivos que son WIP ajeno. La recomendación va en el reporte.
-- `price_from` sí aplica a TODAS las categorías, así que `renta` —que no se vende
-- por horas ni por personas— por fin tiene un dato comercial estructurado.
-- ═══════════════════════════════════════════════════════════════════════════

BEGIN;

DO $guard$
BEGIN
  IF (SELECT md5(prosrc) FROM pg_proc WHERE oid = to_regprocedure('public.client_accept_quote(uuid,uuid,integer)'))
     <> '59d981aa1793176834b22c09b0f9c21e' THEN
    RAISE EXCEPTION 'client_accept_quote cambio (md5 <> 59d981aa...). Reauditar antes de aplicar 722.';
  END IF;
  IF (SELECT md5(prosrc) FROM pg_proc WHERE oid = to_regprocedure('public.admin_approve_provider_application(uuid,text,text,text)'))
     <> '1e6f02b8de3dc3a64f5f6c981f3e9e26' THEN
    RAISE EXCEPTION 'admin_approve_provider_application cambio (md5 <> 1e6f02b8...). Reauditar.';
  END IF;
  IF (SELECT md5(prosrc) FROM pg_proc WHERE oid = to_regprocedure('public.admin_get_provider_applications(text)'))
     <> '36c689b14e4d87ed0890f00c922c51c5' THEN
    RAISE EXCEPTION 'admin_get_provider_applications cambio (md5 <> 36c689b1...). Reauditar.';
  END IF;
  IF (SELECT md5(prosrc) FROM pg_proc
      WHERE oid = to_regprocedure('public.submit_provider_application(text,text,text,integer,numeric,text,text,text,text,numeric,numeric,integer)'))
     <> '8e9e8529822004fbe10345504d42b067' THEN
    RAISE EXCEPTION 'submit_provider_application cambio (md5 <> 8e9e8529...). Reauditar.';
  END IF;
  -- El "3" debe seguir viviendo SOLO en make_busy_range: si esa funcion cambio,
  -- hay que releerla antes de corregir el origen.
  IF (SELECT md5(prosrc) FROM pg_proc
      WHERE oid = to_regprocedure('public.make_busy_range(date,time without time zone,text,numeric,integer)'))
     <> '845010692b27fc02ab313d1937788a59' THEN
    RAISE EXCEPTION 'make_busy_range cambio (md5 <> 84501069...). Reauditar antes de aplicar 722.';
  END IF;
  IF EXISTS (SELECT 1 FROM pg_attribute WHERE attrelid='public.provider_applications'::regclass
             AND attname='price_from' AND NOT attisdropped) THEN
    RAISE EXCEPTION 'provider_applications.price_from ya existe. Revisar a mano.';
  END IF;
END
$guard$;

-- ═══════════ PARTE 1 — la duración llega a la reserva ═══════════
DO $mig1$
DECLARE
  v_def TEXT;
  v_nl  TEXT;
  v_n   INT;
BEGIN
  SELECT pg_get_functiondef(oid) INTO v_def FROM pg_proc
  WHERE oid = to_regprocedure('public.client_accept_quote(uuid,uuid,integer)');

  v_nl := CASE WHEN v_def LIKE '%' || chr(13) || '%' THEN chr(13) || chr(10) ELSE chr(10) END;

  -- (a) columna
  v_n := (length(v_def) - length(replace(v_def, '      is_gift, gift_recipient_name, gift_recipient_contact, gift_message', ''))) / length('      is_gift, gift_recipient_name, gift_recipient_contact, gift_message');
  IF v_n <> 1 THEN RAISE EXCEPTION 'accept_quote: lista de columnas esperada 1 vez, encontrada %', v_n; END IF;
  v_def := replace(v_def,
    '      is_gift, gift_recipient_name, gift_recipient_contact, gift_message',
    '      is_gift, gift_recipient_name, gift_recipient_contact, gift_message,' || v_nl ||
    '      hours_count');

  -- (b) valor: la duracion acordada en la quote, tal cual (ver el encabezado
  --     sobre el fallback: sin COALESCE a proposito).
  v_n := (length(v_def) - length(replace(v_def, '      v_quote.is_gift, v_quote.gift_recipient_name, v_quote.gift_recipient_contact, v_quote.gift_message', ''))) / length('      v_quote.is_gift, v_quote.gift_recipient_name, v_quote.gift_recipient_contact, v_quote.gift_message');
  IF v_n <> 1 THEN RAISE EXCEPTION 'accept_quote: lista de valores esperada 1 vez, encontrada %', v_n; END IF;
  v_def := replace(v_def,
    '      v_quote.is_gift, v_quote.gift_recipient_name, v_quote.gift_recipient_contact, v_quote.gift_message',
    '      v_quote.is_gift, v_quote.gift_recipient_name, v_quote.gift_recipient_contact, v_quote.gift_message,' || v_nl ||
    '      v_quote.duration_hours');

  EXECUTE v_def;
END
$mig1$;

-- ═══════════ PARTE 2 — price_from editable ═══════════
ALTER TABLE public.groups
  ADD CONSTRAINT chk_groups_price_from
    CHECK (price_from IS NULL OR (price_from >= 0 AND price_from <= 10000000));

COMMENT ON COLUMN public.groups.price_from IS
  'sql/722 — precio base "DESDE" (referencia comercial), no una cotizacion garantizada. Sirve para filtrar, ordenar (la web ordena por el) y dar una estimacion inicial junto con included_hours/min_hours. NO entra en el calculo de quotes, comision, reserva ni pagos: la quote real manda. NULL = sin precio publicado ("A cotizar").';

ALTER TABLE public.provider_applications
  ADD COLUMN IF NOT EXISTS price_from numeric;

ALTER TABLE public.provider_applications
  ADD CONSTRAINT chk_papps_price_from
    CHECK (price_from IS NULL OR (price_from >= 0 AND price_from <= 10000000));

COMMENT ON COLUMN public.provider_applications.price_from IS
  'sql/722 — precio "desde" que declara el proveedor al registrarse; se copia a groups.price_from al aprobar.';

-- La RPC del catalogo pasa a 6 campos. Se reemplaza la de 5 argumentos (creada
-- en 720 y que todavia no viaja en ningun binario publicado) para no dejar dos
-- versiones y provocar ambiguedad 42725 en PostgREST.
CREATE OR REPLACE FUNCTION public.set_group_commercial_catalog(
  p_group_id         UUID,
  p_min_hours        NUMERIC DEFAULT NULL,
  p_included_hours   NUMERIC DEFAULT NULL,
  p_extra_hour_price NUMERIC DEFAULT NULL,
  p_capacity_max     INTEGER DEFAULT NULL,
  p_price_from       NUMERIC DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_uid    UUID := auth.uid();
  v_role   TEXT;
  v_group  RECORD;
  v_avisos TEXT[] := '{}';
BEGIN
  IF v_uid IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_authenticated');
  END IF;

  SELECT g.id, g.owner_id, g.country INTO v_group
  FROM public.groups g WHERE g.id = p_group_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'group_not_found');
  END IF;

  SELECT p.role INTO v_role FROM public.profiles p WHERE p.id = v_uid;

  -- Dueño del grupo, Admin global, o admin_ops SOLO en su pais.
  IF NOT (
       v_group.owner_id = v_uid
    OR v_role = 'admin'
    OR (v_role = 'admin_ops'
        AND public.country_code_of(v_group.country) = public.admin_ops_country(v_uid))
  ) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_allowed');
  END IF;

  -- Validaciones explicitas: mismos limites que los CHECK, pero con un error
  -- que la app puede mostrar en vez de un 23514 crudo.
  IF p_min_hours IS NOT NULL AND (p_min_hours <= 0 OR p_min_hours > 24) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_min_hours');
  END IF;
  IF p_included_hours IS NOT NULL AND (p_included_hours <= 0 OR p_included_hours > 24) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_included_hours');
  END IF;
  IF p_extra_hour_price IS NOT NULL AND p_extra_hour_price < 0 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_extra_hour_price');
  END IF;
  IF p_capacity_max IS NOT NULL AND (p_capacity_max <= 0 OR p_capacity_max > 100000) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_capacity_max');
  END IF;
  -- price_from es un precio "desde", no una cotizacion: 0 no tiene sentido como
  -- gancho comercial pero tampoco hay razon para prohibirlo; solo se acota.
  IF p_price_from IS NOT NULL AND (p_price_from < 0 OR p_price_from > 10000000) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_price_from');
  END IF;

  -- Reemplazo completo de los 5 campos: asi "vaciar" un dato es simplemente
  -- mandarlo en NULL, que es un valor legitimo del catalogo.
  UPDATE public.groups g
  SET min_hours        = p_min_hours,
      included_hours   = p_included_hours,
      extra_hour_price = p_extra_hour_price,
      capacity_max     = p_capacity_max,
      price_from       = p_price_from
  WHERE g.id = p_group_id;

  -- Avisos NO bloqueantes (ver el encabezado de 720).
  IF p_min_hours IS NOT NULL AND p_included_hours IS NOT NULL
     AND p_included_hours < p_min_hours THEN
    v_avisos := array_append(v_avisos, 'included_lt_min');
  END IF;
  -- Un "desde" sin decir cuantas horas incluye es lo que hace que el cliente
  -- crea que ese precio le alcanza para todo su evento.
  IF p_price_from IS NOT NULL AND p_included_hours IS NULL THEN
    v_avisos := array_append(v_avisos, 'price_without_included_hours');
  END IF;

  RETURN jsonb_build_object(
    'ok',               true,
    'group_id',         p_group_id,
    'min_hours',        p_min_hours,
    'included_hours',   p_included_hours,
    'extra_hour_price', p_extra_hour_price,
    'capacity_max',     p_capacity_max,
    'price_from',       p_price_from,
    'avisos',           to_jsonb(v_avisos));
END;
$function$;

COMMENT ON FUNCTION public.set_group_commercial_catalog(uuid,numeric,numeric,numeric,integer,numeric) IS
  'sql/720+722 — escribe el catalogo comercial de un grupo (min_hours, included_hours, extra_hour_price, capacity_max, price_from). Permiso doble: dueño del grupo, admin global, o admin_ops de ESE pais. Reemplaza los 5 campos (NULL es valido). Devuelve avisos no bloqueantes. price_from es un precio "desde": NO entra en quotes, comision, reserva ni pagos.';

DROP FUNCTION public.set_group_commercial_catalog(uuid,numeric,numeric,numeric,integer);

REVOKE ALL ON FUNCTION public.set_group_commercial_catalog(uuid,numeric,numeric,numeric,integer,numeric) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.set_group_commercial_catalog(uuid,numeric,numeric,numeric,integer,numeric) FROM anon;
GRANT EXECUTE ON FUNCTION public.set_group_commercial_catalog(uuid,numeric,numeric,numeric,integer,numeric)
  TO authenticated, service_role;

-- El registro tambien captura el "desde".
DO $mig2$
DECLARE
  v_def TEXT;
  v_nl  TEXT;
  v_n   INT;
BEGIN
  SELECT pg_get_functiondef(oid) INTO v_def FROM pg_proc
  WHERE oid = to_regprocedure('public.submit_provider_application(text,text,text,integer,numeric,text,text,text,text,numeric,numeric,integer)');

  v_nl := CASE WHEN v_def LIKE '%' || chr(13) || '%' THEN chr(13) || chr(10) ELSE chr(10) END;

  v_n := (length(v_def) - length(replace(v_def, 'p_capacity_max integer DEFAULT NULL::integer)', ''))) / length('p_capacity_max integer DEFAULT NULL::integer)');
  IF v_n <> 1 THEN RAISE EXCEPTION 'submit: firma esperada 1 vez, encontrada %', v_n; END IF;
  v_def := replace(v_def,
    'p_capacity_max integer DEFAULT NULL::integer)',
    'p_capacity_max integer DEFAULT NULL::integer, p_price_from numeric DEFAULT NULL::numeric)');

  v_n := (length(v_def) - length(replace(v_def, 'notes, included_hours, extra_hour_price, capacity_max)', ''))) / length('notes, included_hours, extra_hour_price, capacity_max)');
  IF v_n <> 1 THEN RAISE EXCEPTION 'submit: columnas esperadas 1 vez, encontradas %', v_n; END IF;
  v_def := replace(v_def,
    'notes, included_hours, extra_hour_price, capacity_max)',
    'notes, included_hours, extra_hour_price, capacity_max, price_from)');

  v_n := (length(v_def) - length(replace(v_def, 'p_included_hours, p_extra_hour_price, p_capacity_max)', ''))) / length('p_included_hours, p_extra_hour_price, p_capacity_max)');
  IF v_n <> 1 THEN RAISE EXCEPTION 'submit: valores esperados 1 vez, encontrados %', v_n; END IF;
  v_def := replace(v_def,
    'p_included_hours, p_extra_hour_price, p_capacity_max)',
    'p_included_hours, p_extra_hour_price, p_capacity_max, p_price_from)');

  EXECUTE v_def;

  DROP FUNCTION public.submit_provider_application(
    text, text, text, integer, numeric, text, text, text, text, numeric, numeric, integer);
END
$mig2$;

GRANT EXECUTE ON FUNCTION public.submit_provider_application(
  text, text, text, integer, numeric, text, text, text, text, numeric, numeric, integer, numeric)
  TO anon, authenticated, service_role;

-- La aprobacion copia tambien el "desde".
DO $mig3$
DECLARE
  v_def TEXT;
  v_n   INT;
BEGIN
  SELECT pg_get_functiondef(oid) INTO v_def FROM pg_proc
  WHERE oid = to_regprocedure('public.admin_approve_provider_application(uuid,text,text,text)');

  v_n := (length(v_def) - length(replace(v_def, '    min_hours, included_hours, extra_hour_price, capacity_max', ''))) / length('    min_hours, included_hours, extra_hour_price, capacity_max');
  IF v_n <> 1 THEN RAISE EXCEPTION 'approve: columnas esperadas 1 vez, encontradas %', v_n; END IF;
  v_def := replace(v_def,
    '    min_hours, included_hours, extra_hour_price, capacity_max',
    '    min_hours, included_hours, extra_hour_price, capacity_max, price_from');

  v_n := (length(v_def) - length(replace(v_def, '    v_app.min_hours, v_app.included_hours, v_app.extra_hour_price, v_app.capacity_max', ''))) / length('    v_app.min_hours, v_app.included_hours, v_app.extra_hour_price, v_app.capacity_max');
  IF v_n <> 1 THEN RAISE EXCEPTION 'approve: valores esperados 1 vez, encontrados %', v_n; END IF;
  v_def := replace(v_def,
    '    v_app.min_hours, v_app.included_hours, v_app.extra_hour_price, v_app.capacity_max',
    '    v_app.min_hours, v_app.included_hours, v_app.extra_hour_price, v_app.capacity_max, v_app.price_from');

  EXECUTE v_def;
END
$mig3$;

-- Admin ve el "desde" en la cola de solicitudes.
DO $mig4$
DECLARE
  v_def TEXT;
  v_n   INT;
BEGIN
  SELECT pg_get_functiondef(oid) INTO v_def FROM pg_proc
  WHERE oid = to_regprocedure('public.admin_get_provider_applications(text)');

  v_n := (length(v_def) - length(replace(v_def, '''capacity_max'', a.capacity_max,', ''))) / length('''capacity_max'', a.capacity_max,');
  IF v_n <> 1 THEN RAISE EXCEPTION 'get_apps: fragmento esperado 1 vez, encontrado %', v_n; END IF;
  v_def := replace(v_def,
    '''capacity_max'', a.capacity_max,',
    '''capacity_max'', a.capacity_max, ''price_from'', a.price_from,');

  EXECUTE v_def;
END
$mig4$;

-- ═══════════ VERIFICACIÓN ═══════════
DO $verify$
BEGIN
  -- La duracion ya se copia.
  IF (SELECT prosrc FROM pg_proc WHERE oid = to_regprocedure('public.client_accept_quote(uuid,uuid,integer)'))
     NOT LIKE '%v_quote.duration_hours%' THEN
    RAISE EXCEPTION 'client_accept_quote no quedo copiando duration_hours. Abortando.';
  END IF;
  -- Y NO se inventó ningún 3 nuevo ahí.
  IF (SELECT prosrc FROM pg_proc WHERE oid = to_regprocedure('public.client_accept_quote(uuid,uuid,integer)'))
     LIKE '%COALESCE(v_quote.duration_hours%' THEN
    RAISE EXCEPTION 'client_accept_quote metio un COALESCE sobre duration_hours; el fallback debe vivir solo en make_busy_range. Abortando.';
  END IF;
  -- make_busy_range intacta.
  IF (SELECT md5(prosrc) FROM pg_proc
      WHERE oid = to_regprocedure('public.make_busy_range(date,time without time zone,text,numeric,integer)'))
     <> '845010692b27fc02ab313d1937788a59' THEN
    RAISE EXCEPTION '722 modifico make_busy_range. Abortando.';
  END IF;
  -- Express intacto.
  IF (SELECT md5(prosrc) FROM pg_proc WHERE oid = to_regprocedure('public.instant_accept_request(uuid,numeric,numeric,text)'))
     <> 'a5dffe3d273846f6efbfdef2df412c30' THEN
    RAISE EXCEPTION '722 modifico instant_accept_request (Express). Abortando.';
  END IF;
  IF (SELECT md5(prosrc) FROM pg_proc WHERE oid = to_regprocedure('public.client_accept_proposal(uuid,uuid)'))
     <> '362d4a3c884e2cd5e5a51128c5a7fc11' THEN
    RAISE EXCEPTION '722 modifico client_accept_proposal (Express). Abortando.';
  END IF;
  -- Catalogo: una sola version, con price_from.
  IF (SELECT COUNT(*) FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
      WHERE n.nspname='public' AND p.proname='set_group_commercial_catalog') <> 1 THEN
    RAISE EXCEPTION 'Quedo mas de una version de set_group_commercial_catalog (ambiguedad 42725). Abortando.';
  END IF;
  IF (SELECT COUNT(*) FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
      WHERE n.nspname='public' AND p.proname='submit_provider_application') <> 1 THEN
    RAISE EXCEPTION 'Quedo mas de una version de submit_provider_application. Abortando.';
  END IF;
  IF has_function_privilege('anon','public.set_group_commercial_catalog(uuid,numeric,numeric,numeric,integer,numeric)','EXECUTE') THEN
    RAISE EXCEPTION 'anon puede ejecutar la RPC del catalogo. Abortando.';
  END IF;
  -- price_from no se invento para nadie.
  IF (SELECT COUNT(*) FROM public.groups WHERE price_from IS NOT NULL) <> 1 THEN
    RAISE EXCEPTION 'El numero de grupos con price_from cambio; 722 no debe inventar precios. Abortando.';
  END IF;
  -- Nada de dinero se toco.
  IF (SELECT md5(prosrc) FROM pg_proc WHERE oid = to_regprocedure('public.calculate_final_price(numeric,boolean,text,text,numeric,text)'))
     <> '37e3c7bfc9844cc533f6340fed38e206' THEN
    RAISE EXCEPTION '722 modifico calculate_final_price. Abortando.';
  END IF;
  IF (SELECT prosrc FROM pg_proc
      WHERE oid = to_regprocedure('public.set_group_commercial_catalog(uuid,numeric,numeric,numeric,integer,numeric)'))
     ~* '(extra_hours|reservation|payment|stripe|conekta|commission|calculate_final_price)' THEN
    RAISE EXCEPTION 'La RPC del catalogo menciona dinero/extra_hours. Abortando.';
  END IF;

  -- ── ACL: 722 no debe reabrir nada de lo que cerro sql/724 ────────────────
  -- El registro es publico y sin sesion: tiene que seguir siendo ejecutable por
  -- anon. Es la UNICA excepcion deliberada.
  IF NOT has_function_privilege('anon', 'public.submit_provider_application(text,text,text,integer,numeric,text,text,text,text,numeric,numeric,integer,numeric)', 'EXECUTE') THEN
    RAISE EXCEPTION 'submit_provider_application quedo sin anon: romperia el registro publico. Abortando.';
  END IF;
  -- El catalogo es para usuarios con sesion, nunca para anon.
  IF has_function_privilege('anon', 'public.set_group_commercial_catalog(uuid,numeric,numeric,numeric,integer,numeric)', 'EXECUTE') THEN
    RAISE EXCEPTION 'set_group_commercial_catalog quedo abierta a anon. Abortando.';
  END IF;
  IF NOT has_function_privilege('authenticated', 'public.set_group_commercial_catalog(uuid,numeric,numeric,numeric,integer,numeric)', 'EXECUTE') THEN
    RAISE EXCEPTION 'set_group_commercial_catalog quedo sin authenticated: el dueño no podria editar. Abortando.';
  END IF;
  -- Y las 8 funciones de webhook que cerro 724 deben seguir cerradas.
  IF EXISTS (
    SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
    WHERE n.nspname='public' AND p.proname IN
      ('confirm_gift_payment','confirm_bid_payment','confirm_recommendation_payment',
       'mark_ad_payment','renew_recommendation_subscription','renew_sponsored_subscription',
       'activate_plus','deactivate_plus')
      AND (has_function_privilege('anon', p.oid, 'EXECUTE')
        OR has_function_privilege('authenticated', p.oid, 'EXECUTE'))
  ) THEN
    RAISE EXCEPTION '722 reabrio alguna funcion de webhook que sql/724 habia cerrado. Abortando.';
  END IF;
  -- Y la cola de Admin tampoco debe abrirse a anon.
  IF has_function_privilege('anon', 'public.admin_get_provider_applications(text)', 'EXECUTE') THEN
    RAISE EXCEPTION 'admin_get_provider_applications quedo abierta a anon. Abortando.';
  END IF;
END
$verify$;

NOTIFY pgrst, 'reload schema';

COMMIT;
