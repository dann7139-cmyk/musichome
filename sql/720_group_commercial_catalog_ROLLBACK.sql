-- ═══════════════════════════════════════════════════════════════════════════
-- ROLLBACK de sql/720 — catálogo comercial del proveedor
-- ═══════════════════════════════════════════════════════════════════════════
-- NO SE EJECUTA salvo emergencia deliberada.
--
-- Revierte las tres funciones a sus bytes EXACTOS anteriores (se comprueba con
-- md5 al final, así que si no quedaron idénticas la transacción aborta) y borra
-- las columnas nuevas.
--
-- ⚠ El paso 4 BORRA el catálogo capturado, incluido el backfill de min_hours que
-- se recuperó de `provider_applications`. Si lo único que se quiere es dejar de
-- escribir catálogo, corre SOLO los pasos 1–3 (quitar la RPC) y detente: las
-- columnas quedan inertes y el dato se conserva.
-- ═══════════════════════════════════════════════════════════════════════════

BEGIN;

-- ── 1. Quitar la RPC de escritura ───────────────────────────────────────────
DROP FUNCTION IF EXISTS public.set_group_commercial_catalog(uuid,numeric,numeric,numeric,integer);

-- ── 2. Registro: volver a la versión de 9 argumentos ────────────────────────
DO $rb$
DECLARE
  v_def TEXT;
  v_nl  TEXT;
BEGIN
  SELECT pg_get_functiondef(oid) INTO v_def FROM pg_proc
  WHERE proname='submit_provider_application' AND pronamespace='public'::regnamespace;

  v_nl := CASE WHEN v_def LIKE '%' || chr(13) || '%' THEN chr(13) || chr(10) ELSE chr(10) END;

  v_def := replace(v_def,
    'p_notes text DEFAULT NULL::text, p_included_hours numeric DEFAULT NULL::numeric, p_extra_hour_price numeric DEFAULT NULL::numeric, p_capacity_max integer DEFAULT NULL::integer)',
    'p_notes text DEFAULT NULL::text)');
  v_def := replace(v_def,
    '(full_name, phone, category, years_experience, min_hours, country, state, city, notes, included_hours, extra_hour_price, capacity_max)',
    '(full_name, phone, category, years_experience, min_hours, country, state, city, notes)');
  v_def := replace(v_def,
    'NULLIF(LEFT(trim(COALESCE(p_notes,'''')), 500), ''''),' || v_nl ||
    '     p_included_hours, p_extra_hour_price, p_capacity_max)',
    'NULLIF(LEFT(trim(COALESCE(p_notes,'''')), 500), ''''))');

  EXECUTE v_def;
  DROP FUNCTION public.submit_provider_application(
    text, text, text, integer, numeric, text, text, text, text, numeric, numeric, integer);
END
$rb$;

GRANT EXECUTE ON FUNCTION public.submit_provider_application(
  text, text, text, integer, numeric, text, text, text, text)
  TO anon, authenticated, service_role;

-- ── 3. Aprobación y cola de Admin: quitar las columnas del catálogo ─────────
DO $rb2$
DECLARE
  v_def TEXT;
  v_nl  TEXT;
BEGIN
  SELECT pg_get_functiondef(oid) INTO v_def FROM pg_proc
  WHERE oid = to_regprocedure('public.admin_approve_provider_application(uuid,text,text,text)');
  v_nl := CASE WHEN v_def LIKE '%' || chr(13) || '%' THEN chr(13) || chr(10) ELSE chr(10) END;
  v_def := replace(v_def, ',' || v_nl || '    min_hours, included_hours, extra_hour_price, capacity_max', '');
  v_def := replace(v_def, ',' || v_nl || '    v_app.min_hours, v_app.included_hours, v_app.extra_hour_price, v_app.capacity_max', '');
  EXECUTE v_def;

  SELECT pg_get_functiondef(oid) INTO v_def FROM pg_proc
  WHERE oid = to_regprocedure('public.admin_get_provider_applications(text)');
  v_def := replace(v_def,
    ' ''included_hours'', a.included_hours, ''extra_hour_price'', a.extra_hour_price, ''capacity_max'', a.capacity_max,',
    '');
  EXECUTE v_def;
END
$rb2$;

-- ── 4. Columnas y CHECK (BORRA EL DATO — ver la nota de arriba) ─────────────
ALTER TABLE public.groups
  DROP CONSTRAINT IF EXISTS chk_groups_min_hours,
  DROP CONSTRAINT IF EXISTS chk_groups_included_hours,
  DROP CONSTRAINT IF EXISTS chk_groups_extra_hour_price,
  DROP CONSTRAINT IF EXISTS chk_groups_capacity_max;

ALTER TABLE public.provider_applications
  DROP CONSTRAINT IF EXISTS chk_papps_min_hours,
  DROP CONSTRAINT IF EXISTS chk_papps_included_hours,
  DROP CONSTRAINT IF EXISTS chk_papps_extra_hour_price,
  DROP CONSTRAINT IF EXISTS chk_papps_capacity_max;

ALTER TABLE public.groups
  DROP COLUMN IF EXISTS min_hours,
  DROP COLUMN IF EXISTS included_hours,
  DROP COLUMN IF EXISTS extra_hour_price,
  DROP COLUMN IF EXISTS capacity_max;

ALTER TABLE public.provider_applications
  DROP COLUMN IF EXISTS included_hours,
  DROP COLUMN IF EXISTS extra_hour_price,
  DROP COLUMN IF EXISTS capacity_max;

-- ── 5. Prueba de identidad: los bytes deben ser los de antes de 720 ─────────
DO $verify$
BEGIN
  IF (SELECT md5(prosrc) FROM pg_proc
      WHERE oid = to_regprocedure('public.submit_provider_application(text,text,text,integer,numeric,text,text,text,text)'))
     <> '8b1c2937a34844beb4d8b5f2eec080c5' THEN
    RAISE EXCEPTION 'submit_provider_application NO volvio a sus bytes originales. Abortando el rollback.';
  END IF;
  IF (SELECT md5(prosrc) FROM pg_proc
      WHERE oid = to_regprocedure('public.admin_approve_provider_application(uuid,text,text,text)'))
     <> 'd760dfb8f1f5e11f6fa95e05ec25f43e' THEN
    RAISE EXCEPTION 'admin_approve_provider_application NO volvio a sus bytes originales. Abortando el rollback.';
  END IF;
  IF (SELECT md5(prosrc) FROM pg_proc
      WHERE oid = to_regprocedure('public.admin_get_provider_applications(text)'))
     <> 'f27b9f2002db86c11b83e14edfee379f' THEN
    RAISE EXCEPTION 'admin_get_provider_applications NO volvio a sus bytes originales. Abortando el rollback.';
  END IF;
  IF (SELECT COUNT(*) FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
      WHERE n.nspname='public' AND p.proname='submit_provider_application') <> 1 THEN
    RAISE EXCEPTION 'Quedo mas de una version de submit_provider_application. Abortando.';
  END IF;
END
$verify$;

NOTIFY pgrst, 'reload schema';

COMMIT;
