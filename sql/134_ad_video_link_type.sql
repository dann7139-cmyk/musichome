-- ════════════════════════════════════════════════════════════════════════════
-- 134_ad_video_link_type.sql
-- Agrega soporte para link_type = 'video' (YouTube embebido dentro de la app)
-- y la columna youtube_url.
--
-- Ejecutar DESPUÉS de 133_ad_system_upgrade.sql
-- ════════════════════════════════════════════════════════════════════════════

-- ── 1. Agregar columna youtube_url ─────────────────────────────────────────

ALTER TABLE public.advertisements
  ADD COLUMN IF NOT EXISTS youtube_url TEXT;

-- ── 2. Actualizar CHECK constraint de link_type ────────────────────────────

ALTER TABLE public.advertisements
  DROP CONSTRAINT IF EXISTS advertisements_link_type_check;

ALTER TABLE public.advertisements
  ADD CONSTRAINT advertisements_link_type_check
    CHECK (link_type IN ('none', 'group', 'video'));

-- ── 3. Actualizar RPC create_advertisement_order para aceptar youtube_url ──

DROP FUNCTION IF EXISTS public.create_advertisement_order(TEXT,TEXT,TEXT,TEXT,TEXT,TEXT,UUID,UUID,TEXT,TEXT,TEXT,TEXT[],INTEGER);
DROP FUNCTION IF EXISTS public.create_advertisement_order(TEXT,TEXT,TEXT,TEXT,TEXT,TEXT,UUID,UUID,TEXT,TEXT,TEXT,TEXT[],INTEGER,TEXT);

CREATE OR REPLACE FUNCTION public.create_advertisement_order(
  p_type              TEXT,
  p_title             TEXT,
  p_subtitle          TEXT         DEFAULT NULL,
  p_button_text       TEXT         DEFAULT 'Contratar',
  p_media_url         TEXT         DEFAULT NULL,
  p_media_type        TEXT         DEFAULT 'none',
  p_package_id        UUID         DEFAULT NULL,
  p_target_group_id   UUID         DEFAULT NULL,
  p_link_type         TEXT         DEFAULT 'none',
  p_link_id           TEXT         DEFAULT NULL,
  p_location_type     TEXT         DEFAULT 'national',
  p_locations         TEXT[]       DEFAULT NULL,
  p_duration_seconds  INTEGER      DEFAULT NULL,
  p_youtube_url       TEXT         DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER
AS $$
DECLARE
  v_uid       UUID := auth.uid();
  v_ad_id     UUID;
  v_package   RECORD;
  v_resolved_link_type TEXT;
  v_resolved_youtube   TEXT;
BEGIN
  IF v_uid IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_authenticated');
  END IF;

  -- Validar link_type
  v_resolved_link_type := COALESCE(p_link_type, 'none');
  IF v_resolved_link_type NOT IN ('none', 'group', 'video') THEN
    v_resolved_link_type := 'none';
  END IF;

  -- Solo guardar youtube_url si link_type = 'video'
  v_resolved_youtube := CASE WHEN v_resolved_link_type = 'video' THEN p_youtube_url ELSE NULL END;

  -- Cargar el paquete
  SELECT * INTO v_package FROM public.ad_packages WHERE id = p_package_id AND is_active = true;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_package');
  END IF;

  -- Insertar el anuncio
  INSERT INTO public.advertisements (
    advertiser_id,
    type,
    title,
    subtitle,
    button_text,
    media_url,
    media_type,
    package_id,
    target_group_id,
    link_type,
    link_id,
    target_location_type,
    target_locations,
    duration_seconds,
    youtube_url,
    status,
    starts_at,
    ends_at
  ) VALUES (
    v_uid,
    p_type,
    p_title,
    p_subtitle,
    COALESCE(p_button_text, 'Contratar'),
    p_media_url,
    COALESCE(p_media_type, 'none'),
    p_package_id,
    p_target_group_id,
    v_resolved_link_type,
    CASE WHEN v_resolved_link_type = 'group' THEN p_link_id::UUID ELSE NULL END,
    COALESCE(p_location_type, 'national'),
    p_locations,
    p_duration_seconds,
    v_resolved_youtube,
    'pending_review',
    NOW(),
    NOW() + (v_package.duration_days || ' days')::INTERVAL
  )
  RETURNING id INTO v_ad_id;

  -- Si es sponsored_group, crear registro inactivo en sponsored_groups
  IF p_type = 'sponsored_group' THEN
    INSERT INTO public.sponsored_groups (group_id, advertiser_id, ad_id, is_active, ends_at)
    VALUES (p_target_group_id, v_uid, v_ad_id, false, NOW() + (v_package.duration_days || ' days')::INTERVAL)
    ON CONFLICT (group_id, advertiser_id) DO UPDATE
      SET ends_at = EXCLUDED.ends_at, is_active = false, ad_id = EXCLUDED.ad_id;
  END IF;

  RETURN jsonb_build_object(
    'ok',       true,
    'ad_id',    v_ad_id,
    'amount',   v_package.price,
    'type',     p_type,
    'group_id', p_target_group_id
  );
END;
$$;

-- ── 4. Actualizar get_active_banner_ads para devolver youtube_url ──────────

DROP FUNCTION IF EXISTS public.get_active_banner_ads(TEXT);

CREATE OR REPLACE FUNCTION public.get_active_banner_ads(p_city TEXT DEFAULT NULL)
RETURNS TABLE (
  id              UUID,
  title           TEXT,
  subtitle        TEXT,
  button_text     TEXT,
  media_url       TEXT,
  media_type      TEXT,
  link_type       TEXT,
  link_id         UUID,
  youtube_url     TEXT,
  impressions     INTEGER,
  clicks          INTEGER,
  order_index     INTEGER
)
LANGUAGE sql STABLE SECURITY DEFINER
AS $$
  SELECT
    a.id, a.title, a.subtitle, a.button_text,
    a.media_url, a.media_type,
    a.link_type, a.link_id, a.youtube_url,
    COALESCE(a.impressions, 0),
    COALESCE(a.clicks, 0),
    COALESCE(a.order_index, 0)
  FROM public.advertisements a
  WHERE a.status = 'active'
    AND a.type   = 'banner_home'
    AND (a.ends_at IS NULL OR a.ends_at > NOW())
    AND (
      p_city IS NULL
      OR a.target_location_type = 'national'
      OR (a.target_location_type = 'city'       AND a.target_locations @> to_jsonb(ARRAY[p_city]))
      OR (a.target_location_type = 'multi_city'  AND a.target_locations @> to_jsonb(ARRAY[p_city]))
    )
  ORDER BY a.order_index ASC, a.created_at DESC;
$$;

-- ── 5. Actualizar get_profile_ads para devolver youtube_url ───────────────

DROP FUNCTION IF EXISTS public.get_profile_ads(UUID, TEXT);

CREATE OR REPLACE FUNCTION public.get_profile_ads(
  p_group_id UUID,
  p_city     TEXT DEFAULT NULL
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
  youtube_url TEXT
)
LANGUAGE sql STABLE SECURITY DEFINER
AS $$
  SELECT
    a.id, a.title, a.subtitle, a.button_text,
    a.media_url, a.media_type,
    a.link_type, a.link_id, a.youtube_url
  FROM public.advertisements a
  WHERE a.status = 'active'
    AND a.type   = 'profile_ad'
    AND (a.ends_at IS NULL OR a.ends_at > NOW())
    AND (a.target_group_id IS NULL OR a.target_group_id = p_group_id)
    AND (
      p_city IS NULL
      OR a.target_location_type = 'national'
      OR (a.target_location_type = 'city'       AND a.target_locations @> to_jsonb(ARRAY[p_city]))
      OR (a.target_location_type = 'multi_city'  AND a.target_locations @> to_jsonb(ARRAY[p_city]))
    )
  ORDER BY RANDOM()
  LIMIT 1;
$$;
