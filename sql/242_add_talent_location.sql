-- ============================================================
-- sql/242_add_talent_location.sql
--
-- Agrega coordenadas a job_board_profiles y actualiza search_talents
-- para devolver distance_km calculada con haversine_km (ya existe en DB).
--
-- Backward compatible:
--   - lat/lng son NULLABLE → talentos existentes quedan sin coords.
--   - search_talents sin parámetros sigue funcionando (p_lat/p_lng DEFAULT NULL).
--   - distance_km devuelto como NULL cuando faltan coords.
--   - Ordenamiento: con coords primero por distancia, sin coords por rating/jobs.
--
-- IMPORTANTE: DROP de la firma anterior (TEXT, TEXT) antes de CREATE OR REPLACE
--   porque PostgreSQL trata firmas distintas como funciones distintas y
--   llamar con 0 args sería ambiguo si ambas coexistieran.
--
-- Conserva todos los filtros de sql/25:
--   - p.role <> 'group'                                (no mostrar dueños de grupo)
--   - NOT EXISTS (job_invitations accepted membership)  (no mostrar integrantes activos)
--
-- No toca: RLS, pagos, timers, reservas, Stripe, realtime.
-- ============================================================

-- ── 1. Agregar columnas de ubicación a job_board_profiles ────────────────────

ALTER TABLE public.job_board_profiles
  ADD COLUMN IF NOT EXISTS lat DOUBLE PRECISION DEFAULT NULL,
  ADD COLUMN IF NOT EXISTS lng DOUBLE PRECISION DEFAULT NULL;

-- Índice parcial para búsquedas geoespaciales (solo filas con coords)
CREATE INDEX IF NOT EXISTS idx_jbp_lat_lng
  ON public.job_board_profiles (lat, lng)
  WHERE lat IS NOT NULL AND lng IS NOT NULL;

-- ── 2. Eliminar firma anterior para evitar ambigüedad de sobrecarga ───────────
-- La firma (TEXT, TEXT) devuelve 10 columnas; la nueva (TEXT, TEXT, DOUBLE, DOUBLE)
-- devuelve 11 (agrega distance_km). Si coexisten, llamar sin args falla con
-- "function search_talents() is not unique".
DROP FUNCTION IF EXISTS public.search_talents(TEXT, TEXT);

-- ── 3. Crear RPC search_talents con soporte de distancia ─────────────────────

CREATE OR REPLACE FUNCTION public.search_talents(
  p_role         TEXT             DEFAULT NULL,
  p_availability TEXT             DEFAULT NULL,
  p_lat          DOUBLE PRECISION DEFAULT NULL,
  p_lng          DOUBLE PRECISION DEFAULT NULL
)
RETURNS TABLE (
  id                  UUID,
  user_id             UUID,
  full_name           TEXT,
  avatar_url          TEXT,
  instrument_or_role  TEXT,
  bio                 TEXT,
  experience_years    INTEGER,
  rating              NUMERIC,
  total_jobs          INTEGER,
  availability_status TEXT,
  distance_km         NUMERIC,
  created_at          TIMESTAMP WITH TIME ZONE
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT
    jbp.id,
    jbp.user_id,
    p.full_name,
    p.avatar_url,
    jbp.instrument_or_role,
    jbp.bio,
    jbp.experience_years,
    jbp.rating::NUMERIC,
    jbp.total_jobs,
    jbp.availability_status,
    CASE
      WHEN jbp.lat IS NOT NULL AND p_lat IS NOT NULL
        THEN ROUND(haversine_km(jbp.lat, jbp.lng, p_lat, p_lng)::NUMERIC, 1)
      ELSE NULL
    END AS distance_km,
    jbp.created_at
  FROM public.job_board_profiles jbp
  JOIN public.profiles p ON p.id = jbp.user_id
  WHERE jbp.is_visible = TRUE
    -- Excluir dueños de grupos (conservado de sql/25)
    AND p.role <> 'group'
    -- Excluir talentos que ya son integrantes permanentes de un grupo (conservado de sql/25)
    AND NOT EXISTS (
      SELECT 1
      FROM public.job_invitations jinv
      WHERE jinv.invited_user_id = jbp.user_id
        AND jinv.status          = 'accepted'
        AND jinv.event_id        IS NULL
    )
    AND (p_role         IS NULL OR jbp.instrument_or_role ILIKE '%' || p_role || '%')
    AND (p_availability IS NULL OR jbp.availability_status = p_availability)
  ORDER BY
    -- Talentos con distancia calculada primero
    CASE WHEN jbp.lat IS NOT NULL AND p_lat IS NOT NULL THEN 0 ELSE 1 END ASC,
    -- Por distancia ascendente (null-safe: sin coords van al final con valor 99999)
    CASE
      WHEN jbp.lat IS NOT NULL AND p_lat IS NOT NULL
        THEN haversine_km(jbp.lat, jbp.lng, p_lat, p_lng)
      ELSE 99999.0
    END ASC,
    -- Desempate dentro de mismo grupo de distancia
    jbp.availability_status ASC,
    jbp.rating              DESC,
    jbp.total_jobs          DESC;
$$;

GRANT EXECUTE ON FUNCTION public.search_talents(TEXT, TEXT, DOUBLE PRECISION, DOUBLE PRECISION)
  TO authenticated, service_role;

-- ── Verificación ──────────────────────────────────────────────────────────────
DO $$
DECLARE
  v_cols TEXT;
  v_count INT;
BEGIN
  -- Verificar columnas lat/lng
  SELECT string_agg(column_name, ', ' ORDER BY ordinal_position)
  INTO   v_cols
  FROM   information_schema.columns
  WHERE  table_schema = 'public'
    AND  table_name   = 'job_board_profiles'
    AND  column_name  IN ('lat', 'lng');

  IF v_cols LIKE '%lat%' AND v_cols LIKE '%lng%' THEN
    RAISE NOTICE '[242] job_board_profiles.lat/lng presentes ✅';
  ELSE
    RAISE WARNING '[242] ALERTA: columnas lat/lng no encontradas';
  END IF;

  -- Verificar que NO existe la firma antigua (TEXT, TEXT)
  SELECT COUNT(*) INTO v_count
  FROM pg_proc p
  JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public'
    AND p.proname = 'search_talents'
    AND p.pronargs = 2;

  IF v_count = 0 THEN
    RAISE NOTICE '[242] Firma antigua search_talents(TEXT,TEXT) eliminada ✅';
  ELSE
    RAISE WARNING '[242] ALERTA: firma antigua search_talents(TEXT,TEXT) sigue presente';
  END IF;

  -- Verificar que la nueva firma (TEXT, TEXT, DOUBLE, DOUBLE) existe
  SELECT COUNT(*) INTO v_count
  FROM pg_proc p
  JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public'
    AND p.proname = 'search_talents'
    AND p.pronargs = 4;

  IF v_count = 1 THEN
    RAISE NOTICE '[242] Nueva firma search_talents(TEXT,TEXT,DOUBLE,DOUBLE) creada ✅';
  ELSE
    RAISE WARNING '[242] ALERTA: nueva firma search_talents no encontrada';
  END IF;
END;
$$;

SELECT '242_add_talent_location.sql: lat/lng + search_talents con distancia y filtros conservados ✅' AS status;
