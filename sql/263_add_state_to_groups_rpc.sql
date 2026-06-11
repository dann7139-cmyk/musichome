-- ============================================================
-- sql/263_add_state_to_groups_rpc.sql
--
-- Agrega el campo `state` al RETURNS de get_groups_ranked_by_city
-- para que el cliente pueda filtrar grupos por país.
--
-- Sin este campo, stateToCountry(g.state) siempre recibe undefined
-- y los grupos de otros países aparecen en el explorador.
-- ============================================================

DROP FUNCTION IF EXISTS public.get_groups_ranked_by_city(TEXT, INT);
DROP FUNCTION IF EXISTS public.get_groups_ranked_by_city(TEXT, TEXT, INT);

CREATE OR REPLACE FUNCTION public.get_groups_ranked_by_city(
  p_city  TEXT,
  p_state TEXT    DEFAULT NULL,
  p_limit INT     DEFAULT 60
)
RETURNS TABLE (
  id                    UUID,
  name                  TEXT,
  genre                 TEXT,
  city                  TEXT,
  state                 TEXT,
  service_cities        JSONB,
  profile_image         TEXT,
  photo_status          TEXT,
  price_from            NUMERIC,
  rating                NUMERIC,
  total_reviews         INT,
  is_verified           BOOLEAN,
  verification_status   TEXT,
  is_active             BOOLEAN,
  puntos_reputacion     INT,
  bid_amount            NUMERIC,
  bid_ends_at           TIMESTAMPTZ,
  boost_score           INT,
  boost_ends_at         TIMESTAMPTZ,
  trust_score           NUMERIC,
  search_penalty        NUMERIC,
  is_high_demand        BOOLEAN,
  recent_completions    INT,
  bid_active            BOOLEAN,
  is_local              BOOLEAN
)
LANGUAGE plpgsql
SECURITY DEFINER STABLE
SET search_path = public
AS $$
DECLARE
  v_city_norm  TEXT := CASE WHEN p_city  IS NULL THEN NULL ELSE normalize_city_name(p_city)  END;
  v_state_norm TEXT := CASE WHEN p_state IS NULL THEN NULL ELSE normalize_state_name(p_state) END;
BEGIN
  RETURN QUERY
  SELECT
    g.id, g.name, g.genre, g.city,
    g.state,
    COALESCE(g.service_cities, '[]'::JSONB),
    g.profile_image, g.photo_status, g.price_from,
    g.rating, g.total_reviews, g.is_verified, g.verification_status,
    g.is_active,
    COALESCE(g.puntos_reputacion, 0)::INT,
    COALESCE(g.bid_amount, 0::NUMERIC),
    g.bid_ends_at,
    COALESCE(g.boost_score, 0)::INT,
    g.boost_ends_at,
    COALESCE(g.trust_score, 0::NUMERIC),
    COALESCE(g.search_penalty, 0::NUMERIC),
    COALESCE(g.is_high_demand, false),
    COALESCE(g.recent_completions, 0)::INT,
    (
      g.bid_ends_at IS NOT NULL
      AND g.bid_ends_at > now()
      AND COALESCE(g.bid_amount, 0) > 0
    ) AS bid_active,
    (v_city_norm IS NULL OR normalize_city_name(g.city) = v_city_norm) AS is_local
  FROM public.groups g
  WHERE g.is_active = true
    -- Filtro de ciudad
    AND (
      v_city_norm IS NULL
      OR normalize_city_name(g.city) = v_city_norm
      OR EXISTS (
        SELECT 1
        FROM jsonb_array_elements_text(COALESCE(g.service_cities, '[]'::JSONB)) sc(city_name)
        WHERE normalize_city_name(sc.city_name) = v_city_norm
      )
    )
    -- Filtro de estado: NULL de estado = grupo nacional (aparece en todos los estados)
    AND (
      v_state_norm IS NULL
      OR g.state IS NULL
      OR normalize_state_name(g.state) = v_state_norm
    )
  ORDER BY
    (v_city_norm IS NULL OR normalize_city_name(g.city) = v_city_norm) DESC,
    (g.bid_ends_at IS NOT NULL AND g.bid_ends_at > now()
      AND COALESCE(g.bid_amount, 0) > 0) DESC,
    COALESCE(g.bid_amount, 0) DESC,
    COALESCE(g.boost_score, 0) DESC,
    COALESCE(g.rating, 0) DESC,
    COALESCE(g.total_reviews, 0) DESC,
    g.created_at DESC
  LIMIT p_limit;
END;
$$;

GRANT EXECUTE ON FUNCTION public.get_groups_ranked_by_city(TEXT, TEXT, INT) TO anon, authenticated;
