-- ════════════════════════════════════════════════════════════════════
-- 194_international_ads.sql
--
-- OBJETIVO: Soporte de alcance internacional + rotación ponderada.
--
-- 1. advertisements.target_country — nuevo campo TEXT (NULL = sin
--    restricción de país; 'global' = alcance internacional).
--
-- 2. create_advertisement_order — añade parámetro p_target_country
--    y guarda el valor en la nueva columna.
--    Incluye el fix del bug v_pkg de 193 (plan personalizado).
--
-- 3. get_active_banner_ads — reescrita con rotación ponderada:
--      anuncios locales (city / multi_city)   peso 3
--      anuncios nacionales / internacionales  peso 1
--    Así la mezcla real es ≈ 3:1 local vs. nacional.
--    También permite anuncios con target_location_type='international'.
--
-- 4. get_profile_ads — misma lógica de rotación ponderada.
--
-- Requiere: 193_fix_create_ad_order_custom_plan.sql
-- ════════════════════════════════════════════════════════════════════


-- ════════════════════════════════════════════════════════════════════
-- 1. Columna target_country
-- ════════════════════════════════════════════════════════════════════

ALTER TABLE public.advertisements
  ADD COLUMN IF NOT EXISTS target_country TEXT DEFAULT NULL;

CREATE INDEX IF NOT EXISTS idx_advertisements_target_country
  ON public.advertisements(target_country)
  WHERE target_country IS NOT NULL;

COMMENT ON COLUMN public.advertisements.target_country IS
  'NULL = sin restricción; ''global'' = internacional (alcance mundial)';


-- ════════════════════════════════════════════════════════════════════
-- 2. create_advertisement_order — añade p_target_country
-- ════════════════════════════════════════════════════════════════════

-- Eliminar versiones anteriores (17 y 18 parámetros)
DROP FUNCTION IF EXISTS public.create_advertisement_order(TEXT,TEXT,TEXT,TEXT,TEXT,TEXT,UUID,TEXT,UUID,TEXT,JSONB,INT,TEXT,INT,NUMERIC,TEXT,TEXT[]);
DROP FUNCTION IF EXISTS public.create_advertisement_order(TEXT,TEXT,TEXT,TEXT,TEXT,TEXT,UUID,TEXT,UUID,TEXT,JSONB,INT,TEXT,INT,NUMERIC,TEXT,TEXT[],TEXT);

CREATE OR REPLACE FUNCTION public.create_advertisement_order(
  p_type             TEXT,
  p_title            TEXT,
  p_subtitle         TEXT     DEFAULT NULL,
  p_button_text      TEXT     DEFAULT 'Contratar',
  p_media_url        TEXT     DEFAULT NULL,
  p_media_type       TEXT     DEFAULT 'none',
  p_package_id       UUID     DEFAULT NULL,
  p_link_type        TEXT     DEFAULT 'none',
  p_link_id          UUID     DEFAULT NULL,
  p_location_type    TEXT     DEFAULT 'national',
  p_locations        JSONB    DEFAULT NULL,
  p_duration_seconds INT      DEFAULT NULL,
  p_youtube_url      TEXT     DEFAULT NULL,
  p_custom_days      INT      DEFAULT NULL,
  p_total_price      NUMERIC  DEFAULT NULL,
  p_target_state     TEXT     DEFAULT NULL,
  p_target_states    TEXT[]   DEFAULT NULL,
  p_target_country   TEXT     DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_user_id     UUID := auth.uid();
  v_ad_id       UUID;
  v_group_id    UUID;
  v_group_state TEXT;
  v_pkg         RECORD;
  v_total       NUMERIC;
  v_dur_days    INT;
  v_state_norm  TEXT;
  v_states_arr  TEXT[];
BEGIN
  IF v_user_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'no_session');
  END IF;

  IF p_type NOT IN ('banner_home', 'sponsored_group', 'profile_ad') THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_type: ' || COALESCE(p_type, 'null'));
  END IF;

  IF p_package_id IS NOT NULL THEN
    SELECT * INTO v_pkg FROM public.ad_packages
    WHERE id = p_package_id AND is_active = true;
    IF NOT FOUND THEN
      RETURN jsonb_build_object('ok', false, 'error', 'package_not_found');
    END IF;
  END IF;

  -- Resolver grupo + estado del anunciante
  SELECT id, state INTO v_group_id, v_group_state
  FROM   public.groups
  WHERE  owner_id = v_user_id
  LIMIT  1;

  -- target_state (single, backward compat)
  IF p_type = 'sponsored_group' THEN
    v_state_norm := normalize_state_name(v_group_state);
  ELSE
    v_state_norm := normalize_state_name(
      COALESCE(NULLIF(TRIM(COALESCE(p_target_state, '')), ''), v_group_state)
    );
  END IF;

  -- target_states (array, solo banner/profile, no internacional)
  IF p_type IN ('banner_home', 'profile_ad')
     AND COALESCE(p_location_type, 'national') <> 'international'
     AND p_target_states IS NOT NULL
     AND array_length(p_target_states, 1) > 0
  THEN
    SELECT ARRAY(
      SELECT normalize_state_name(s)
      FROM   unnest(p_target_states) AS s
      WHERE  TRIM(s) <> ''
    ) INTO v_states_arr;
    IF array_length(v_states_arr, 1) IS NULL THEN
      v_states_arr := NULL;
    END IF;
  END IF;

  -- FIX: solo acceder a v_pkg si p_package_id IS NOT NULL
  IF p_package_id IS NOT NULL THEN
    v_total    := COALESCE(p_total_price, v_pkg.price, 0);
    v_dur_days := COALESCE(v_pkg.duration_days, p_custom_days, 7);
  ELSE
    v_total    := COALESCE(p_total_price, 0);
    v_dur_days := COALESCE(p_custom_days, 7);
  END IF;

  INSERT INTO public.advertisements (
    advertiser_id, package_id, type, title, subtitle, button_text,
    media_url, media_type, link_type, link_id,
    target_location_type, target_locations, target_state, target_states,
    target_country,
    duration_seconds, youtube_url, custom_days,
    total_price, effective_price,
    status,
    starts_at, ends_at
  ) VALUES (
    v_user_id, p_package_id, p_type, p_title, p_subtitle,
    COALESCE(p_button_text, 'Contratar'),
    p_media_url, COALESCE(p_media_type, 'none'),
    CASE WHEN p_type = 'sponsored_group' THEN 'group'
         ELSE COALESCE(p_link_type, 'none') END,
    CASE WHEN p_type = 'sponsored_group' THEN v_group_id
         ELSE p_link_id END,
    COALESCE(p_location_type, 'national'), p_locations,
    v_state_norm, v_states_arr,
    p_target_country,
    p_duration_seconds,
    CASE WHEN COALESCE(p_link_type, 'none') = 'video' THEN p_youtube_url ELSE NULL END,
    p_custom_days,
    v_total, v_total,
    'pending_payment',
    NOW(),
    NOW() + (v_dur_days || ' days')::INTERVAL
  )
  RETURNING id INTO v_ad_id;

  IF p_type = 'sponsored_group' AND v_group_id IS NOT NULL THEN
    INSERT INTO public.sponsored_groups (group_id, advertiser_id, starts_at, ends_at, is_active)
    VALUES (v_group_id, v_user_id, NOW(), NOW() + (v_dur_days || ' days')::INTERVAL, false)
    ON CONFLICT DO NOTHING;
  END IF;

  RETURN jsonb_build_object(
    'ok',     true,
    'ad_id',  v_ad_id,
    'state',  v_state_norm,
    'states', v_states_arr,
    'total',  v_total
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.create_advertisement_order(
  TEXT,TEXT,TEXT,TEXT,TEXT,TEXT,UUID,TEXT,UUID,TEXT,JSONB,INT,TEXT,INT,NUMERIC,TEXT,TEXT[],TEXT
) TO authenticated;


-- ════════════════════════════════════════════════════════════════════
-- 3. get_active_banner_ads — rotación ponderada local vs. nacional
-- ════════════════════════════════════════════════════════════════════

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
    a.link_type, a.link_id,
    a.duration_seconds, a.order_index,
    a.is_free
  FROM   public.advertisements a
  LEFT JOIN public.ad_packages pkg ON pkg.id = a.package_id
  WHERE  a.type   = 'banner_home'
    AND  a.status = 'active'
    AND  (a.starts_at IS NULL OR a.starts_at <= now())
    AND  (a.ends_at   IS NULL OR a.ends_at   >  now())
    -- Filtro de ciudad / alcance
    AND  (
      -- nacionales e internacionales siempre pasan
      a.target_location_type IS NULL
      OR a.target_location_type IN ('national', 'international')
      -- sin ciudad proporcionada: mostrar todos
      OR p_city IS NULL
      -- locales: deben incluir la ciudad del usuario
      OR (a.target_location_type IN ('city', 'multi_city')
          AND a.target_locations IS NOT NULL
          AND a.target_locations @> jsonb_build_array(p_city))
    )
    -- Filtro de estado
    AND  (
      p_state IS NULL
      OR (a.target_states IS NULL AND a.target_state IS NULL)
      OR (a.target_states IS NOT NULL
          AND normalize_state_name(p_state) = ANY(a.target_states))
      OR (a.target_states IS NULL AND a.target_state IS NOT NULL
          AND a.target_state = normalize_state_name(p_state))
    )
  ORDER BY
    -- Anuncios pagados siempre antes que gratuitos
    a.is_free ASC,
    -- Rotación ponderada: locales ×3 de probabilidad vs. nacionales
    -- Esto produce una mezcla ≈ 3:1 local vs. nacional en cada carga.
    (
      CASE
        WHEN a.target_location_type IN ('city', 'multi_city')
             AND p_city IS NOT NULL
             AND a.target_locations IS NOT NULL
             AND a.target_locations @> jsonb_build_array(p_city)
        THEN 3.0   -- local: peso alto
        ELSE 1.0   -- nacional / internacional: peso base
      END
    ) * RANDOM() DESC,
    -- Desempate por precio del paquete (mayor inversión = más visible en igualdad)
    COALESCE(pkg.price, 0) DESC,
    a.order_index ASC,
    a.starts_at   ASC;
END;
$$;

GRANT EXECUTE ON FUNCTION public.get_active_banner_ads(TEXT, TEXT) TO anon, authenticated;


-- ════════════════════════════════════════════════════════════════════
-- 4. get_profile_ads — rotación ponderada local vs. nacional
-- ════════════════════════════════════════════════════════════════════

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
    a.link_type, a.link_id,
    a.is_free
  FROM   public.advertisements a
  WHERE  a.type   = 'profile_ad'
    AND  a.status = 'active'
    AND  (a.target_group_id IS NULL OR a.target_group_id = p_group_id)
    AND  (a.starts_at IS NULL OR a.starts_at <= now())
    AND  (a.ends_at   IS NULL OR a.ends_at   >  now())
    -- Filtro de ciudad / alcance
    AND  (
      a.target_location_type IS NULL
      OR a.target_location_type IN ('national', 'international')
      OR p_city IS NULL
      OR (a.target_location_type IN ('city', 'multi_city')
          AND a.target_locations IS NOT NULL
          AND a.target_locations @> jsonb_build_array(p_city))
    )
    -- Filtro de estado
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


-- ════════════════════════════════════════════════════════════════════
-- Verificación
-- ════════════════════════════════════════════════════════════════════

SELECT '194_international_ads.sql ejecutado ✅' AS status;
