-- ============================================================
-- sql/245_search_talents_allow_group_owners.sql
--
-- FIX: los dueños de grupo (role='group') que tienen un perfil
-- de talento visible ahora aparecen en la búsqueda de talentos.
--
-- Antes: AND p.role <> 'group' los excluía completamente.
-- Ahora: se elimina ese filtro. El filtro de integrantes ya
--   aceptados permanentes (NOT EXISTS job_invitations) sigue
--   activo — solo excluye a quienes ya son miembros de otro grupo.
--
-- Misma firma (TEXT, TEXT, DOUBLE PRECISION, DOUBLE PRECISION).
-- CREATE OR REPLACE — no se necesita DROP.
-- ============================================================

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
    -- Excluir talentos que ya son integrantes permanentes de un grupo
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
    CASE WHEN jbp.lat IS NOT NULL AND p_lat IS NOT NULL THEN 0 ELSE 1 END ASC,
    CASE
      WHEN jbp.lat IS NOT NULL AND p_lat IS NOT NULL
        THEN haversine_km(jbp.lat, jbp.lng, p_lat, p_lng)
      ELSE 99999.0
    END ASC,
    jbp.availability_status ASC,
    jbp.rating              DESC,
    jbp.total_jobs          DESC;
$$;

GRANT EXECUTE ON FUNCTION public.search_talents(TEXT, TEXT, DOUBLE PRECISION, DOUBLE PRECISION)
  TO authenticated, service_role;

-- Verificación
DO $$
DECLARE
  v_count INT;
BEGIN
  SELECT COUNT(*) INTO v_count
  FROM public.job_board_profiles jbp
  JOIN public.profiles p ON p.id = jbp.user_id
  WHERE jbp.is_visible = TRUE
    AND p.role = 'group';

  RAISE NOTICE '[245] Dueños de grupo con perfil de talento visible: %', v_count;
  RAISE NOTICE '[245] search_talents actualizado — dueños de grupo ahora aparecen ✅';
END;
$$;

SELECT '245_search_talents_allow_group_owners.sql: dueños de grupo visibles en búsqueda ✅' AS status;
