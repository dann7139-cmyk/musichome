-- ============================================================
-- sql/335_advertisements_video_trim.sql
--
-- Soporte para recorte de video en anuncios gratuitos:
--   1. Columna video_start_seconds en advertisements
--   2. create_free_ad v3 — acepta p_duration_seconds y p_video_start_seconds
--   3. get_active_banner_ads v3 — expone video_start_seconds
-- ============================================================

-- ── 1. Columna video_start_seconds ────────────────────────────────────────────
ALTER TABLE public.advertisements
  ADD COLUMN IF NOT EXISTS video_start_seconds INTEGER DEFAULT 0;

COMMENT ON COLUMN public.advertisements.video_start_seconds IS
  'Segundo de inicio del clip dentro del archivo subido. '
  'El explorador reproduce desde este punto durante duration_seconds.';

-- ── 2. create_free_ad v3 — con trim de video ─────────────────────────────────
DROP FUNCTION IF EXISTS public.create_free_ad(TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, INT, TEXT, TEXT);

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
  p_video_start_seconds INT     DEFAULT 0
)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_user_id  UUID := auth.uid();
  v_role     TEXT;
  v_ad_id    UUID;
  v_ends_at  TIMESTAMPTZ;
  v_link_url TEXT := NULLIF(TRIM(COALESCE(p_link_url, '')), '');
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
    target_state, status, is_free,
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
    'link_url',             v_link_url,
    'ends_at',              v_ends_at,
    'duration_seconds',     p_duration_seconds,
    'video_start_seconds',  p_video_start_seconds
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.create_free_ad(TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, INT, TEXT, TEXT, INT, INT)
  TO authenticated;

-- ── 3. get_active_banner_ads v3 — expone video_start_seconds ─────────────────
DROP FUNCTION IF EXISTS public.get_active_banner_ads(TEXT, TEXT);

CREATE OR REPLACE FUNCTION public.get_active_banner_ads(
  p_city  TEXT DEFAULT NULL,
  p_state TEXT DEFAULT NULL
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

GRANT EXECUTE ON FUNCTION public.get_active_banner_ads(TEXT, TEXT) TO anon, authenticated;

-- ── Verificación ──────────────────────────────────────────────────────────────
DO $$
BEGIN
  RAISE NOTICE '[335] advertisements.video_start_seconds agregado ✅';
  RAISE NOTICE '[335] create_free_ad v3: acepta p_duration_seconds + p_video_start_seconds ✅';
  RAISE NOTICE '[335] get_active_banner_ads v3: expone video_start_seconds ✅';
END;
$$;

SELECT '335_advertisements_video_trim.sql ejecutado ✅' AS status;
