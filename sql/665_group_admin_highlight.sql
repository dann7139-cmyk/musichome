-- sql/665 — "brillo de marco" manual para un grupo en el Explorador
--
-- Petición real (2026-09-17): "quiero otro botón que si lo activo salga
-- un efecto en el marco del grupo... en el explorador donde ven todos los
-- grupos hay cuatro filas... si activo ese grupo brillará más pero el
-- puro marco. Quiero que lo hagas con Miguel Aguilar y su Grupo Estilo
-- para ver cómo se ve."
--
-- Puramente cosmético y manual — INDEPENDIENTE del sistema de patrocinio
-- real (is_sponsored/boost_score/bid, que ya tiene su propia lógica de
-- cupos pagados por categoría/estado). admin_highlight es solo un
-- interruptor visual que Daniel prende/apaga a mano desde el admin, sin
-- tocar cupos ni dinero.
--
-- Sandbox probado con BEGIN/ROLLBACK antes de aplicar en real.

ALTER TABLE public.groups
  ADD COLUMN IF NOT EXISTS admin_highlight boolean NOT NULL DEFAULT false;

-- RPC para prender/apagar — mismo patrón de guard que admin_grant_plus.
CREATE OR REPLACE FUNCTION public.admin_set_group_highlight(p_group_id uuid, p_on boolean)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_caller_role TEXT;
  v_found       BOOLEAN;
BEGIN
  SELECT role INTO v_caller_role FROM public.profiles WHERE id = auth.uid();
  IF v_caller_role IS DISTINCT FROM 'admin' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'Acceso denegado');
  END IF;

  UPDATE public.groups SET admin_highlight = p_on WHERE id = p_group_id;
  GET DIAGNOSTICS v_found = ROW_COUNT;
  IF v_found = 0 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'Grupo no encontrado');
  END IF;

  RETURN jsonb_build_object('ok', true, 'admin_highlight', p_on);
END;
$function$;

-- get_groups_ranked_by_city (Explorador) — agrega admin_highlight al final
-- de RETURNS TABLE para no romper el orden de columnas existente.
-- Postgres no deja cambiar la lista de columnas de un RETURNS TABLE con
-- CREATE OR REPLACE (son OUT params) — hay que DROP primero.
DROP FUNCTION public.get_groups_ranked_by_city(text, text, text, integer);
CREATE OR REPLACE FUNCTION public.get_groups_ranked_by_city(p_city text, p_state text DEFAULT NULL::text, p_country text DEFAULT NULL::text, p_limit integer DEFAULT 50)
 RETURNS TABLE(id uuid, name text, genre text, city text, state text, service_cities jsonb, profile_image text, photo_status text, price_from numeric, rating numeric, total_reviews integer, is_verified boolean, verification_status text, is_active boolean, puntos_reputacion integer, bid_amount numeric, bid_ends_at timestamp with time zone, boost_score integer, boost_ends_at timestamp with time zone, trust_score numeric, search_penalty numeric, is_high_demand boolean, recent_completions integer, bid_active boolean, is_local boolean, is_plus_active boolean, admin_highlight boolean)
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
    -- 🏆 Plus EFECTIVO (activo Y no vencido)
    (COALESCE(g.is_plus_active, false)
      AND (g.plus_expires_at IS NULL OR g.plus_expires_at > now())) AS is_plus_active,
    -- ✨ sql/665 — brillo de marco manual, puramente cosmético
    COALESCE(g.admin_highlight, false) AS admin_highlight
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
    -- Filtro país (de sql/361): g.country NULL = legacy → visible en todos
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

-- Demo pedida por el usuario: prender el brillo en Miguel Aguilar y su
-- Grupo Estilo para verlo en el Explorador ahora mismo.
UPDATE public.groups SET admin_highlight = true
WHERE id = 'abf37e26-7076-4ff3-a68b-71e21a441fd6';
