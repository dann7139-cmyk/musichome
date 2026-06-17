-- ════════════════════════════════════════════════════════════════════
-- sql/361_recommendations_bi_country.sql
--
-- Bugs P2 y P3: sistema de recomendaciones y ranking no filtraban
-- por país. Usuario de USA veía grupos de México y viceversa.
--
-- Cambios en este archivo (en una sola transacción):
--
--   BLOQUE 1: ALTER TABLE recommendation_orders
--             ADD COLUMN IF NOT EXISTS country TEXT
--
--   BLOQUE 2: get_active_recommendations — nuevo p_country TEXT DEFAULT NULL
--             Firma anterior: (TEXT, TEXT, INTEGER) → firma nueva: (TEXT, TEXT, TEXT, INTEGER)
--
--   BLOQUE 3: get_groups_ranked_by_city — nuevo p_country TEXT DEFAULT NULL
--             Firma anterior: (TEXT, TEXT, INT) → firma nueva: (TEXT, TEXT, TEXT, INT)
--
--   BLOQUE 4: place_recommendation_order — guarda g.country al insertar
--             Firma sin cambios (UUID, INT) — solo CREATE OR REPLACE.
--
--   BLOQUE 5: Backfill country en recommendation_orders existentes
--             desde groups.country (idempotente).
--
-- Backward compatible: todos los parámetros nuevos son DEFAULT NULL.
-- Grupos sin country registrado (legacy) se incluyen siempre.
--
-- Depende de: normalize_state_name (sql/177), groups.country (sql/321),
--             normalize_city_name (sql/150).
-- Ejecutar después de: sql/360_fix_sponsored_group_ids.sql
-- ════════════════════════════════════════════════════════════════════

BEGIN;

-- ── Guardia: dependencias deben existir antes de continuar ───────────────────

DO $$
BEGIN
  -- normalize_state_name creada en sql/177
  IF NOT EXISTS (
    SELECT 1 FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public' AND p.proname = 'normalize_state_name'
  ) THEN
    RAISE EXCEPTION
      'normalize_state_name no existe. Ejecutar 177_normalize_state_and_fixes.sql primero.';
  END IF;

  -- groups.country creada en sql/321
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name   = 'groups'
      AND column_name  = 'country'
  ) THEN
    RAISE EXCEPTION
      'groups.country no existe. Ejecutar 321_backfill_group_country.sql primero.';
  END IF;
END;
$$;


-- ════════════════════════════════════════════════════════════════════
-- BLOQUE 1: columna country en recommendation_orders
--
-- ADD COLUMN IF NOT EXISTS — idempotente, no falla si ya existe.
-- TEXT nullable: filas antiguas quedan NULL hasta el backfill (Bloque 5).
-- ════════════════════════════════════════════════════════════════════

ALTER TABLE public.recommendation_orders
  ADD COLUMN IF NOT EXISTS country TEXT;


-- ════════════════════════════════════════════════════════════════════
-- BLOQUE 2: get_active_recommendations + p_country
--
-- Bug P2: un grupo de USA con recommendation_order activa aparecía
-- en el carrusel "Recomendado para ti" de un usuario en México.
--
-- Nuevo parámetro: p_country TEXT DEFAULT NULL (tercer argumento).
-- Filtro agrega AND sobre g.country (JOIN con groups ya existe).
-- Grupos con g.country IS NULL (legacy) se incluyen siempre.
--
-- DROP de firma anterior exacta: (TEXT, TEXT, INTEGER)
-- ════════════════════════════════════════════════════════════════════

DROP FUNCTION IF EXISTS public.get_active_recommendations(TEXT, TEXT, INTEGER);

CREATE OR REPLACE FUNCTION public.get_active_recommendations(
  p_city    TEXT    DEFAULT NULL,
  p_state   TEXT    DEFAULT NULL,
  p_country TEXT    DEFAULT NULL,
  p_limit   INTEGER DEFAULT 10
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
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public
AS $$
  SELECT
    g.id, g.name, g.genre, g.city, g.description,
    g.price_from, g.rating, g.total_reviews, g.is_verified,
    -- Plus activo con guard de expiración (heredado de sql/326)
    (g.is_plus_active AND (g.plus_expires_at IS NULL OR g.plus_expires_at > NOW())) AS is_plus_active,
    g.profile_image,
    ro.amount, ro.ends_at
  FROM public.recommendation_orders ro
  JOIN public.groups g ON g.id = ro.group_id
  WHERE ro.status    = 'paid'
    AND ro.starts_at <= NOW()
    AND ro.ends_at   >  NOW()
    AND g.is_active  = TRUE
    -- Ciudad (heredado): solo si el caller la especifica
    AND (p_city IS NULL OR LOWER(TRIM(g.city)) = LOWER(TRIM(p_city)))
    -- Estado: g.state IS NULL = grupo nacional → visible en cualquier estado
    AND (
      p_state IS NULL
      OR g.state IS NULL
      OR normalize_state_name(g.state) = normalize_state_name(p_state)
    )
    -- País (nuevo): g.country IS NULL = grupo legacy → visible en cualquier país
    AND (
      p_country IS NULL
      OR g.country IS NULL
      OR normalize_state_name(g.country) = normalize_state_name(p_country)
    )
  ORDER BY
    COALESCE(ro.bid_amount, ro.amount) DESC,
    ro.ends_at   DESC,
    ro.starts_at DESC
  LIMIT p_limit;
$$;

GRANT EXECUTE ON FUNCTION public.get_active_recommendations(TEXT, TEXT, TEXT, INTEGER)
  TO anon, authenticated;


-- ════════════════════════════════════════════════════════════════════
-- BLOQUE 3: get_groups_ranked_by_city + p_country
--
-- Bug P2: HomeScreen usaba un workaround JS
--   rawGroups.filter(g => !g.country || g.country === userCountry)
-- cuando no había filtro de país en el RPC. Ahora el filtro es en DB.
--
-- Nuevo parámetro: p_country TEXT DEFAULT NULL (tercer argumento).
-- RETURNS TABLE sin cambios — TypeScript no necesita actualización.
-- ORDER BY sin cambios — bid/plus/rating siguen igual.
--
-- DROP de firma anterior exacta: (TEXT, TEXT, INT)
-- También DROP de (TEXT, INT) por si quedó alguna versión vieja.
-- ════════════════════════════════════════════════════════════════════

DROP FUNCTION IF EXISTS public.get_groups_ranked_by_city(TEXT, INT);
DROP FUNCTION IF EXISTS public.get_groups_ranked_by_city(TEXT, TEXT, INT);

CREATE OR REPLACE FUNCTION public.get_groups_ranked_by_city(
  p_city    TEXT,
  p_state   TEXT DEFAULT NULL,
  p_country TEXT DEFAULT NULL,
  p_limit   INT  DEFAULT 60
)
RETURNS TABLE (
  id                  UUID,
  name                TEXT,
  genre               TEXT,
  city                TEXT,
  service_cities      JSONB,
  profile_image       TEXT,
  photo_status        TEXT,
  price_from          NUMERIC,
  rating              NUMERIC,
  total_reviews       INT,
  is_verified         BOOLEAN,
  verification_status TEXT,
  is_active           BOOLEAN,
  puntos_reputacion   INT,
  bid_amount          NUMERIC,
  bid_ends_at         TIMESTAMPTZ,
  boost_score         INT,
  boost_ends_at       TIMESTAMPTZ,
  trust_score         NUMERIC,
  search_penalty      NUMERIC,
  is_high_demand      BOOLEAN,
  recent_completions  INT,
  bid_active          BOOLEAN,
  is_local            BOOLEAN,
  is_plus_active      BOOLEAN
)
LANGUAGE plpgsql
SECURITY DEFINER STABLE
SET search_path = public
AS $$
DECLARE
  v_city_norm    TEXT := CASE WHEN p_city    IS NULL THEN NULL ELSE normalize_city_name(p_city)     END;
  v_state_norm   TEXT := CASE WHEN p_state   IS NULL THEN NULL ELSE normalize_state_name(p_state)   END;
  v_country_norm TEXT := CASE WHEN p_country IS NULL THEN NULL ELSE normalize_state_name(p_country) END;
BEGIN
  RETURN QUERY
  SELECT
    g.id, g.name, g.genre, g.city,
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
    COALESCE(g.is_high_demand, FALSE),
    COALESCE(g.recent_completions, 0)::INT,
    (
      g.bid_ends_at IS NOT NULL
      AND g.bid_ends_at > NOW()
      AND COALESCE(g.bid_amount, 0) > 0
    ) AS bid_active,
    (v_city_norm IS NULL OR normalize_city_name(g.city) = v_city_norm) AS is_local,
    -- Plus activo con guard de expiración: protege ante webhook fallido (heredado sql/325)
    (g.is_plus_active AND (g.plus_expires_at IS NULL OR g.plus_expires_at > NOW())) AS is_plus_active
  FROM public.groups g
  WHERE g.is_active = TRUE

    -- Filtro ciudad + service_cities (heredado)
    AND (
      v_city_norm IS NULL
      OR normalize_city_name(g.city) = v_city_norm
      OR EXISTS (
        SELECT 1
        FROM jsonb_array_elements_text(COALESCE(g.service_cities, '[]'::JSONB)) sc(city_name)
        WHERE normalize_city_name(sc.city_name) = v_city_norm
      )
    )

    -- Filtro estado: g.state IS NULL = grupo nacional → visible en cualquier estado
    AND (
      v_state_norm IS NULL
      OR g.state IS NULL
      OR normalize_state_name(g.state) = v_state_norm
    )

    -- Filtro país (nuevo): g.country IS NULL = grupo legacy → visible en cualquier país
    AND (
      v_country_norm IS NULL
      OR g.country IS NULL
      OR normalize_state_name(g.country) = v_country_norm
    )

  ORDER BY
    -- #1: Grupos locales primero (sin cambio)
    (v_city_norm IS NULL OR normalize_city_name(g.city) = v_city_norm) DESC,
    -- #2: Bidding activo (sin cambio — siempre gana sobre Plus)
    (g.bid_ends_at IS NOT NULL AND g.bid_ends_at > NOW()
      AND COALESCE(g.bid_amount, 0) > 0) DESC,
    -- #3: Mayor monto de bid (sin cambio)
    COALESCE(g.bid_amount, 0) DESC,
    -- #4: Plus activo con guard de expiración (sin cambio)
    (g.is_plus_active AND (g.plus_expires_at IS NULL OR g.plus_expires_at > NOW())) DESC,
    -- #5-7: Orgánicos (sin cambio)
    COALESCE(g.rating, 0) DESC,
    COALESCE(g.total_reviews, 0) DESC,
    g.created_at DESC
  LIMIT p_limit;
END;
$$;

GRANT EXECUTE ON FUNCTION public.get_groups_ranked_by_city(TEXT, TEXT, TEXT, INT)
  TO anon, authenticated;


-- ════════════════════════════════════════════════════════════════════
-- BLOQUE 4: place_recommendation_order — guarda g.country al insertar
--
-- Firma sin cambios (UUID, INT) → solo CREATE OR REPLACE, sin DROP.
-- Agrega v_country al SELECT FROM groups y al INSERT.
-- Requiere que recommendation_orders.country exista (Bloque 1).
-- ════════════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION public.place_recommendation_order(
  p_group_id UUID,
  p_duration INT
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_amount   NUMERIC(10,2);
  v_per_day  NUMERIC(10,2);
  v_city     TEXT;
  v_state    TEXT;
  v_country  TEXT;
  v_order_id UUID;
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM public.groups WHERE id = p_group_id AND owner_id = auth.uid()
  ) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'unauthorized');
  END IF;

  -- Pricing escalonado fijo (sin cambios respecto a sql/177)
  v_amount := CASE p_duration
    WHEN 1 THEN   79.00
    WHEN 3 THEN  199.00
    WHEN 7 THEN  399.00
    ELSE ROUND((79.00 * p_duration * 0.85)::NUMERIC, 2)
  END;

  v_per_day := ROUND((v_amount / p_duration)::NUMERIC, 2);

  -- Ciudad, estado (normalizado) y país del grupo
  SELECT city, normalize_state_name(state), country
  INTO   v_city, v_state, v_country
  FROM   public.groups
  WHERE  id = p_group_id;

  INSERT INTO public.recommendation_orders
    (group_id, duration_days, amount, price_per_day, status, city, state, country)
  VALUES
    (p_group_id, p_duration, v_amount, v_per_day, 'pending_payment',
     v_city, v_state, v_country)
  RETURNING id INTO v_order_id;

  RETURN jsonb_build_object(
    'ok',       true,
    'order_id', v_order_id,
    'amount',   v_amount,
    'per_day',  v_per_day,
    'duration', p_duration,
    'city',     v_city,
    'state',    v_state,
    'country',  v_country
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.place_recommendation_order(UUID, INT)
  TO authenticated;


-- ════════════════════════════════════════════════════════════════════
-- BLOQUE 5: Backfill country en recommendation_orders existentes
--
-- Solo actualiza filas con country IS NULL cuyo grupo tiene país.
-- Idempotente: si se ejecuta dos veces, el segundo UPDATE es 0 filas.
-- Protegido contra NULLs: AND ro.country IS NULL + AND g.country IS NOT NULL.
-- ════════════════════════════════════════════════════════════════════

UPDATE public.recommendation_orders ro
SET    country = g.country
FROM   public.groups g
WHERE  g.id       = ro.group_id
  AND  ro.country IS NULL
  AND  g.country  IS NOT NULL;


COMMIT;


-- ════════════════════════════════════════════════════════════════════
-- VERIFICACIONES (ejecutar tras COMMIT)
-- ════════════════════════════════════════════════════════════════════

-- 1. Firma de get_active_recommendations
--    Esperado: "(p_city text DEFAULT NULL, p_state text DEFAULT NULL,
--               p_country text DEFAULT NULL, p_limit integer DEFAULT 10)"
SELECT
  p.proname                                    AS funcion,
  pg_catalog.pg_get_function_arguments(p.oid) AS firma
FROM pg_proc p
JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'public'
  AND p.proname = 'get_active_recommendations';


-- 2. Firma de get_groups_ranked_by_city
--    Esperado: "(p_city text, p_state text DEFAULT NULL,
--               p_country text DEFAULT NULL, p_limit integer DEFAULT 60)"
SELECT
  p.proname                                    AS funcion,
  pg_catalog.pg_get_function_arguments(p.oid) AS firma
FROM pg_proc p
JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'public'
  AND p.proname = 'get_groups_ranked_by_city';


-- 3. Columna country en recommendation_orders
--    Esperado: 1 fila con column_name='country', data_type='text'
SELECT column_name, data_type, is_nullable
FROM information_schema.columns
WHERE table_schema = 'public'
  AND table_name   = 'recommendation_orders'
  AND column_name  = 'country';


-- 4. Resultado del backfill
--    Esperado: sin_country = 0 (o igual al número de grupos sin país)
SELECT
  COUNT(*)                                AS total_orders,
  COUNT(country)                          AS con_country,
  COUNT(*) FILTER (WHERE country IS NULL) AS sin_country
FROM public.recommendation_orders;


SELECT 'sql/361_recommendations_bi_country.sql ejecutado ✅' AS status;
