-- ROLLBACK de sql/665 — quita el brillo de marco manual por completo.
-- DROP antes de recrear: Postgres no deja cambiar la lista de columnas de
-- un RETURNS TABLE (son OUT params) con CREATE OR REPLACE.
DROP FUNCTION public.get_groups_ranked_by_city(text, text, text, integer);
CREATE OR REPLACE FUNCTION public.get_groups_ranked_by_city(p_city text, p_state text DEFAULT NULL::text, p_country text DEFAULT NULL::text, p_limit integer DEFAULT 50)
 RETURNS TABLE(id uuid, name text, genre text, city text, state text, service_cities jsonb, profile_image text, photo_status text, price_from numeric, rating numeric, total_reviews integer, is_verified boolean, verification_status text, is_active boolean, puntos_reputacion integer, bid_amount numeric, bid_ends_at timestamp with time zone, boost_score integer, boost_ends_at timestamp with time zone, trust_score numeric, search_penalty numeric, is_high_demand boolean, recent_completions integer, bid_active boolean, is_local boolean, is_plus_active boolean)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_city_norm    TEXT := CASE WHEN p_city    IS NULL THEN NULL ELSE normalize_city_name(p_city)     END;
  v_state_norm   TEXT := CASE WHEN p_state   IS NULL THEN NULL ELSE normalize_state_name(p_state)   END;
  v_country_norm TEXT := CASE WHEN p_country IS NULL THEN NULL ELSE normalize_state_name(p_country) END;
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
    (v_city_norm IS NULL OR normalize_city_name(g.city) = v_city_norm) AS is_local,
    (COALESCE(g.is_plus_active, false)
      AND (g.plus_expires_at IS NULL OR g.plus_expires_at > now())) AS is_plus_active
  FROM public.groups g
  WHERE g.is_active = true
    AND (
      v_city_norm IS NULL
      OR normalize_city_name(g.city) = v_city_norm
      OR EXISTS (
        SELECT 1
        FROM jsonb_array_elements_text(COALESCE(g.service_cities, '[]'::JSONB)) sc(city_name)
        WHERE normalize_city_name(sc.city_name) = v_city_norm
      )
    )
    AND (
      v_state_norm IS NULL
      OR g.state IS NULL
      OR normalize_state_name(g.state) = v_state_norm
    )
    AND (
      v_country_norm IS NULL
      OR g.country IS NULL
      OR normalize_state_name(g.country) = v_country_norm
    )
  ORDER BY
    (g.visibility_penalty_until IS NOT NULL AND g.visibility_penalty_until > now()) ASC,
    (v_city_norm IS NULL OR normalize_city_name(g.city) = v_city_norm) DESC,
    (g.bid_ends_at IS NOT NULL AND g.bid_ends_at > now()
      AND COALESCE(g.bid_amount, 0) > 0) DESC,
    COALESCE(g.bid_amount, 0) DESC,
    COALESCE(g.boost_score, 0) DESC,
    (COALESCE(g.is_plus_active, false)
      AND (g.plus_expires_at IS NULL OR g.plus_expires_at > now())) DESC,
    COALESCE(g.rating, 0) DESC,
    COALESCE(g.total_reviews, 0) DESC,
    g.created_at DESC
  LIMIT p_limit;
END;
$function$;

DROP FUNCTION IF EXISTS public.admin_set_group_highlight(uuid, boolean);

ALTER TABLE public.groups DROP COLUMN IF EXISTS admin_highlight;
