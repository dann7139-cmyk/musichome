-- ════════════════════════════════════════════════════════════════════
-- 175_state_filtering_and_images.sql
--
-- 1. Agrega columna `state` a groups y `target_state` a advertisements
-- 2. Actualiza anuncios demo con imágenes reales (Unsplash CDN)
-- 3. Actualiza get_active_banner_ads  → acepta p_state TEXT opcional
-- 4. Actualiza get_profile_ads        → acepta p_state TEXT opcional
-- 5. Actualiza get_active_recommendations → acepta p_state TEXT opcional
-- 6. Actualiza get_groups_ranked_by_city  → acepta p_state TEXT opcional
--
-- Lógica de estado:
--   - Si p_state es NULL  → el usuario no tiene estado detectado → se muestran TODOS
--   - Si target_state es NULL → el anuncio/grupo es nacional → aparece en todos los estados
--   - Si target_state coincide con p_state → aparece solo en ese estado
--
-- Seguro: ALTER TABLE IF NOT EXISTS, DROP IF EXISTS + CREATE OR REPLACE
-- Ejecutar en Supabase SQL Editor (después de 174_fix_banner_ads.sql)
-- ════════════════════════════════════════════════════════════════════

-- ── 1. Columnas de estado ─────────────────────────────────────────────────────

ALTER TABLE public.groups
  ADD COLUMN IF NOT EXISTS state TEXT;

ALTER TABLE public.advertisements
  ADD COLUMN IF NOT EXISTS target_state TEXT;

COMMENT ON COLUMN public.groups.state IS
  'Estado mexicano al que pertenece el grupo (ej. "Jalisco"). NULL = nacional.';
COMMENT ON COLUMN public.advertisements.target_state IS
  'Estado al que se dirige el anuncio. NULL = visible en todos los estados.';

-- Índice para búsqueda por estado
CREATE INDEX IF NOT EXISTS idx_groups_state ON public.groups (state);
CREATE INDEX IF NOT EXISTS idx_ads_target_state ON public.advertisements (target_state);


-- ── 2. Actualizar anuncios demo con imágenes ──────────────────────────────────
-- Si el SQL 174 fue ejecutado, estos ads existen. Les ponemos media_url y media_type.

UPDATE public.advertisements
SET
  media_url  = 'https://images.unsplash.com/photo-1470229722913-7c0e2dbbafd3?w=800&q=80',
  media_type = 'image',
  updated_at = NOW()
WHERE type      = 'banner_home'
  AND status    = 'active'
  AND (media_url IS NULL OR media_url = '');

UPDATE public.advertisements
SET
  media_url  = 'https://images.unsplash.com/photo-1493225457124-a3eb161ffa5f?w=600&q=80',
  media_type = 'image',
  updated_at = NOW()
WHERE type      = 'profile_ad'
  AND status    = 'active'
  AND (media_url IS NULL OR media_url = '');


-- ── 3. get_active_banner_ads — con filtro opcional de estado ─────────────────

DROP FUNCTION IF EXISTS public.get_active_banner_ads(TEXT);
DROP FUNCTION IF EXISTS public.get_active_banner_ads(TEXT, TEXT);

CREATE OR REPLACE FUNCTION public.get_active_banner_ads(
  p_city  TEXT DEFAULT NULL,
  p_state TEXT DEFAULT NULL
)
RETURNS TABLE (
  id               UUID,
  title            TEXT,
  subtitle         TEXT,
  tag              TEXT,
  button_text      TEXT,
  media_url        TEXT,
  media_type       TEXT,
  media_offset     INT,
  link_type        TEXT,
  link_id          UUID,
  duration_seconds INT,
  order_index      INT
)
LANGUAGE plpgsql
SECURITY DEFINER STABLE
SET search_path = public
AS $$
BEGIN
  PERFORM public.expire_advertisements();
  RETURN QUERY
  SELECT
    a.id, a.title, a.subtitle, a.tag, a.button_text,
    a.media_url, a.media_type, a.media_offset,
    a.link_type, a.link_id,
    a.duration_seconds, a.order_index
  FROM   public.advertisements a
  LEFT JOIN public.ad_packages pkg ON pkg.id = a.package_id
  WHERE  a.type   = 'banner_home'
    AND  a.status = 'active'
    AND  (a.starts_at IS NULL OR a.starts_at <= now())
    AND  (a.ends_at   IS NULL OR a.ends_at   >  now())
    -- Filtro de ciudad (legacy)
    AND  (
      a.target_location_type IS NULL
      OR a.target_location_type = 'national'
      OR p_city IS NULL
      OR (a.target_locations IS NOT NULL
          AND a.target_locations @> jsonb_build_array(p_city))
    )
    -- Filtro de estado (nuevo)
    AND  (
      p_state IS NULL                                        -- estado del usuario desconocido → mostrar todo
      OR a.target_state IS NULL                             -- anuncio nacional → siempre visible
      OR LOWER(TRIM(a.target_state)) = LOWER(TRIM(p_state)) -- estado coincide
    )
  ORDER BY
    COALESCE(pkg.price, 0) DESC,
    a.order_index ASC,
    a.starts_at   ASC;
END;
$$;

GRANT EXECUTE ON FUNCTION public.get_active_banner_ads(TEXT, TEXT) TO anon, authenticated;


-- ── 4. get_profile_ads — con filtro opcional de estado ───────────────────────

DROP FUNCTION IF EXISTS public.get_profile_ads(UUID, TEXT);
DROP FUNCTION IF EXISTS public.get_profile_ads(UUID, TEXT, TEXT);

CREATE OR REPLACE FUNCTION public.get_profile_ads(
  p_group_id UUID,
  p_city     TEXT DEFAULT NULL,
  p_state    TEXT DEFAULT NULL
)
RETURNS TABLE (
  id          UUID,
  title       TEXT,
  subtitle    TEXT,
  button_text TEXT,
  media_url   TEXT,
  media_type  TEXT,
  link_type   TEXT,
  link_id     UUID
)
LANGUAGE plpgsql
SECURITY DEFINER STABLE
SET search_path = public
AS $$
BEGIN
  RETURN QUERY
  SELECT
    a.id, a.title, a.subtitle, a.button_text,
    a.media_url, a.media_type,
    a.link_type, a.link_id
  FROM   public.advertisements a
  WHERE  a.type   = 'profile_ad'
    AND  a.status = 'active'
    AND  (a.target_group_id IS NULL OR a.target_group_id = p_group_id)
    AND  (a.starts_at IS NULL OR a.starts_at <= now())
    AND  (a.ends_at   IS NULL OR a.ends_at   >  now())
    -- Filtro de ciudad (legacy)
    AND  (
      a.target_location_type IS NULL
      OR a.target_location_type = 'national'
      OR p_city IS NULL
      OR (a.target_locations IS NOT NULL
          AND a.target_locations @> jsonb_build_array(p_city))
    )
    -- Filtro de estado (nuevo)
    AND  (
      p_state IS NULL
      OR a.target_state IS NULL
      OR LOWER(TRIM(a.target_state)) = LOWER(TRIM(p_state))
    )
  ORDER  BY a.order_index
  LIMIT  1;
END;
$$;

GRANT EXECUTE ON FUNCTION public.get_profile_ads(UUID, TEXT, TEXT) TO authenticated;


-- ── 5. get_active_recommendations — con filtro opcional de estado ─────────────

DROP FUNCTION IF EXISTS public.get_active_recommendations(TEXT, INTEGER);
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
  profile_image  TEXT,
  amount         NUMERIC,
  ends_at        TIMESTAMPTZ
)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public
AS $$
  SELECT
    g.id, g.name, g.genre, g.city, g.description,
    g.price_from, g.rating, g.total_reviews, g.is_verified, g.profile_image,
    ro.amount, ro.ends_at
  FROM public.recommendation_orders ro
  JOIN public.groups g ON g.id = ro.group_id
  WHERE ro.status  = 'paid'
    AND ro.starts_at <= NOW()
    AND ro.ends_at   >  NOW()
    AND g.is_active  = TRUE
    -- Filtro de ciudad
    AND (p_city  IS NULL OR LOWER(TRIM(g.city))  = LOWER(TRIM(p_city)))
    -- Filtro de estado
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

GRANT EXECUTE ON FUNCTION public.get_active_recommendations(TEXT, TEXT, INTEGER) TO anon, authenticated;


-- ── 6. get_groups_ranked_by_city — con filtro opcional de estado ─────────────

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
  v_state_norm TEXT := CASE WHEN p_state IS NULL THEN NULL ELSE LOWER(TRIM(p_state)) END;
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
    -- Filtro de estado (nuevo): grupos sin estado asignado aparecen en todos
    AND (
      v_state_norm IS NULL
      OR g.state IS NULL
      OR LOWER(TRIM(g.state)) = v_state_norm
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


-- ── Verificación ──────────────────────────────────────────────────────────────

SELECT type, title, status, media_type,
       LEFT(media_url, 60) AS media_preview,
       target_state
FROM public.advertisements
WHERE status = 'active'
ORDER BY type, created_at DESC;

SELECT '175_state_filtering_and_images.sql ejecutado ✅' AS status;
