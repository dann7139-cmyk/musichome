-- ============================================================
-- sql/326_add_is_plus_active_to_rpcs.sql
--
-- Agrega is_plus_active a dos RPCs que lo omitían, para que
-- el badge Plus sea consistente en todas las pantallas.
--
-- 1. get_active_recommendations  → agrega is_plus_active BOOLEAN
-- 2. get_my_job_invitations       → agrega is_plus_active al objeto 'group'
--
-- Backward compatible: solo se añaden campos nuevos.
-- DROP FUNCTION IF EXISTS necesario por cambio en RETURNS TABLE (#1).
-- ============================================================

-- ── 1. get_active_recommendations ────────────────────────────────────────────
-- Última versión en sql/175. Agrega is_plus_active al RETURNS TABLE y SELECT.

DROP FUNCTION IF EXISTS public.get_active_recommendations(TEXT, TEXT, INTEGER);

CREATE OR REPLACE FUNCTION public.get_active_recommendations(
  p_city   TEXT    DEFAULT NULL,
  p_state  TEXT    DEFAULT NULL,
  p_limit  INTEGER DEFAULT 10
)
RETURNS TABLE (
  id             UUID,
  name           TEXT,
  genre          TEXT,
  city           TEXT,
  description    TEXT,
  price_from     NUMERIC,
  rating         NUMERIC,
  total_reviews  INT,
  is_verified    BOOLEAN,
  is_plus_active BOOLEAN,
  profile_image  TEXT,
  amount         NUMERIC,
  ends_at        TIMESTAMPTZ
)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public
AS $$
  SELECT
    g.id, g.name, g.genre, g.city, g.description,
    g.price_from, g.rating, g.total_reviews, g.is_verified,
    (g.is_plus_active AND (g.plus_expires_at IS NULL OR g.plus_expires_at > NOW())) AS is_plus_active,
    g.profile_image,
    ro.amount, ro.ends_at
  FROM public.recommendation_orders ro
  JOIN public.groups g ON g.id = ro.group_id
  WHERE ro.status  = 'paid'
    AND ro.starts_at <= NOW()
    AND ro.ends_at   >  NOW()
    AND g.is_active  = TRUE
    AND (p_city  IS NULL OR LOWER(TRIM(g.city))  = LOWER(TRIM(p_city)))
    AND (
      p_state IS NULL
      OR g.state IS NULL
      OR LOWER(TRIM(g.state)) = LOWER(TRIM(p_state))
    )
  ORDER BY
    COALESCE(ro.bid_amount, ro.amount) DESC,
    ro.ends_at   DESC,
    ro.starts_at DESC
  LIMIT p_limit;
$$;

GRANT EXECUTE ON FUNCTION public.get_active_recommendations(TEXT, TEXT, INTEGER)
  TO anon, authenticated;


-- ── 2. get_my_job_invitations ─────────────────────────────────────────────────
-- Última versión en sql/250. Agrega is_plus_active al objeto JSON 'group'.
-- No cambia firma (RETURNS SETOF json) → CREATE OR REPLACE sin DROP.

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
          'event_time', res.event_time,
          'package', CASE WHEN pk.id IS NOT NULL THEN json_build_object(
            'name',           pk.name,
            'duration_hours', pk.duration_hours
          ) ELSE NULL END
        ))
        FROM public.reservations res
        LEFT JOIN public.packages pk ON pk.id = res.package_id
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


SELECT '326_add_is_plus_active_to_rpcs.sql ejecutado ✅' AS status;
