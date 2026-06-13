-- ============================================================
-- sql/336_free_ad_country_targeting.sql
--
-- Targeting por país en anuncios gratuitos del admin:
--   1. create_free_ad v4 — acepta p_target_country
--   2. get_active_banner_ads v4 — acepta p_country y filtra
--      anuncios con target_country cuando está definido.
--
-- Lógica de alcance:
--   target_country IS NULL → aparece en todo el mundo
--   target_country = 'méxico' y target_state IS NULL → solo en México
--   target_country = 'méxico' y target_state = 'jalisco' → solo en Jalisco, México
--
-- El cliente envía p_country = safeCountry.toLowerCase()
-- El admin guarda LOWER(TRIM(p_target_country))
-- Ambos están en minúsculas para que el match sea case-insensitive.
-- ============================================================

-- ── 1. create_free_ad v4 — con targeting de país ─────────────────────────────

DROP FUNCTION IF EXISTS public.create_free_ad(TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, INT, TEXT, TEXT, INT, INT);

CREATE OR REPLACE FUNCTION public.create_free_ad(
  p_type                TEXT,
  p_title               TEXT,
  p_subtitle            TEXT    DEFAULT NULL,
  p_button_text         TEXT    DEFAULT 'Ver más',
  p_media_url           TEXT    DEFAULT NULL,
  p_media_type          TEXT    DEFAULT NULL,
  p_target_state        TEXT    DEFAULT NULL,
  p_duration_days       INT     DEFAULT 30,
  p_tag                 TEXT    DEFAULT NULL,
  p_link_url            TEXT    DEFAULT NULL,
  p_duration_seconds    INT     DEFAULT NULL,
  p_video_start_seconds INT     DEFAULT 0,
  p_target_country      TEXT    DEFAULT NULL   -- 'méxico', 'colombia', etc. (en minúsculas)
)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_user_id        UUID := auth.uid();
  v_role           TEXT;
  v_ad_id          UUID;
  v_ends_at        TIMESTAMPTZ;
  v_link_url       TEXT := NULLIF(TRIM(COALESCE(p_link_url, '')), '');
  v_target_country TEXT := NULLIF(LOWER(TRIM(COALESCE(p_target_country, ''))), '');
BEGIN
  SELECT role INTO v_role FROM public.profiles WHERE id = v_user_id;
  IF v_role IS DISTINCT FROM 'admin' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'unauthorized');
  END IF;

  IF p_type NOT IN ('banner_home', 'profile_ad', 'sponsored_group') THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_type',
      'allowed', '["banner_home","profile_ad","sponsored_group"]'::JSONB);
  END IF;

  IF p_title IS NULL OR TRIM(p_title) = '' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'title_required');
  END IF;

  IF v_link_url IS NOT NULL AND v_link_url !~* '^https?://' THEN
    v_link_url := 'https://' || v_link_url;
  END IF;

  v_ends_at := CASE
    WHEN p_duration_days IS NOT NULL AND p_duration_days > 0
    THEN NOW() + (p_duration_days || ' days')::INTERVAL
    ELSE NULL
  END;

  INSERT INTO public.advertisements (
    type, title, subtitle, button_text,
    media_url, media_type,
    link_type, link_url,
    target_state, target_country,
    status, is_free,
    starts_at, ends_at, tag,
    advertiser_id,
    duration_seconds, video_start_seconds
  )
  VALUES (
    p_type,
    TRIM(p_title),
    NULLIF(TRIM(COALESCE(p_subtitle, '')), ''),
    COALESCE(NULLIF(TRIM(p_button_text), ''), 'Ver más'),
    NULLIF(TRIM(COALESCE(p_media_url, '')), ''),
    NULLIF(p_media_type, ''),
    CASE WHEN v_link_url IS NOT NULL THEN 'url' ELSE 'none' END,
    v_link_url,
    normalize_state_name(p_target_state),
    v_target_country,
    'active',
    TRUE,
    NOW(),
    v_ends_at,
    NULLIF(TRIM(COALESCE(p_tag, '')), ''),
    v_user_id,
    NULLIF(p_duration_seconds, 0),
    COALESCE(p_video_start_seconds, 0)
  )
  RETURNING id INTO v_ad_id;

  RETURN jsonb_build_object(
    'ok',                   true,
    'ad_id',                v_ad_id,
    'type',                 p_type,
    'target_country',       v_target_country,
    'target_state',         normalize_state_name(p_target_state),
    'link_url',             v_link_url,
    'ends_at',              v_ends_at,
    'duration_seconds',     p_duration_seconds,
    'video_start_seconds',  p_video_start_seconds
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.create_free_ad(TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, INT, TEXT, TEXT, INT, INT, TEXT)
  TO authenticated;

-- ── 2. get_active_banner_ads v4 — filtra por país ────────────────────────────

DROP FUNCTION IF EXISTS public.get_active_banner_ads(TEXT, TEXT);

CREATE OR REPLACE FUNCTION public.get_active_banner_ads(
  p_city    TEXT DEFAULT NULL,
  p_state   TEXT DEFAULT NULL,
  p_country TEXT DEFAULT NULL   -- safeCountry.toLowerCase() desde el cliente
)
RETURNS TABLE (
  id                   UUID,
  title                TEXT,
  subtitle             TEXT,
  tag                  TEXT,
  button_text          TEXT,
  media_url            TEXT,
  media_type           TEXT,
  media_offset         INT,
  link_type            TEXT,
  link_id              UUID,
  link_url             TEXT,
  youtube_url          TEXT,
  duration_seconds     INT,
  video_start_seconds  INT,
  order_index          INT,
  is_free              BOOLEAN
)
LANGUAGE plpgsql
SECURITY DEFINER STABLE
SET search_path = public
AS $$
BEGIN
  RETURN QUERY
  SELECT
    a.id, a.title, a.subtitle, a.tag, a.button_text,
    a.media_url, a.media_type, a.media_offset,
    a.link_type, a.link_id, a.link_url, a.youtube_url,
    a.duration_seconds,
    COALESCE(a.video_start_seconds, 0),
    a.order_index,
    a.is_free
  FROM   public.advertisements a
  LEFT JOIN public.ad_packages pkg ON pkg.id = a.package_id
  WHERE  a.type   = 'banner_home'
    AND  a.status = 'active'
    AND  (a.starts_at IS NULL OR a.starts_at <= now())
    AND  (a.ends_at   IS NULL OR a.ends_at   >  now())
    -- Filtro de país: NULL = aparece en todos; coincide si el usuario está en ese país
    AND  (
      a.target_country IS NULL
      OR p_country IS NULL
      OR LOWER(a.target_country) = LOWER(p_country)
    )
    -- Filtro de estado: NULL = todo el país / todos los países
    AND  (
      a.target_location_type IS NULL
      OR a.target_location_type IN ('national', 'international')
      OR p_city IS NULL
      OR (a.target_location_type IN ('city', 'multi_city')
          AND a.target_locations IS NOT NULL
          AND a.target_locations @> jsonb_build_array(p_city))
    )
    AND  (
      p_state IS NULL
      OR (a.target_states IS NULL AND a.target_state IS NULL)
      OR (a.target_states IS NOT NULL
          AND normalize_state_name(p_state) = ANY(a.target_states))
      OR (a.target_states IS NULL AND a.target_state IS NOT NULL
          AND a.target_state = normalize_state_name(p_state))
    )
  ORDER BY
    a.is_free ASC,
    (
      CASE
        WHEN a.target_location_type IN ('city', 'multi_city')
             AND p_city IS NOT NULL
             AND a.target_locations IS NOT NULL
             AND a.target_locations @> jsonb_build_array(p_city)
        THEN 3.0
        ELSE 1.0
      END
    ) * RANDOM() DESC,
    COALESCE(pkg.price, 0) DESC,
    a.order_index ASC,
    a.starts_at   ASC;
END;
$$;

GRANT EXECUTE ON FUNCTION public.get_active_banner_ads(TEXT, TEXT, TEXT) TO anon, authenticated;

-- ── Verificación ──────────────────────────────────────────────────────────────
DO $$
BEGIN
  RAISE NOTICE '[336] create_free_ad v4: acepta p_target_country ✅';
  RAISE NOTICE '[336] get_active_banner_ads v4: acepta p_country, filtra target_country ✅';
  RAISE NOTICE '[336] Alcance: NULL=todos | country=solo ese país | country+state=solo ese estado ✅';
END;
$$;

SELECT '336_free_ad_country_targeting.sql ejecutado ✅' AS status;
