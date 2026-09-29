-- ═══════════════════════════════════════════════════════════════════════════
-- 720 — ETAPA 3: catálogo comercial del proveedor
-- ═══════════════════════════════════════════════════════════════════════════
-- Hoy el valor numérico que el proveedor declara al registrarse
-- (`provider_applications.min_hours`) se PIERDE: `admin_approve_provider_
-- application` lo mete en la prosa de `groups.description`
-- ("Contratación mínima: 3 horas.") y ninguna columna estructurada lo guarda.
-- Verificado en producción: 12 de 16 solicitudes traen min_hours (valores 2 y 3)
-- y las 15 aprobadas quedaron con el dato solo como texto.
--
-- Esto crea el catálogo comercial estructurado sobre el MISMO `groups.id`, sirva
-- el proveedor su propia cuenta o lo siga administrando Daricefy
-- (`concierge_mode = true`).
--
-- ── AUDITORÍA DE DUPLICADOS (hecha antes de crear cada columna) ───────────
--   min_hours        → NO existe equivalente en `groups`. La fuente de entrada
--                      es `provider_applications.min_hours`, que seguirá siendo
--                      la puerta del registro; `groups.min_hours` es el dato
--                      vigente del proveedor. Se copia al aprobar.
--   included_hours   → NO existe equivalente en ninguna tabla.
--   extra_hour_price → NO existe equivalente. Hay tres campos PARECIDOS que NO
--                      son esto y que NO se tocan:
--                        · `groups.extra_hours_rate` NUMERIC(5,2) — NO es un
--                          precio: es una ESTADÍSTICA (eventos con horas extra
--                          aceptadas / eventos completados), la calcula sql/136.
--                        · `quotes.extra_hour_price` — precio de horas extra de
--                          ESE evento; lo escribe únicamente `request_overtime`,
--                          o sea el mecanismo DURANTE el evento.
--                        · `extra_hours.price_per_hour` — la hora extra ya
--                          cobrada. Es el sistema `extra_hours`, intocable.
--                      Regla: catálogo = referencia previa; quote = precio
--                      realmente cotizado para ese evento.
--   capacity_max     → NO existe columna, PERO hay un equivalente parcial:
--                      `groups.category_details->>'capacity'` (jsonb) para la
--                      categoría `terraza`. Ver "OJO CON TERRAZAS" abajo.
--                      `groups.sound_capacity_max` es OTRA cosa: a cuánta gente
--                      le alcanza el EQUIPO DE SONIDO del proveedor (sql/403),
--                      no la capacidad del servicio.
--
-- ── OJO CON TERRAZAS (única divergencia con el diseño) ────────────────────
-- `CATEGORY_DETAIL_FIELDS.terraza` ya tiene un campo `capacity` (number) que se
-- le pregunta al proveedor Y al cliente. Para el proveedor significa exactamente
-- `capacity_max`. Para NO crear dos fuentes de verdad, en esta etapa:
--   · `capacity_max` NO se le pide a la categoría `terraza` en el formulario del
--     proveedor (sigue en `category_details.capacity`);
--   · NO se migra ese jsonb (0 de 17 grupos tiene datos ahí hoy — todos son
--     música), porque hacerlo bien exige tocar 3 archivos que son WIP ajeno.
-- Mientras eso no se resuelva, quien lea capacidad debe usar
--   COALESCE(g.capacity_max, (g.category_details->>'capacity')::int)
-- y hay que cerrarlo ANTES de lanzar terrazas.
--
-- ── LO QUE ESTO NO ES ─────────────────────────────────────────────────────
-- Estos campos sirven para filtrar, ordenar, respetar mínimos y dar una
-- estimación inicial. NO son un precio final garantizado: el precio final sigue
-- siendo la quote real respondida por Admin/proveedor, con traslado cuando
-- corresponda. No se toca `calculate_final_price`, ni `admin_respond_quote`, ni
-- el margen/comisión, ni `extra_hours`, ni pagos.
-- NO se crean `package_price` ni `package_enabled`: "Arma mi fiesta" usará
-- cotizaciones reales individuales.
--
-- ── min_hours VS included_hours: SIN RELACIÓN OBLIGATORIA ─────────────────
-- A propósito NO hay CHECK que los relacione. Un grupo puede tener mínimo 3 h e
-- incluir 3 h (iguales); una terraza puede tener mínimo 6 h de renta e incluir
-- 8 h en su precio base (incluidas > mínimo). El único caso sospechoso es
-- incluidas < mínimo (la estimación saldría más baja que cualquier contratación
-- real): eso se devuelve como AVISO no bloqueante, no como error, porque no está
-- comprobado que ningún servicio lo necesite.
-- ═══════════════════════════════════════════════════════════════════════════

BEGIN;

DO $guard$
BEGIN
  IF to_regprocedure('public.country_code_of(text)') IS NULL
     OR to_regprocedure('public.admin_ops_country(uuid)') IS NULL THEN
    RAISE EXCEPTION 'Faltan country_code_of/admin_ops_country. Abortando.';
  END IF;
  -- Las dos funciones que se editan deben estar EXACTAMENTE como se auditaron.
  IF (SELECT md5(prosrc) FROM pg_proc
      WHERE oid = to_regprocedure('public.submit_provider_application(text,text,text,integer,numeric,text,text,text,text)'))
     <> '8b1c2937a34844beb4d8b5f2eec080c5' THEN
    RAISE EXCEPTION 'submit_provider_application cambio (md5 <> 8b1c2937...). Reauditar antes de aplicar 720.';
  END IF;
  IF (SELECT md5(prosrc) FROM pg_proc
      WHERE oid = to_regprocedure('public.admin_approve_provider_application(uuid,text,text,text)'))
     <> 'd760dfb8f1f5e11f6fa95e05ec25f43e' THEN
    RAISE EXCEPTION 'admin_approve_provider_application cambio (md5 <> d760dfb8...). Reauditar antes de aplicar 720.';
  END IF;
  IF (SELECT md5(prosrc) FROM pg_proc
      WHERE oid = to_regprocedure('public.admin_get_provider_applications(text)'))
     <> 'f27b9f2002db86c11b83e14edfee379f' THEN
    RAISE EXCEPTION 'admin_get_provider_applications cambio (md5 <> f27b9f20...). Reauditar antes de aplicar 720.';
  END IF;
  -- Ninguna de las 4 columnas debe existir ya con otro significado.
  IF EXISTS (SELECT 1 FROM pg_attribute WHERE attrelid='public.groups'::regclass
             AND attname IN ('min_hours','included_hours','extra_hour_price','capacity_max')
             AND NOT attisdropped) THEN
    RAISE EXCEPTION 'Alguna columna del catalogo ya existe en groups. Revisar a mano antes de continuar.';
  END IF;
END
$guard$;

-- ── 1. Catálogo en groups (la fuente de verdad) ─────────────────────────────
ALTER TABLE public.groups
  ADD COLUMN IF NOT EXISTS min_hours        numeric(4,1),
  ADD COLUMN IF NOT EXISTS included_hours   numeric(4,1),
  ADD COLUMN IF NOT EXISTS extra_hour_price numeric(10,2),
  ADD COLUMN IF NOT EXISTS capacity_max     integer;

COMMENT ON COLUMN public.groups.min_hours IS
  'sql/720 — horas minimas de contratacion de ESTE proveedor. NULL = no declarado / no aplica (comida y renta no se venden por hora). NUNCA se asume 3: cada servicio tiene su propio minimo. Se copia desde provider_applications.min_hours al aprobar.';
COMMENT ON COLUMN public.groups.included_hours IS
  'sql/720 — cuantas horas incluye el precio base comercial mostrado (groups.price_from). NULL = no declarado. Sin relacion obligatoria con min_hours a proposito.';
COMMENT ON COLUMN public.groups.extra_hour_price IS
  'sql/720 — precio comercial de UNA hora adicional elegida ANTES de contratar (referencia de catalogo). NO es el sistema extra_hours (horas durante/al final del evento, tabla extra_hours + request_overtime), NO es quotes.extra_hour_price (precio de ese evento) y NO es groups.extra_hours_rate (una estadistica). El precio que se cobra siempre es el de la quote.';
COMMENT ON COLUMN public.groups.capacity_max IS
  'sql/720 — capacidad maxima del servicio en la unidad de su categoria (personas, porciones). NULL = no aplica o no se conoce, y NUNCA debe bloquear a un proveedor. No confundir con sound_capacity_max (a cuanta gente le alcanza su equipo de sonido). Para la categoria terraza la capacidad sigue viviendo hoy en category_details.capacity: leer con COALESCE(capacity_max, (category_details->>''capacity'')::int).';

ALTER TABLE public.groups
  ADD CONSTRAINT chk_groups_min_hours
    CHECK (min_hours IS NULL OR (min_hours > 0 AND min_hours <= 24)),
  ADD CONSTRAINT chk_groups_included_hours
    CHECK (included_hours IS NULL OR (included_hours > 0 AND included_hours <= 24)),
  ADD CONSTRAINT chk_groups_extra_hour_price
    CHECK (extra_hour_price IS NULL OR extra_hour_price >= 0),
  ADD CONSTRAINT chk_groups_capacity_max
    CHECK (capacity_max IS NULL OR (capacity_max > 0 AND capacity_max <= 100000));

-- ── 2. Los mismos datos en el registro del proveedor ────────────────────────
-- `min_hours` ya existia; faltaban los otros tres.
ALTER TABLE public.provider_applications
  ADD COLUMN IF NOT EXISTS included_hours   numeric(4,1),
  ADD COLUMN IF NOT EXISTS extra_hour_price numeric(10,2),
  ADD COLUMN IF NOT EXISTS capacity_max     integer;

ALTER TABLE public.provider_applications
  ADD CONSTRAINT chk_papps_min_hours
    CHECK (min_hours IS NULL OR (min_hours > 0 AND min_hours <= 24)),
  ADD CONSTRAINT chk_papps_included_hours
    CHECK (included_hours IS NULL OR (included_hours > 0 AND included_hours <= 24)),
  ADD CONSTRAINT chk_papps_extra_hour_price
    CHECK (extra_hour_price IS NULL OR extra_hour_price >= 0),
  ADD CONSTRAINT chk_papps_capacity_max
    CHECK (capacity_max IS NULL OR (capacity_max > 0 AND capacity_max <= 100000));

COMMENT ON COLUMN public.provider_applications.included_hours   IS 'sql/720 — lo que el proveedor declara al registrarse; se copia a groups.included_hours al aprobar.';
COMMENT ON COLUMN public.provider_applications.extra_hour_price IS 'sql/720 — lo que el proveedor declara al registrarse; se copia a groups.extra_hour_price al aprobar. No tiene nada que ver con el sistema extra_hours.';
COMMENT ON COLUMN public.provider_applications.capacity_max     IS 'sql/720 — lo que el proveedor declara al registrarse; se copia a groups.capacity_max al aprobar.';

-- ── 3. Backfill SEGURO de min_hours ─────────────────────────────────────────
-- Solo valores numéricos que ya existen en `provider_applications`, ligados por
-- `linked_group_id`, y solo cuando el grupo tiene UN único valor inequívoco.
-- NO se infiere nada del texto de `description` ("Contratación mínima: 3 horas")
-- ni se inventa un default: lo que no tenga origen numérico se queda en NULL
-- para que Admin/proveedor lo complete.
WITH inequivocas AS (
  SELECT a.linked_group_id AS gid, MIN(a.min_hours) AS mh
  FROM public.provider_applications a
  WHERE a.status = 'approved'
    AND a.linked_group_id IS NOT NULL
    AND a.min_hours IS NOT NULL
    AND a.min_hours > 0 AND a.min_hours <= 24
  GROUP BY a.linked_group_id
  HAVING COUNT(DISTINCT a.min_hours) = 1
)
UPDATE public.groups g
SET min_hours = i.mh
FROM inequivocas i
WHERE g.id = i.gid AND g.min_hours IS NULL;

-- ── 4. RPC de escritura con doble permiso (dueño o Admin) ───────────────────
-- Por qué una RPC y no solo el UPDATE directo: `groups` tiene GRANT UPDATE a
-- nivel de TABLA para `authenticated` (y `anon`), así que las columnas nuevas
-- quedan escribibles por RLS (dueño o admin) de todos modos — eso es previo a
-- 720 y no se toca aquí. La RPC aporta lo que RLS no puede: un punto único con
-- validación legible, soporte para `admin_ops` acotado a SU país (RLS solo
-- contempla `role = 'admin'`) y el aviso de incluidas < mínimo.
-- La garantía dura son los CHECK de arriba, que aplican a CUALQUIER camino.
CREATE OR REPLACE FUNCTION public.set_group_commercial_catalog(
  p_group_id         UUID,
  p_min_hours        NUMERIC DEFAULT NULL,
  p_included_hours   NUMERIC DEFAULT NULL,
  p_extra_hour_price NUMERIC DEFAULT NULL,
  p_capacity_max     INTEGER DEFAULT NULL)
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

  -- Reemplazo completo de los 4 campos: asi "vaciar" un dato es simplemente
  -- mandarlo en NULL, que es un valor legitimo del catalogo.
  UPDATE public.groups g
  SET min_hours        = p_min_hours,
      included_hours   = p_included_hours,
      extra_hour_price = p_extra_hour_price,
      capacity_max     = p_capacity_max
  WHERE g.id = p_group_id;

  -- Aviso NO bloqueante (ver el encabezado de 720).
  IF p_min_hours IS NOT NULL AND p_included_hours IS NOT NULL
     AND p_included_hours < p_min_hours THEN
    v_avisos := array_append(v_avisos, 'included_lt_min');
  END IF;

  RETURN jsonb_build_object(
    'ok',               true,
    'group_id',         p_group_id,
    'min_hours',        p_min_hours,
    'included_hours',   p_included_hours,
    'extra_hour_price', p_extra_hour_price,
    'capacity_max',     p_capacity_max,
    'avisos',           to_jsonb(v_avisos));
END;
$function$;

COMMENT ON FUNCTION public.set_group_commercial_catalog(uuid,numeric,numeric,numeric,integer) IS
  'sql/720 — escribe el catalogo comercial de un grupo (min_hours, included_hours, extra_hour_price, capacity_max). Permiso doble: dueño del grupo, admin global, o admin_ops de ESE pais. Reemplaza los 4 campos (NULL es un valor valido). Devuelve avisos no bloqueantes. No toca precios de quotes, comision ni extra_hours.';

REVOKE ALL ON FUNCTION public.set_group_commercial_catalog(uuid,numeric,numeric,numeric,integer) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.set_group_commercial_catalog(uuid,numeric,numeric,numeric,integer) FROM anon;
GRANT EXECUTE ON FUNCTION public.set_group_commercial_catalog(uuid,numeric,numeric,numeric,integer)
  TO authenticated, service_role;

-- ── 5. El registro conserva los 4 datos ─────────────────────────────────────
-- `submit_provider_application` se edita POR TRANSFORMACION de su propia
-- definicion desplegada: se leen los bytes reales, se sustituyen fragmentos
-- exactos y se vuelve a crear. Asi no hay riesgo de transcribir mal el resto.
DO $mig$
DECLARE
  v_def TEXT;
  v_nl  TEXT;
  v_n   INT;
BEGIN
  SELECT pg_get_functiondef(oid) INTO v_def FROM pg_proc
  WHERE oid = to_regprocedure('public.submit_provider_application(text,text,text,integer,numeric,text,text,text,text)');

  v_nl := CASE WHEN v_def LIKE '%' || chr(13) || '%' THEN chr(13) || chr(10) ELSE chr(10) END;

  -- (a) tres parametros nuevos, todos opcionales: las llamadas viejas del
  --     binario instalado siguen funcionando igual.
  v_n := (length(v_def) - length(replace(v_def, 'p_notes text DEFAULT NULL::text)', ''))) / length('p_notes text DEFAULT NULL::text)');
  IF v_n <> 1 THEN RAISE EXCEPTION 'submit: firma esperada 1 vez, encontrada %', v_n; END IF;
  v_def := replace(v_def,
    'p_notes text DEFAULT NULL::text)',
    'p_notes text DEFAULT NULL::text, p_included_hours numeric DEFAULT NULL::numeric, p_extra_hour_price numeric DEFAULT NULL::numeric, p_capacity_max integer DEFAULT NULL::integer)');

  -- (b) columnas del INSERT
  v_n := (length(v_def) - length(replace(v_def, '(full_name, phone, category, years_experience, min_hours, country, state, city, notes)', ''))) / length('(full_name, phone, category, years_experience, min_hours, country, state, city, notes)');
  IF v_n <> 1 THEN RAISE EXCEPTION 'submit: lista de columnas esperada 1 vez, encontrada %', v_n; END IF;
  v_def := replace(v_def,
    '(full_name, phone, category, years_experience, min_hours, country, state, city, notes)',
    '(full_name, phone, category, years_experience, min_hours, country, state, city, notes, included_hours, extra_hour_price, capacity_max)');

  -- (c) valores del INSERT
  v_n := (length(v_def) - length(replace(v_def, 'NULLIF(LEFT(trim(COALESCE(p_notes,'''')), 500), ''''))', ''))) / length('NULLIF(LEFT(trim(COALESCE(p_notes,'''')), 500), ''''))');
  IF v_n <> 1 THEN RAISE EXCEPTION 'submit: valores esperados 1 vez, encontrados %', v_n; END IF;
  v_def := replace(v_def,
    'NULLIF(LEFT(trim(COALESCE(p_notes,'''')), 500), ''''))',
    'NULLIF(LEFT(trim(COALESCE(p_notes,'''')), 500), ''''),' || v_nl ||
    '     p_included_hours, p_extra_hour_price, p_capacity_max)');

  EXECUTE v_def;

  -- La version de 9 argumentos sobra y dejaria llamadas ambiguas (42725).
  DROP FUNCTION public.submit_provider_application(text,text,text,integer,numeric,text,text,text,text);
END
$mig$;

-- El registro es PUBLICO (se llena antes de tener cuenta): se reponen los mismos
-- grants que tenia la version de 9 argumentos, ni mas ni menos.
GRANT EXECUTE ON FUNCTION public.submit_provider_application(
  text, text, text, integer, numeric, text, text, text, text, numeric, numeric, integer)
  TO anon, authenticated, service_role;

-- ── 6. La aprobación conserva los 4 datos NUMERICAMENTE ─────────────────────
-- Antes: el valor solo sobrevivia dentro de `v_description` como texto.
-- Ahora: ademas se copia a las columnas del grupo. La prosa se deja intacta
-- (se sigue leyendo bien en el perfil y quitarla no era parte del encargo).
DO $mig2$
DECLARE
  v_def TEXT;
  v_nl  TEXT;
  v_n   INT;
BEGIN
  SELECT pg_get_functiondef(oid) INTO v_def FROM pg_proc
  WHERE oid = to_regprocedure('public.admin_approve_provider_application(uuid,text,text,text)');

  v_nl := CASE WHEN v_def LIKE '%' || chr(13) || '%' THEN chr(13) || chr(10) ELSE chr(10) END;

  v_n := (length(v_def) - length(replace(v_def, '    country_id, country, state, city, concierge_mode', ''))) / length('    country_id, country, state, city, concierge_mode');
  IF v_n <> 1 THEN RAISE EXCEPTION 'approve: columnas esperadas 1 vez, encontradas %', v_n; END IF;
  v_def := replace(v_def,
    '    country_id, country, state, city, concierge_mode',
    '    country_id, country, state, city, concierge_mode,' || v_nl ||
    '    min_hours, included_hours, extra_hour_price, capacity_max');

  v_n := (length(v_def) - length(replace(v_def, '    v_country_id, v_app.country, v_app.state, v_app.city, true', ''))) / length('    v_country_id, v_app.country, v_app.state, v_app.city, true');
  IF v_n <> 1 THEN RAISE EXCEPTION 'approve: valores esperados 1 vez, encontrados %', v_n; END IF;
  v_def := replace(v_def,
    '    v_country_id, v_app.country, v_app.state, v_app.city, true',
    '    v_country_id, v_app.country, v_app.state, v_app.city, true,' || v_nl ||
    '    v_app.min_hours, v_app.included_hours, v_app.extra_hour_price, v_app.capacity_max');

  EXECUTE v_def;
END
$mig2$;

-- ── 7. Admin ve los datos nuevos en la cola de solicitudes ──────────────────
DO $mig3$
DECLARE
  v_def TEXT;
  v_n   INT;
BEGIN
  SELECT pg_get_functiondef(oid) INTO v_def FROM pg_proc
  WHERE oid = to_regprocedure('public.admin_get_provider_applications(text)');

  v_n := (length(v_def) - length(replace(v_def, '''years_experience'', a.years_experience, ''min_hours'', a.min_hours,', ''))) / length('''years_experience'', a.years_experience, ''min_hours'', a.min_hours,');
  IF v_n <> 1 THEN RAISE EXCEPTION 'get_apps: fragmento esperado 1 vez, encontrado %', v_n; END IF;
  v_def := replace(v_def,
    '''years_experience'', a.years_experience, ''min_hours'', a.min_hours,',
    '''years_experience'', a.years_experience, ''min_hours'', a.min_hours, ''included_hours'', a.included_hours, ''extra_hour_price'', a.extra_hour_price, ''capacity_max'', a.capacity_max,');

  EXECUTE v_def;
END
$mig3$;

-- ── 8. Verificación ─────────────────────────────────────────────────────────
DO $verify$
DECLARE
  v_backfill INT;
BEGIN
  IF (SELECT COUNT(*) FROM pg_attribute WHERE attrelid='public.groups'::regclass
      AND attname IN ('min_hours','included_hours','extra_hour_price','capacity_max')
      AND NOT attisdropped) <> 4 THEN
    RAISE EXCEPTION 'Faltan columnas del catalogo en groups. Abortando.';
  END IF;
  IF (SELECT COUNT(*) FROM pg_constraint WHERE conrelid='public.groups'::regclass
      AND conname IN ('chk_groups_min_hours','chk_groups_included_hours',
                      'chk_groups_extra_hour_price','chk_groups_capacity_max')) <> 4 THEN
    RAISE EXCEPTION 'Faltan CHECK del catalogo. Abortando.';
  END IF;
  IF to_regprocedure('public.set_group_commercial_catalog(uuid,numeric,numeric,numeric,integer)') IS NULL THEN
    RAISE EXCEPTION 'No se creo set_group_commercial_catalog. Abortando.';
  END IF;
  IF has_function_privilege('anon','public.set_group_commercial_catalog(uuid,numeric,numeric,numeric,integer)','EXECUTE') THEN
    RAISE EXCEPTION 'anon puede ejecutar la RPC del catalogo. Abortando.';
  END IF;
  -- Solo debe quedar UNA version de submit_provider_application.
  IF (SELECT COUNT(*) FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
      WHERE n.nspname='public' AND p.proname='submit_provider_application') <> 1 THEN
    RAISE EXCEPTION 'Quedo mas de una version de submit_provider_application (ambiguedad 42725). Abortando.';
  END IF;
  -- La aprobacion ya copia el numero.
  IF (SELECT prosrc FROM pg_proc
      WHERE oid = to_regprocedure('public.admin_approve_provider_application(uuid,text,text,text)'))
     NOT LIKE '%v_app.min_hours, v_app.included_hours%' THEN
    RAISE EXCEPTION 'La aprobacion no quedo copiando min_hours. Abortando.';
  END IF;
  -- Nada de esto debio tocar extra_hours ni el calculo de precio.
  IF (SELECT prosrc FROM pg_proc
      WHERE oid = to_regprocedure('public.set_group_commercial_catalog(uuid,numeric,numeric,numeric,integer)'))
     ~* '(extra_hours|reservation|payment|stripe|conekta|commission|comision|calculate_final_price)' THEN
    RAISE EXCEPTION 'La RPC del catalogo menciona dinero/extra_hours. Abortando.';
  END IF;

  SELECT COUNT(*) INTO v_backfill FROM public.groups WHERE min_hours IS NOT NULL;
  RAISE NOTICE '720 OK — grupos con min_hours tras el backfill: %', v_backfill;
END
$verify$;

NOTIFY pgrst, 'reload schema';

COMMIT;
