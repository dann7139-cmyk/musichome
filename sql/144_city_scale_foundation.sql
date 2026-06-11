-- ════════════════════════════════════════════════════════════════════════════
-- 144_city_scale_foundation.sql
-- Fundamentos para escalar a múltiples ciudades como mercados independientes.
--
-- ARQUITECTURA:
--   · Cada ciudad es un mini-mercado: ranking, anuncios, demanda y bids son
--     locales a la ciudad del usuario.
--   · Anuncios nacionales: cupo propio, no compiten con ciudad.
--   · Si el usuario no tiene ciudad: solo ve anuncios nacionales.
--   · City gate: update_my_city() permite forzar selección en la app.
--
-- NUEVAS FUNCIONES:
--   · get_active_cities()              — lista de ciudades para selector
--   · update_my_city(p_city)           — guarda ciudad en profiles del usuario
--   · get_city_demand_score(p_city)    — métricas de demanda por ciudad
--   · get_groups_ranked_by_city(...)   — grupos rankeados dentro de su ciudad
--
-- NO modifica funciones existentes (get_active_banner_ads, place_bid, etc.)
-- Ejecutar DESPUÉS de 143_ad_limits_per_city.sql
-- ════════════════════════════════════════════════════════════════════════════


-- ── 1. get_active_cities() ────────────────────────────────────────────────────
-- Lista de ciudades disponibles para el selector de ciudad.
-- Incluye conteo de grupos activos y nivel de demanda.

DROP FUNCTION IF EXISTS public.get_active_cities();
CREATE OR REPLACE FUNCTION public.get_active_cities()
RETURNS TABLE (
  id           UUID,
  name         TEXT,
  state_name   TEXT,
  country_name TEXT,
  lat          NUMERIC,
  lng          NUMERIC,
  group_count  BIGINT,
  demand_level TEXT
)
LANGUAGE plpgsql
SECURITY DEFINER STABLE
SET search_path = public
AS $$
BEGIN
  RETURN QUERY
  SELECT
    c.id,
    c.name,
    COALESCE(s.name, '') AS state_name,
    COALESCE(co.name,  '') AS country_name,
    COALESCE(c.lat,  0)  AS lat,
    COALESCE(c.lng,  0)  AS lng,
    COUNT(g.id)          AS group_count,
    CASE
      WHEN COUNT(g.id) >= 10 THEN 'high'
      WHEN COUNT(g.id) >= 3  THEN 'normal'
      ELSE                        'new'
    END                  AS demand_level
  FROM   public.cities c
  LEFT JOIN public.states   s  ON s.id  = c.state_id
  LEFT JOIN public.countries co ON co.id = c.country_id
  LEFT JOIN public.groups    g  ON g.city ILIKE c.name
                                AND g.is_active = true
  WHERE  c.is_active = true
  GROUP BY c.id, c.name, s.name, co.name, c.lat, c.lng
  ORDER BY group_count DESC, c.name ASC;
END;
$$;

GRANT EXECUTE ON FUNCTION public.get_active_cities() TO anon, authenticated;


-- ── 2. update_my_city(p_city TEXT) ───────────────────────────────────────────
-- Actualiza la ciudad del perfil del usuario autenticado.
-- Llamar desde la pantalla CitySelectScreen después de que el usuario elija.

DROP FUNCTION IF EXISTS public.update_my_city(TEXT);
CREATE OR REPLACE FUNCTION public.update_my_city(p_city TEXT)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid UUID := auth.uid();
BEGIN
  IF v_uid IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_authenticated');
  END IF;

  IF p_city IS NULL OR trim(p_city) = '' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'city_required');
  END IF;

  UPDATE public.profiles
  SET    city       = trim(p_city),
         updated_at = now()
  WHERE  id = v_uid;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'profile_not_found');
  END IF;

  RETURN jsonb_build_object('ok', true, 'city', trim(p_city));
END;
$$;

GRANT EXECUTE ON FUNCTION public.update_my_city(TEXT) TO authenticated;


-- ── 3. get_city_demand_score(p_city TEXT) ────────────────────────────────────
-- Calcula el nivel de demanda de una ciudad basado en actividad real:
-- anuncios activos, grupos patrocinados, bids/boosts activos, reservas recientes.
-- Usado para mostrar "Alta demanda en tu ciudad" en la app.

DROP FUNCTION IF EXISTS public.get_city_demand_score(TEXT);
CREATE OR REPLACE FUNCTION public.get_city_demand_score(p_city TEXT)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER STABLE
SET search_path = public
AS $$
DECLARE
  v_banners      INT := 0;
  v_sponsored    INT := 0;
  v_bids         INT := 0;
  v_boosts       INT := 0;
  v_reservations INT := 0;
  v_groups       INT := 0;
  v_score        INT;
  v_level        TEXT;
BEGIN
  IF p_city IS NULL OR trim(p_city) = '' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'city_required');
  END IF;

  -- Anuncios banner activos que incluyen esta ciudad
  SELECT COUNT(*) INTO v_banners
  FROM   public.advertisements
  WHERE  status = 'active'
    AND  type   = 'banner_home'
    AND  ends_at > now()
    AND  (
      target_location_type IS NULL
      OR target_location_type = 'national'
      OR (target_locations IS NOT NULL
          AND target_locations @> jsonb_build_array(p_city))
    );

  -- Grupos patrocinados activos en esta ciudad
  SELECT COUNT(*) INTO v_sponsored
  FROM   public.sponsored_groups sg
  JOIN   public.groups g ON g.id = sg.group_id
  WHERE  sg.is_active = true
    AND  sg.ends_at   > now()
    AND  g.city       ILIKE p_city;

  -- Grupos con bid activo en esta ciudad
  SELECT COUNT(*) INTO v_bids
  FROM   public.groups
  WHERE  city       ILIKE p_city
    AND  bid_ends_at > now()
    AND  COALESCE(bid_amount, 0) > 0;

  -- Grupos con boost activo en esta ciudad
  SELECT COUNT(*) INTO v_boosts
  FROM   public.groups
  WHERE  city        ILIKE p_city
    AND  boost_ends_at > now()
    AND  COALESCE(boost_score, 0) > 0;

  -- Reservas recientes (últimos 30 días) en esta ciudad
  SELECT COUNT(*) INTO v_reservations
  FROM   public.reservations r
  JOIN   public.groups       g ON g.id = r.group_id
  WHERE  g.city    ILIKE p_city
    AND  r.created_at > now() - INTERVAL '30 days'
    AND  r.status NOT IN ('cancelled', 'expired');

  -- Grupos activos totales en la ciudad
  SELECT COUNT(*) INTO v_groups
  FROM   public.groups
  WHERE  city      ILIKE p_city
    AND  is_active = true;

  -- Score ponderado
  v_score := (v_banners * 15)
           + (v_sponsored * 10)
           + (v_bids      *  8)
           + (v_boosts    *  5)
           + (v_reservations * 2)
           + (v_groups    *  1);

  v_level := CASE
    WHEN v_score >= 60 THEN 'very_high'
    WHEN v_score >= 25 THEN 'high'
    WHEN v_score >= 5  THEN 'normal'
    ELSE                    'new'
  END;

  RETURN jsonb_build_object(
    'ok',                  true,
    'city',                p_city,
    'active_banners',      v_banners,
    'active_sponsored',    v_sponsored,
    'active_bids',         v_bids,
    'active_boosts',       v_boosts,
    'recent_reservations', v_reservations,
    'active_groups',       v_groups,
    'demand_score',        v_score,
    'demand_level',        v_level
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.get_city_demand_score(TEXT) TO anon, authenticated;


-- ── 4. get_groups_ranked_by_city(p_city, p_limit) ───────────────────────────
-- Devuelve grupos rankeados DENTRO de su ciudad.
-- Ranking solo compara grupos de la misma ciudad: bid_amount, boost_score,
-- rating y reputación no se mezclan entre ciudades.
--
-- Orden:
--   1. bid activo > sin bid
--   2. bid_amount DESC (mayor puja primero, dentro de la misma ciudad)
--   3. boost_score DESC
--   4. rating DESC
--   5. total_reviews DESC
--   6. created_at DESC (desempate)
--
-- Fallback: si p_city es NULL → devuelve todos los grupos activos ordenados
-- globalmente (para usuarios sin ciudad aún no bloqueados en onboarding).

DROP FUNCTION IF EXISTS public.get_groups_ranked_by_city(TEXT, INT);
CREATE OR REPLACE FUNCTION public.get_groups_ranked_by_city(
  p_city  TEXT,
  p_limit INT DEFAULT 60
)
RETURNS TABLE (
  id                    UUID,
  name                  TEXT,
  genre                 TEXT,
  city                  TEXT,
  profile_image         TEXT,
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
  bid_active            BOOLEAN
)
LANGUAGE plpgsql
SECURITY DEFINER STABLE
SET search_path = public
AS $$
BEGIN
  RETURN QUERY
  SELECT
    g.id,
    g.name,
    g.genre,
    g.city,
    g.profile_image,
    g.rating,
    g.total_reviews,
    g.is_verified,
    g.verification_status,
    g.is_active,
    COALESCE(g.puntos_reputacion, 0)::INT,
    COALESCE(g.bid_amount,   0::NUMERIC),
    g.bid_ends_at,
    COALESCE(g.boost_score,  0)::INT,
    g.boost_ends_at,
    COALESCE(g.trust_score,  0::NUMERIC),
    COALESCE(g.search_penalty, 0::NUMERIC),
    COALESCE(g.is_high_demand, false),
    COALESCE(g.recent_completions, 0)::INT,
    -- bid_active: solo cuenta si hay amount > 0 y no expiró
    (
      g.bid_ends_at IS NOT NULL
      AND g.bid_ends_at > now()
      AND COALESCE(g.bid_amount, 0) > 0
    ) AS bid_active
  FROM public.groups g
  WHERE g.is_active = true
    AND (
      p_city IS NULL
      OR g.city ILIKE p_city
    )
  ORDER BY
    -- 1. bid activo primero
    (g.bid_ends_at IS NOT NULL AND g.bid_ends_at > now()
      AND COALESCE(g.bid_amount, 0) > 0) DESC,
    -- 2. monto de bid (solo importa dentro de la ciudad)
    COALESCE(g.bid_amount, 0) DESC,
    -- 3. boost de visibilidad
    COALESCE(g.boost_score, 0) DESC,
    -- 4. calidad del grupo
    COALESCE(g.rating, 0) DESC,
    COALESCE(g.total_reviews, 0) DESC,
    -- 5. desempate
    g.created_at DESC
  LIMIT p_limit;
END;
$$;

GRANT EXECUTE ON FUNCTION public.get_groups_ranked_by_city(TEXT, INT) TO anon, authenticated;


-- ── 5. Trigger: verificar ciudad requerida en grupos ─────────────────────────
-- Al insertar o actualizar un grupo, valida que el campo city no esté vacío.
-- Previene datos sin ciudad que romperían la segmentación.

CREATE OR REPLACE FUNCTION public.validate_group_city()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  IF NEW.city IS NULL OR trim(NEW.city) = '' THEN
    RAISE EXCEPTION 'La ciudad del grupo es obligatoria (campo city vacío).'
      USING ERRCODE = 'check_violation';
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_validate_group_city ON public.groups;
CREATE TRIGGER trg_validate_group_city
  BEFORE INSERT OR UPDATE OF city ON public.groups
  FOR EACH ROW EXECUTE FUNCTION public.validate_group_city();


-- ── 6. Vista: city_demand_overview (solo admin) ───────────────────────────────
-- Resumen de demanda por ciudad para el panel admin.
-- Muestra métricas clave para tomar decisiones de expansión.

DROP VIEW IF EXISTS public.city_demand_overview;
CREATE VIEW public.city_demand_overview AS
SELECT
  g.city,
  COUNT(DISTINCT g.id)                                           AS total_groups,
  COUNT(DISTINCT g.id) FILTER (WHERE g.is_active = true)        AS active_groups,
  COUNT(DISTINCT g.id) FILTER (
    WHERE g.bid_ends_at > now() AND COALESCE(g.bid_amount, 0) > 0
  )                                                              AS groups_with_bid,
  COUNT(DISTINCT g.id) FILTER (
    WHERE g.boost_ends_at > now() AND COALESCE(g.boost_score, 0) > 0
  )                                                              AS groups_with_boost,
  COALESCE(SUM(g.bid_amount) FILTER (
    WHERE g.bid_ends_at > now()
  ), 0)                                                          AS total_bid_revenue_active,
  COUNT(DISTINCT r.id) FILTER (
    WHERE r.created_at > now() - INTERVAL '30 days'
    AND r.status NOT IN ('cancelled', 'expired')
  )                                                              AS reservations_last_30d,
  ROUND(AVG(g.rating), 2)                                        AS avg_rating,
  -- Demand score simplificado
  (COUNT(DISTINCT g.id) FILTER (
    WHERE g.bid_ends_at > now() AND COALESCE(g.bid_amount, 0) > 0
  ) * 8
  + COUNT(DISTINCT g.id) FILTER (
    WHERE g.boost_ends_at > now() AND COALESCE(g.boost_score, 0) > 0
  ) * 5
  + COUNT(DISTINCT r.id) FILTER (
    WHERE r.created_at > now() - INTERVAL '30 days'
    AND r.status NOT IN ('cancelled', 'expired')
  ) * 2)                                                         AS demand_score
FROM public.groups g
LEFT JOIN public.reservations r ON r.group_id = g.id
WHERE g.city IS NOT NULL AND g.city <> ''
GROUP BY g.city
ORDER BY demand_score DESC;

-- Solo admin puede leer esta vista
REVOKE ALL ON public.city_demand_overview FROM anon, authenticated;
GRANT  SELECT ON public.city_demand_overview TO authenticated;
-- RLS se aplica a nivel función — la vista es auxiliar para admin dashboard


SELECT '144_city_scale_foundation.sql ejecutado ✅' AS status;
SELECT 'RPCs: get_active_cities, update_my_city, get_city_demand_score, get_groups_ranked_by_city' AS info;
SELECT 'Trigger: trg_validate_group_city — ciudad obligatoria en grupos' AS info;
SELECT 'Vista: city_demand_overview — métricas por ciudad para admin' AS info;
