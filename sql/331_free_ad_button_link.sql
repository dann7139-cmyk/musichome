-- ============================================================
-- sql/331_free_ad_button_link.sql
--
-- Botón con ENLACE en los anuncios gratis del admin:
--   1. create_free_ad v2 — acepta p_link_url; si viene, guarda
--      link_type='url' + link_url (el botón abre ese enlace).
--   2. get_active_banner_ads v2 — expone link_url y youtube_url
--      (antes el cliente no recibía el enlace aunque existiera).
--   3. get_profile_ads v2 — igual.
--
-- La tabla advertisements YA tiene link_type ('none'|'group'|'url'
-- + 'video' desde 134), link_url y youtube_url. Solo faltaba
-- aceptarlo al crear gratis y devolverlo al leer.
-- ============================================================

-- ── 1. create_free_ad v2 — con enlace de botón ────────────────────────────────

DROP FUNCTION IF EXISTS public.create_free_ad(TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, INT, TEXT);

CREATE OR REPLACE FUNCTION public.create_free_ad(
  p_type          TEXT,
  p_title         TEXT,
  p_subtitle      TEXT    DEFAULT NULL,
  p_button_text   TEXT    DEFAULT 'Ver más',
  p_media_url     TEXT    DEFAULT NULL,
  p_media_type    TEXT    DEFAULT NULL,   -- 'image' | 'video'
  p_target_state  TEXT    DEFAULT NULL,
  p_duration_days INT     DEFAULT 30,
  p_tag           TEXT    DEFAULT NULL,
  p_link_url      TEXT    DEFAULT NULL    -- enlace que abre el botón
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
  -- Verificar que el usuario es admin
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

  -- Normalizar enlace: si no trae esquema, anteponer https://
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
    advertiser_id
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
    v_user_id
  )
  RETURNING id INTO v_ad_id;

  RETURN jsonb_build_object(
    'ok',       true,
    'ad_id',    v_ad_id,
    'type',     p_type,
    'link_url', v_link_url,
    'ends_at',  v_ends_at
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.create_free_ad(TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, INT, TEXT, TEXT)
  TO authenticated;

-- ── 2. get_active_banner_ads v2 — expone link_url y youtube_url ───────────────
-- Idéntica a sql/194 + 2 columnas. DROP requerido: cambia el RETURNS TABLE.

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
  link_url         TEXT,
  youtube_url      TEXT,
  duration_seconds INT,
  order_index      INT,
  is_free          BOOLEAN
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

-- ── 3. get_profile_ads v2 — expone link_url y youtube_url ─────────────────────

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
  link_url    TEXT,
  youtube_url TEXT,
  is_free     BOOLEAN
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
    a.link_type, a.link_id, a.link_url, a.youtube_url,
    a.is_free
  FROM   public.advertisements a
  WHERE  a.type   = 'profile_ad'
    AND  a.status = 'active'
    AND  (a.target_group_id IS NULL OR a.target_group_id = p_group_id)
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
    a.order_index ASC,
    a.starts_at   ASC
  LIMIT 5;
END;
$$;

GRANT EXECUTE ON FUNCTION public.get_profile_ads(UUID, TEXT, TEXT) TO authenticated;

-- ── Verificación ──────────────────────────────────────────────────────────────
DO $$
BEGIN
  RAISE NOTICE '[331] create_free_ad: acepta p_link_url (botón con enlace) ✅';
  RAISE NOTICE '[331] get_active_banner_ads: expone link_url + youtube_url ✅';
  RAISE NOTICE '[331] get_profile_ads: expone link_url + youtube_url ✅';
END;
$$;

SELECT '331_free_ad_button_link.sql ejecutado ✅' AS status;
