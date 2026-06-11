-- ════════════════════════════════════════════════════════════════════
-- 180_expose_is_free_in_rpcs.sql
--
-- OBJETIVO: Exponer el campo is_free en las RPCs de búsqueda para
-- que el frontend pueda aplicar lógica visual y de límite.
--
-- 1. get_active_banner_ads → agrega is_free BOOLEAN al RETURNS TABLE
-- 2. get_profile_ads       → agrega is_free BOOLEAN al RETURNS TABLE
--
-- Con is_free en la respuesta:
--   - HomeScreen puede filtrar max 1 anuncio gratis visible
--   - GroupDetailScreen puede aplicar opacity menor a anuncios gratis
--   - No cambia el ORDER BY ni la lógica — solo añade la columna
--
-- Seguro: DROP FUNCTION IF EXISTS con firma exacta antes de CREATE
-- Requiere: 179_free_admin_ads.sql (columna is_free en advertisements)
-- ════════════════════════════════════════════════════════════════════


-- ── 1. get_active_banner_ads + is_free ──────────────────────────────────────

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
  order_index      INT,
  is_free          BOOLEAN    -- nuevo: frontend aplica estilo/límite
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
    a.duration_seconds, a.order_index,
    a.is_free
  FROM   public.advertisements a
  LEFT JOIN public.ad_packages pkg ON pkg.id = a.package_id
  WHERE  a.type   = 'banner_home'
    AND  a.status = 'active'
    AND  (a.starts_at IS NULL OR a.starts_at <= now())
    AND  (a.ends_at   IS NULL OR a.ends_at   >  now())
    AND  (
      a.target_location_type IS NULL
      OR a.target_location_type = 'national'
      OR p_city IS NULL
      OR (a.target_locations IS NOT NULL
          AND a.target_locations @> jsonb_build_array(p_city))
    )
    AND  (
      p_state IS NULL
      OR a.target_state IS NULL
      OR normalize_state_name(a.target_state) = normalize_state_name(p_state)
    )
  ORDER BY
    a.is_free ASC,                      -- FALSE (pagados) antes que TRUE (gratis)
    COALESCE(pkg.price, 0) DESC,
    a.order_index ASC,
    a.starts_at   ASC;
END;
$$;

GRANT EXECUTE ON FUNCTION public.get_active_banner_ads(TEXT, TEXT) TO anon, authenticated;


-- ── 2. get_profile_ads + is_free ────────────────────────────────────────────

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
  link_id     UUID,
  is_free     BOOLEAN    -- nuevo: frontend ajusta opacity
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
    a.link_type, a.link_id,
    a.is_free
  FROM   public.advertisements a
  WHERE  a.type   = 'profile_ad'
    AND  a.status = 'active'
    AND  (a.target_group_id IS NULL OR a.target_group_id = p_group_id)
    AND  (a.starts_at IS NULL OR a.starts_at <= now())
    AND  (a.ends_at   IS NULL OR a.ends_at   >  now())
    AND  (
      a.target_location_type IS NULL
      OR a.target_location_type = 'national'
      OR p_city IS NULL
      OR (a.target_locations IS NOT NULL
          AND a.target_locations @> jsonb_build_array(p_city))
    )
    AND  (
      p_state IS NULL
      OR a.target_state IS NULL
      OR normalize_state_name(a.target_state) = normalize_state_name(p_state)
    )
  ORDER BY
    a.is_free ASC,    -- pagado gana (FALSE < TRUE) con LIMIT 1
    a.order_index
  LIMIT  1;
END;
$$;

GRANT EXECUTE ON FUNCTION public.get_profile_ads(UUID, TEXT, TEXT) TO authenticated;


-- ── Verificación ──────────────────────────────────────────────────────────────

-- Confirmar que is_free aparece en la respuesta de la RPC
SELECT id, title, is_free
FROM public.get_active_banner_ads(NULL, NULL)
LIMIT 5;

SELECT '180_expose_is_free_in_rpcs.sql ejecutado ✅' AS status;
