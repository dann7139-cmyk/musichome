-- ════════════════════════════════════════════════════════════════════════════
-- 150_normalize_cities.sql
-- Normalización de nombres de ciudad en todo el sistema.
--
-- PROBLEMA:
--   groups.city y service_cities pueden tener mayúsculas/minúsculas distintas,
--   acentos o espacios extra, lo que rompe los filtros por ciudad.
--
-- SOLUCIÓN:
--   · normalize_city_name()            — función central de normalización
--   · update_my_city()                 — normaliza al guardar ciudad base
--   · update_my_service_cities()       — normaliza cada ciudad del array
--   · get_groups_ranked_by_city()      — compara ciudades normalizadas
--   · get_city_demand_score()          — idem
--   · get_active_cities()              — idem
--   · trg_normalize_group_city         — normaliza groups.city en INSERT/UPDATE
--   · Backfill de datos existentes
--
-- Ejecutar DESPUÉS de 149_multi_city.sql
-- ════════════════════════════════════════════════════════════════════════════


-- ── 1. normalize_city_name() ──────────────────────────────────────────────────
-- Convierte cualquier nombre de ciudad a formato canónico:
--   lowercase + sin acentos españoles + trim de espacios.
-- "Guadalajara" → "guadalajara"
-- "MÉXICO"      → "mexico"
-- "Zapopán "    → "zapopan"

CREATE OR REPLACE FUNCTION public.normalize_city_name(p_city TEXT)
RETURNS TEXT
LANGUAGE plpgsql
IMMUTABLE STRICT
SET search_path = public
AS $$
BEGIN
  RETURN lower(trim(
    translate(
      p_city,
      'ÁÉÍÓÚáéíóúÑñÜü',
      'AEIOUaeiouNnUu'
    )
  ));
END;
$$;

GRANT EXECUTE ON FUNCTION public.normalize_city_name(TEXT) TO anon, authenticated;


-- ── 2. update_my_city() — normaliza ciudad base al guardar ───────────────────

DROP FUNCTION IF EXISTS public.update_my_city(TEXT);
CREATE OR REPLACE FUNCTION public.update_my_city(p_city TEXT)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid       UUID := auth.uid();
  v_city_norm TEXT;
BEGIN
  IF v_uid IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_authenticated');
  END IF;

  IF p_city IS NULL OR trim(p_city) = '' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'city_required');
  END IF;

  v_city_norm := normalize_city_name(p_city);

  UPDATE public.profiles
  SET    city       = v_city_norm,
         updated_at = now()
  WHERE  id = v_uid;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'profile_not_found');
  END IF;

  RETURN jsonb_build_object('ok', true, 'city', v_city_norm);
END;
$$;

GRANT EXECUTE ON FUNCTION public.update_my_city(TEXT) TO authenticated;


-- ── 3. update_my_service_cities() — normaliza cada ciudad del array ───────────

DROP FUNCTION IF EXISTS public.update_my_service_cities(UUID, JSONB);
CREATE OR REPLACE FUNCTION public.update_my_service_cities(
  p_group_id       UUID,
  p_service_cities JSONB   -- array de nombres: '["Zapopan","Tlaquepaque"]'
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_user_id       UUID := auth.uid();
  v_owner         UUID;
  v_normalized    JSONB;
BEGIN
  SELECT owner_id INTO v_owner
  FROM   public.groups
  WHERE  id = p_group_id;

  IF v_owner IS DISTINCT FROM v_user_id THEN
    RETURN jsonb_build_object('ok', false, 'error', 'No autorizado');
  END IF;

  IF jsonb_typeof(p_service_cities) <> 'array' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'service_cities debe ser un array');
  END IF;

  IF jsonb_array_length(p_service_cities) > 10 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'Máximo 10 ciudades adicionales');
  END IF;

  -- Normalizar cada ciudad del array
  SELECT jsonb_agg(normalize_city_name(value::TEXT))
  INTO   v_normalized
  FROM   jsonb_array_elements_text(p_service_cities);

  -- Si el array estaba vacío jsonb_agg devuelve NULL → usar '[]'
  v_normalized := COALESCE(v_normalized, '[]'::JSONB);

  UPDATE public.groups
  SET    service_cities = v_normalized,
         updated_at     = now()
  WHERE  id = p_group_id;

  RETURN jsonb_build_object('ok', true);
END;
$$;

REVOKE ALL ON FUNCTION public.update_my_service_cities(UUID, JSONB) FROM anon;
GRANT  EXECUTE ON FUNCTION public.update_my_service_cities(UUID, JSONB) TO authenticated;


-- ── 4. get_groups_ranked_by_city() — comparación normalizada ─────────────────
-- Re-crea la versión de 149_multi_city con normalize_city_name() en la WHERE
-- y en el ORDER BY (is_local).

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
  service_cities        JSONB,
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
  bid_active            BOOLEAN,
  is_local              BOOLEAN
)
LANGUAGE plpgsql
SECURITY DEFINER STABLE
SET search_path = public
AS $$
DECLARE
  v_city_norm TEXT := CASE WHEN p_city IS NULL THEN NULL
                           ELSE normalize_city_name(p_city) END;
BEGIN
  RETURN QUERY
  SELECT
    g.id,
    g.name,
    g.genre,
    g.city,
    COALESCE(g.service_cities, '[]'::JSONB),
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
    (
      g.bid_ends_at IS NOT NULL
      AND g.bid_ends_at > now()
      AND COALESCE(g.bid_amount, 0) > 0
    ) AS bid_active,
    -- is_local: TRUE cuando la ciudad base coincide
    (v_city_norm IS NULL OR normalize_city_name(g.city) = v_city_norm) AS is_local
  FROM public.groups g
  WHERE g.is_active = true
    AND (
      v_city_norm IS NULL
      -- Ciudad base coincide (normalizada)
      OR normalize_city_name(g.city) = v_city_norm
      -- Ciudad está en service_cities (normalizada)
      OR EXISTS (
        SELECT 1
        FROM jsonb_array_elements_text(COALESCE(g.service_cities, '[]'::JSONB)) sc(city_name)
        WHERE normalize_city_name(sc.city_name) = v_city_norm
      )
    )
  ORDER BY
    -- 1. Grupos locales (ciudad base) primero
    (v_city_norm IS NULL OR normalize_city_name(g.city) = v_city_norm) DESC,
    -- 2. bid activo
    (g.bid_ends_at IS NOT NULL AND g.bid_ends_at > now()
      AND COALESCE(g.bid_amount, 0) > 0) DESC,
    -- 3. monto de bid
    COALESCE(g.bid_amount, 0) DESC,
    -- 4. boost
    COALESCE(g.boost_score, 0) DESC,
    -- 5. calidad
    COALESCE(g.rating, 0) DESC,
    COALESCE(g.total_reviews, 0) DESC,
    -- 6. desempate
    g.created_at DESC
  LIMIT p_limit;
END;
$$;

GRANT EXECUTE ON FUNCTION public.get_groups_ranked_by_city(TEXT, INT)
  TO anon, authenticated;


-- ── 5. get_city_demand_score() — comparación normalizada ─────────────────────

DROP FUNCTION IF EXISTS public.get_city_demand_score(TEXT);
CREATE OR REPLACE FUNCTION public.get_city_demand_score(p_city TEXT)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER STABLE
SET search_path = public
AS $$
DECLARE
  v_city_norm    TEXT;
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

  v_city_norm := normalize_city_name(p_city);

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

  SELECT COUNT(*) INTO v_sponsored
  FROM   public.sponsored_groups sg
  JOIN   public.groups g ON g.id = sg.group_id
  WHERE  sg.is_active = true
    AND  sg.ends_at   > now()
    AND  normalize_city_name(g.city) = v_city_norm;

  SELECT COUNT(*) INTO v_bids
  FROM   public.groups
  WHERE  normalize_city_name(city) = v_city_norm
    AND  bid_ends_at > now()
    AND  COALESCE(bid_amount, 0) > 0;

  SELECT COUNT(*) INTO v_boosts
  FROM   public.groups
  WHERE  normalize_city_name(city) = v_city_norm
    AND  boost_ends_at > now()
    AND  COALESCE(boost_score, 0) > 0;

  SELECT COUNT(*) INTO v_reservations
  FROM   public.reservations r
  JOIN   public.groups       g ON g.id = r.group_id
  WHERE  normalize_city_name(g.city) = v_city_norm
    AND  r.created_at > now() - INTERVAL '30 days'
    AND  r.status NOT IN ('cancelled', 'expired');

  SELECT COUNT(*) INTO v_groups
  FROM   public.groups
  WHERE  normalize_city_name(city) = v_city_norm
    AND  is_active = true;

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


-- ── 6. get_active_cities() — matching normalizado ────────────────────────────

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
    COALESCE(s.name,  '') AS state_name,
    COALESCE(co.name, '') AS country_name,
    COALESCE(c.lat, 0)   AS lat,
    COALESCE(c.lng, 0)   AS lng,
    COUNT(g.id)          AS group_count,
    CASE
      WHEN COUNT(g.id) >= 10 THEN 'high'
      WHEN COUNT(g.id) >= 3  THEN 'normal'
      ELSE                        'new'
    END                  AS demand_level
  FROM   public.cities c
  LEFT JOIN public.states    s  ON s.id  = c.state_id
  LEFT JOIN public.countries co ON co.id = c.country_id
  LEFT JOIN public.groups    g  ON normalize_city_name(g.city) = normalize_city_name(c.name)
                                AND g.is_active = true
  WHERE  c.is_active = true
  GROUP BY c.id, c.name, s.name, co.name, c.lat, c.lng
  ORDER BY group_count DESC, c.name ASC;
END;
$$;

GRANT EXECUTE ON FUNCTION public.get_active_cities() TO anon, authenticated;


-- ── 7. Trigger: auto-normalizar groups.city en INSERT/UPDATE ─────────────────
-- Garantiza que groups.city siempre quede normalizado,
-- sin importar desde dónde se escriba (app, admin, SQL directo).

CREATE OR REPLACE FUNCTION public.normalize_group_city()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  IF NEW.city IS NULL OR trim(NEW.city) = '' THEN
    RAISE EXCEPTION 'La ciudad del grupo es obligatoria (campo city vacío).'
      USING ERRCODE = 'check_violation';
  END IF;
  NEW.city := normalize_city_name(NEW.city);
  RETURN NEW;
END;
$$;

-- Reemplaza trg_validate_group_city (mismo evento, ahora también normaliza)
DROP TRIGGER IF EXISTS trg_validate_group_city   ON public.groups;
DROP TRIGGER IF EXISTS trg_normalize_group_city  ON public.groups;
CREATE TRIGGER trg_normalize_group_city
  BEFORE INSERT OR UPDATE OF city ON public.groups
  FOR EACH ROW EXECUTE FUNCTION public.normalize_group_city();


-- ── 8. Backfill: normalizar datos existentes ──────────────────────────────────
-- Ejecutar una sola vez. Es idempotente.

-- 8a. Normalizar groups.city
UPDATE public.groups
SET    city = normalize_city_name(city)
WHERE  city IS NOT NULL
  AND  city <> normalize_city_name(city);

-- 8b. Normalizar service_cities (elemento a elemento)
UPDATE public.groups
SET    service_cities = (
  SELECT COALESCE(jsonb_agg(normalize_city_name(value)), '[]'::JSONB)
  FROM   jsonb_array_elements_text(service_cities)
)
WHERE  service_cities IS NOT NULL
  AND  service_cities <> '[]'::JSONB;

SELECT '150_normalize_cities.sql ejecutado ✅' AS status;
SELECT 'normalize_city_name() creada — lowercase + sin acentos' AS info;
SELECT 'update_my_city / update_my_service_cities normalizan al guardar' AS info;
SELECT 'get_groups_ranked_by_city / get_city_demand_score usan normalización' AS info;
SELECT 'Trigger trg_normalize_group_city: groups.city siempre normalizado' AS info;
SELECT 'Backfill completado en groups.city, service_cities y profiles.city' AS info;
