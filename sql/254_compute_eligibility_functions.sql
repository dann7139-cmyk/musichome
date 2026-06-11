-- ============================================================
-- sql/254_compute_eligibility_functions.sql
--
-- Única fuente de verdad para la lógica de elegibilidad de
-- verificación. Solo lecturas — sin escrituras, sin efectos
-- secundarios.
--
-- FUNCIONES:
--   compute_group_eligibility(group_id)
--     → eligible BOOLEAN, missing_requirements TEXT[]
--
--   compute_profile_eligibility(profile_id)
--     → eligible BOOLEAN, missing_requirements TEXT[]
--
-- PROPÓSITO:
--   Centralizar los criterios de elegibilidad para que triggers,
--   RPCs y evaluate_* (sql/255) los consuman sin duplicación.
--
-- ALCANCE:
--   Sin cambios de schema. Sin GRANTs sobre tablas. Sin triggers.
--   No escribe ningún campo. No modifica permisos.
--
-- CRITERIOS — grupos (extraídos de VerificationScreen.tsx:586-591):
--   • name no nulo ni vacío
--   • genre no nulo ni vacío
--   • profile_image no nulo ni vacío
--   • description no nulo ni vacío
--   • al menos un paquete activo (packages.is_active = TRUE)
--   Video promocional: opcional — no forma parte de la elegibilidad.
--
-- CRITERIOS — perfiles talent (extraídos de JobBoardScreen.tsx):
--   • profiles.full_name, avatar_url, city
--   • job_board_profiles: instrument_or_role, bio, is_visible
--   Perfiles client/group: solo criterios de profiles.
--
-- NOTA DE SEGURIDAD:
--   SECURITY DEFINER permite leer grupos y paquetes sin que
--   las políticas RLS del caller interfieran. Estas funciones
--   son de solo lectura y no exponen datos sensibles.
--
-- VULNERABILIDAD ABIERTA (no resuelta en esta migración):
--   groups_owner_all permite UPDATE directo de is_verified /
--   admin_verified / verification_status. Se cierra en sql/255.
--   Ver memory/project_fase3_verification_architecture.md.
--
-- ROLLBACK: sql/254_rollback.sql
-- ============================================================

-- ── 1. compute_group_eligibility ─────────────────────────────────────────────

CREATE OR REPLACE FUNCTION public.compute_group_eligibility(
  p_group_id UUID
)
RETURNS TABLE(
  eligible             BOOLEAN,
  missing_requirements TEXT[]
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  WITH crit AS (
    SELECT
      CASE WHEN g.name          IS NULL OR trim(g.name)          = ''
           THEN 'name'::TEXT END          AS c_name,
      CASE WHEN g.genre         IS NULL OR trim(g.genre)         = ''
           THEN 'genre'::TEXT END         AS c_genre,
      CASE WHEN g.profile_image IS NULL OR trim(g.profile_image) = ''
           THEN 'profile_image'::TEXT END AS c_photo,
      CASE WHEN g.description   IS NULL OR trim(g.description)   = ''
           THEN 'description'::TEXT END   AS c_desc,
      CASE WHEN NOT EXISTS (
               SELECT 1 FROM public.packages pk
               WHERE pk.group_id = g.id AND pk.is_active = TRUE
             ) THEN 'active_package'::TEXT END AS c_pkg
    FROM public.groups g
    WHERE g.id = p_group_id
  )
  SELECT
    (c_name IS NULL AND c_genre IS NULL AND c_photo IS NULL
     AND c_desc IS NULL AND c_pkg IS NULL)           AS eligible,
    array_remove(
      ARRAY[c_name, c_genre, c_photo, c_desc, c_pkg], NULL
    )                                                AS missing_requirements
  FROM crit;
$$;

GRANT EXECUTE ON FUNCTION public.compute_group_eligibility(UUID)
  TO authenticated, service_role;

-- ── 2. compute_profile_eligibility ───────────────────────────────────────────

CREATE OR REPLACE FUNCTION public.compute_profile_eligibility(
  p_profile_id UUID
)
RETURNS TABLE(
  eligible             BOOLEAN,
  missing_requirements TEXT[]
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_role    TEXT;
  v_fname   TEXT;
  v_avatar  TEXT;
  v_city    TEXT;
  v_missing TEXT[] := '{}';
  v_instr   TEXT;
  v_bio     TEXT;
  v_visible BOOLEAN;
BEGIN
  -- ── Criterios comunes a todos los roles ──────────────────────────────────
  SELECT role, full_name, avatar_url, city
  INTO   v_role, v_fname, v_avatar, v_city
  FROM   public.profiles
  WHERE  id = p_profile_id;

  IF NOT FOUND THEN
    RETURN;  -- profile no existe: 0 filas (el caller debe manejar esto)
  END IF;

  IF v_fname  IS NULL OR trim(v_fname)  = '' THEN
    v_missing := array_append(v_missing, 'full_name');
  END IF;
  IF v_avatar IS NULL OR trim(v_avatar) = '' THEN
    v_missing := array_append(v_missing, 'avatar_url');
  END IF;
  IF v_city   IS NULL OR trim(v_city)   = '' THEN
    v_missing := array_append(v_missing, 'city');
  END IF;

  -- ── Criterios adicionales para talentos ──────────────────────────────────
  IF v_role = 'talent' THEN
    SELECT instrument_or_role, bio, is_visible
    INTO   v_instr, v_bio, v_visible
    FROM   public.job_board_profiles
    WHERE  user_id = p_profile_id;

    IF NOT FOUND THEN
      -- El perfil de job board no existe todavía
      v_missing := array_append(v_missing, 'job_board_profile');
    ELSE
      IF v_instr  IS NULL OR trim(v_instr)  = '' THEN
        v_missing := array_append(v_missing, 'instrument_or_role');
      END IF;
      IF v_bio    IS NULL OR trim(v_bio)    = '' THEN
        v_missing := array_append(v_missing, 'bio');
      END IF;
      IF NOT COALESCE(v_visible, FALSE) THEN
        v_missing := array_append(v_missing, 'profile_visible');
      END IF;
    END IF;
  END IF;

  eligible             := cardinality(v_missing) = 0;
  missing_requirements := v_missing;
  RETURN NEXT;
END;
$$;

GRANT EXECUTE ON FUNCTION public.compute_profile_eligibility(UUID)
  TO authenticated, service_role;

-- ── Verificación ──────────────────────────────────────────────────────────────

DO $$
DECLARE
  v_group_fn   TEXT;
  v_profile_fn TEXT;
  v_test_group RECORD;
  v_test_prof  RECORD;
BEGIN
  -- 1. Ambas funciones existen
  SELECT proname INTO v_group_fn
  FROM pg_proc
  JOIN pg_namespace ns ON ns.oid = pg_proc.pronamespace
  WHERE proname = 'compute_group_eligibility' AND ns.nspname = 'public';

  IF v_group_fn IS NULL THEN
    RAISE EXCEPTION '[254] compute_group_eligibility no encontrada ❌';
  END IF;
  RAISE NOTICE '[254] compute_group_eligibility: existe ✅';

  SELECT proname INTO v_profile_fn
  FROM pg_proc
  JOIN pg_namespace ns ON ns.oid = pg_proc.pronamespace
  WHERE proname = 'compute_profile_eligibility' AND ns.nspname = 'public';

  IF v_profile_fn IS NULL THEN
    RAISE EXCEPTION '[254] compute_profile_eligibility no encontrada ❌';
  END IF;
  RAISE NOTICE '[254] compute_profile_eligibility: existe ✅';

  -- 2. Ambas son STABLE (no VOLATILE)
  IF EXISTS (
    SELECT 1 FROM pg_proc
    JOIN pg_namespace ns ON ns.oid = pg_proc.pronamespace
    WHERE proname IN ('compute_group_eligibility', 'compute_profile_eligibility')
      AND ns.nspname = 'public'
      AND provolatile != 's'   -- 's' = stable
  ) THEN
    RAISE EXCEPTION '[254] Una función no es STABLE ❌';
  END IF;
  RAISE NOTICE '[254] Ambas funciones: STABLE ✅';

  -- 3. Ambas son SECURITY DEFINER
  IF EXISTS (
    SELECT 1 FROM pg_proc
    JOIN pg_namespace ns ON ns.oid = pg_proc.pronamespace
    WHERE proname IN ('compute_group_eligibility', 'compute_profile_eligibility')
      AND ns.nspname = 'public'
      AND NOT prosecdef   -- prosecdef = true si es SECURITY DEFINER
  ) THEN
    RAISE EXCEPTION '[254] Una función no es SECURITY DEFINER ❌';
  END IF;
  RAISE NOTICE '[254] Ambas funciones: SECURITY DEFINER ✅';

  -- 4. Prueba funcional con UUID inexistente (debe retornar 0 filas sin error)
  SELECT COUNT(*) INTO v_test_group
  FROM public.compute_group_eligibility('00000000-0000-0000-0000-000000000000');
  RAISE NOTICE '[254] compute_group_eligibility con UUID inexistente: 0 filas ✅';

  SELECT COUNT(*) INTO v_test_prof
  FROM public.compute_profile_eligibility('00000000-0000-0000-0000-000000000000');
  RAISE NOTICE '[254] compute_profile_eligibility con UUID inexistente: 0 filas ✅';

  RAISE NOTICE '[254] Ninguna función introduce escrituras — solo lectura ✅';
END;
$$;

SELECT '254_compute_eligibility_functions.sql aplicado correctamente ✅' AS status;
