-- ============================================================
-- sql/564_fix_job_invitations_and_similar_groups.sql
--
-- Dos bugs encontrados haciendo QA en la cuenta de talento:
--
-- 1. get_my_job_invitations() — al abrir "Empleos" tronaba en consola:
--      relation "public.packages" does not exist (42P01)
--    La tabla `packages` fue erradicada del proyecto (ver
--    project_packages_eradicated.md) pero esta función (sql/326) se
--    quedó con un LEFT JOIN a esa tabla vía reservations.package_id,
--    columna que tampoco existe ya. Se reemplaza por hours_count,
--    que es como el resto de la app ya deriva la duración de una
--    reserva (JobBoardScreen.tsx ya esperaba res.hours_count).
--
-- 2. get_similar_groups() — nunca funcionó (silenciosamente, el
--    frontend no reporta el error de este RPC): "column reference
--    genre is ambiguous". Los nombres de columna del RETURNS TABLE
--    (group_id, name, genre, city, average_rating, ...) quedan
--    declarados como variables automáticas dentro de la función en
--    PL/pgSQL, y colisionan con las columnas del SELECT INTO inicial
--    (genre, city, average_rating) al no estar calificadas con alias.
--    Se corrige calificando esas columnas con el alias de la tabla.
--
-- Ambas son SECURITY DEFINER, solo lectura — sin riesgo de datos.
-- Firma sin cambios en ninguna de las dos → CREATE OR REPLACE directo,
-- sin necesidad de DROP FUNCTION.
-- ============================================================

-- Nota: la versión desplegada de ambas funciones ya se verificó a mano
-- con pg_get_functiondef() antes de escribir este archivo — coincide
-- exactamente con sql/326 (job invitations) y con la definición vigente
-- de get_similar_groups mostrada más abajo. Firma sin cambios en
-- ninguna de las dos → CREATE OR REPLACE directo.

-- ── 1. get_my_job_invitations — quita el JOIN muerto a packages ──────────────

CREATE OR REPLACE FUNCTION public.get_my_job_invitations()
RETURNS SETOF json
LANGUAGE plpgsql
SECURITY DEFINER
STABLE
SET search_path = public
AS $$
BEGIN
  RETURN QUERY
  SELECT json_build_object(
    'id',                      ji.id,
    'event_id',                ji.event_id,
    'proposed_payment_amount', ji.proposed_payment_amount,
    'message',                 ji.message,
    'status',                  ji.status,
    'created_at',              ji.created_at,

    'group', CASE WHEN g.id IS NOT NULL THEN json_build_object(
      'id',            g.id,
      'name',          g.name,
      'genre',         g.genre,
      'profile_image', g.profile_image,
      'rating',        g.rating,
      'total_reviews', g.total_reviews,
      'members_count', g.members_count,
      'is_verified',      g.is_verified,
      'is_plus_active',   (g.is_plus_active AND (g.plus_expires_at IS NULL OR g.plus_expires_at > NOW())),
      'created_at',       g.created_at,
      'completed_events', COALESCE((
        SELECT COUNT(*)::int
        FROM public.reservations r
        WHERE r.group_id = g.id
          AND r.status = 'completed'
      ), 0)
    ) ELSE NULL END,

    'event', CASE WHEN ev.id IS NOT NULL THEN json_build_object(
      'event_date',  ev.event_date,
      'address',     ev.address,
      'reservations', COALESCE((
        SELECT json_agg(json_build_object(
          'event_time',  res.event_time,
          'hours_count', res.hours_count
        ))
        FROM public.reservations res
        WHERE res.event_id = ji.event_id
      ), '[]'::json)
    ) ELSE NULL END
  )
  FROM public.job_invitations ji
  LEFT JOIN public.groups  g  ON g.id  = ji.group_id
  LEFT JOIN public.events  ev ON ev.id = ji.event_id
  WHERE ji.invited_user_id = auth.uid()
  ORDER BY ji.created_at DESC;
END;
$$;

GRANT EXECUTE ON FUNCTION public.get_my_job_invitations() TO authenticated;

-- ── 2. get_similar_groups — quita la ambigüedad de nombres ───────────────────

CREATE OR REPLACE FUNCTION public.get_similar_groups(p_group_id uuid, p_limit integer DEFAULT 6)
RETURNS TABLE(group_id uuid, name text, genre text, city text, average_rating numeric, total_reviews integer, ranking_score numeric, badges text[], availability text, similarity_score numeric)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  v_source RECORD;
BEGIN
  -- Cargar datos del grupo de referencia — columnas calificadas con
  -- alias (g0.) para no chocar con los nombres de columna del
  -- RETURNS TABLE (genre, city, average_rating), que PL/pgSQL declara
  -- como variables automáticas visibles en toda la función.
  SELECT g0.genre, g0.city, g0.average_rating
  INTO   v_source
  FROM   public.groups g0
  WHERE  g0.id = p_group_id;

  IF NOT FOUND THEN
    RETURN;
  END IF;

  RETURN QUERY
  SELECT
    g.id,
    g.name,
    g.genre,
    g.city,
    g.average_rating,
    g.total_reviews,
    g.ranking_score,
    g.badges,
    COALESCE(g.availability, 'available'),
    ROUND((
      CASE WHEN LOWER(TRIM(g.city)) = LOWER(TRIM(v_source.city)) THEN 4.0 ELSE 0.0 END
      + CASE
          WHEN COALESCE(g.average_rating, 0) >= 4.5 THEN 3.0
          WHEN COALESCE(g.average_rating, 0) >= 4.0 THEN 2.0
          WHEN COALESCE(g.average_rating, 0) >= 3.0 THEN 1.0
          ELSE 0.0
        END
      + (COALESCE(g.ranking_score, 0) / 5.0 * 3.0)
    )::NUMERIC, 2)                                       AS similarity_score
  FROM public.groups g
  WHERE g.id        != p_group_id
    AND g.genre      = v_source.genre
    AND g.is_active  = TRUE
    AND COALESCE(g.availability, 'available') != 'offline'
    AND COALESCE(g.average_rating, 0) >= 3.0
  ORDER BY
    similarity_score DESC,
    g.ranking_score  DESC
  LIMIT p_limit;
END;
$$;

GRANT EXECUTE ON FUNCTION public.get_similar_groups(uuid, integer) TO anon, authenticated;

SELECT '564_fix_job_invitations_and_similar_groups.sql ejecutado ✅' AS status;
