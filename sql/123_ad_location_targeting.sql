-- ════════════════════════════════════════════════════════════════════════════
-- 123_ad_location_targeting.sql
-- Segmentación geográfica para el sistema de publicidad.
--
--   1. target_location_type / target_locations en advertisements
--   2. location_scope en ad_packages
--   3. Paquetes por alcance (city / multi_city / national)
--   4. create_advertisement_order() — nuevos parámetros de ubicación
--   5. get_active_banner_ads(p_city)  — filtro por ciudad
--   6. get_profile_ads(p_group_id, p_city) — filtro por ciudad
--   7. get_sponsored_group_ids(p_city)  — filtro por ciudad del grupo
--
-- Regla de compatibilidad:
--   Si target_location_type IS NULL  → anuncio global (se muestra en todas partes)
--   Si target_location_type = 'national' → se muestra en todas partes
--   Si target_location_type = 'city'/'multi_city' → se muestra solo si
--     p_city es NULL  (el caller no sabe la ciudad)  O
--     p_city está en target_locations
--
-- Ejecutar DESPUÉS de 122_boost_system.sql
-- ════════════════════════════════════════════════════════════════════════════


-- ── 1. Columnas en advertisements ────────────────────────────────────────────

ALTER TABLE public.advertisements
  ADD COLUMN IF NOT EXISTS target_location_type TEXT
    CHECK (target_location_type IN ('city', 'multi_city', 'national'));

ALTER TABLE public.advertisements
  ADD COLUMN IF NOT EXISTS target_locations JSONB;
  -- Ejemplos: '["Guadalajara"]'  '["CDMX","Monterrey","Guadalajara"]'
  -- NULL = sin restricción geográfica (global)


-- ── 2. location_scope en ad_packages ─────────────────────────────────────────

ALTER TABLE public.ad_packages
  ADD COLUMN IF NOT EXISTS location_scope TEXT DEFAULT 'national'
    CHECK (location_scope IN ('city', 'multi_city', 'national'));

-- Los paquetes existentes quedan con location_scope = 'national' (por el DEFAULT)


-- ── 3. Paquetes por alcance ───────────────────────────────────────────────────
-- Precio referencial: ciudad ≈ 40 %, multi_ciudad ≈ 65 % del precio nacional

INSERT INTO public.ad_packages
  (name, type, duration_days, price, description, is_active, location_scope)
VALUES
  -- Banner Home — ciudad
  ('Banner Ciudad — 7 días',    'banner_home',     7,  119.00, 'Tu anuncio en el inicio, visible solo en tu ciudad — 7 días',   true, 'city'),
  ('Banner Ciudad — 15 días',   'banner_home',    15,  199.00, 'Tu anuncio en el inicio, visible solo en tu ciudad — 15 días',  true, 'city'),
  -- Banner Home — varias ciudades
  ('Banner Multi-ciudad 7d',    'banner_home',     7,  189.00, 'Tu anuncio en el inicio en hasta 5 ciudades — 7 días',          true, 'multi_city'),
  ('Banner Multi-ciudad 15d',   'banner_home',    15,  319.00, 'Tu anuncio en el inicio en hasta 5 ciudades — 15 días',         true, 'multi_city'),

  -- Grupo Destacado — ciudad
  ('Destacado Ciudad — 7 días', 'sponsored_group', 7,   99.00, 'Tu grupo primero en "Destacados" en tu ciudad — 7 días',        true, 'city'),
  ('Destacado Ciudad — 15d',    'sponsored_group',15,  159.00, 'Tu grupo primero en "Destacados" en tu ciudad — 15 días',       true, 'city'),
  -- Grupo Destacado — varias ciudades
  ('Destacado Multi-ciudad 7d', 'sponsored_group', 7,  159.00, 'Tu grupo primero en "Destacados" en hasta 5 ciudades — 7d',     true, 'multi_city'),
  ('Destacado Multi-ciudad 15d','sponsored_group',15,  259.00, 'Tu grupo primero en "Destacados" en hasta 5 ciudades — 15d',    true, 'multi_city'),

  -- Anuncio en Perfil — ciudad
  ('Perfil Ciudad — 7 días',    'profile_ad',      7,   79.00, 'Tu anuncio en perfiles de grupos de tu ciudad — 7 días',        true, 'city'),
  ('Perfil Ciudad — 15 días',   'profile_ad',     15,  129.00, 'Tu anuncio en perfiles de grupos de tu ciudad — 15 días',       true, 'city'),
  -- Anuncio en Perfil — varias ciudades
  ('Perfil Multi-ciudad 7d',    'profile_ad',      7,  129.00, 'Tu anuncio en perfiles de grupos en hasta 5 ciudades — 7d',     true, 'multi_city'),
  ('Perfil Multi-ciudad 15d',   'profile_ad',     15,  209.00, 'Tu anuncio en perfiles de grupos en hasta 5 ciudades — 15d',    true, 'multi_city')
ON CONFLICT DO NOTHING;


-- ── 4. create_advertisement_order — nuevos parámetros de ubicación ────────────

DROP FUNCTION IF EXISTS public.create_advertisement_order(TEXT,TEXT,TEXT,TEXT,TEXT,TEXT,UUID,UUID,TEXT,TEXT,TEXT);
CREATE OR REPLACE FUNCTION public.create_advertisement_order(
  p_type              TEXT,
  p_title             TEXT,
  p_subtitle          TEXT         DEFAULT NULL,
  p_button_text       TEXT         DEFAULT 'Contactar',
  p_media_url         TEXT         DEFAULT NULL,
  p_media_type        TEXT         DEFAULT 'none',
  p_package_id        UUID         DEFAULT NULL,
  p_target_group_id   UUID         DEFAULT NULL,
  p_link_type         TEXT         DEFAULT 'none',
  p_link_url          TEXT         DEFAULT NULL,
  p_button_url        TEXT         DEFAULT NULL,
  p_location_type     TEXT         DEFAULT 'national',  -- 'city' | 'multi_city' | 'national'
  p_locations         JSONB        DEFAULT NULL         -- ["Ciudad1","Ciudad2"]
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_user_id   UUID := auth.uid();
  v_ad_id     UUID;
  v_group_id  UUID;
  v_pkg       RECORD;
  v_loc_type  TEXT;
BEGIN
  IF v_user_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'no_session');
  END IF;

  IF p_type NOT IN ('banner_home', 'sponsored_group', 'profile_ad') THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_type');
  END IF;

  -- Normalizar location_type
  v_loc_type := COALESCE(
    NULLIF(p_location_type, ''),
    'national'
  );

  -- Validar paquete
  IF p_package_id IS NOT NULL THEN
    SELECT * INTO v_pkg FROM public.ad_packages
    WHERE id = p_package_id AND is_active = true;
    IF NOT FOUND THEN
      RETURN jsonb_build_object('ok', false, 'error', 'package_not_found');
    END IF;
    IF v_pkg.type != p_type THEN
      RETURN jsonb_build_object('ok', false, 'error', 'package_type_mismatch');
    END IF;
  END IF;

  -- Para sponsored_group: resolver grupo del anunciante
  IF p_type = 'sponsored_group' THEN
    SELECT id INTO v_group_id FROM public.groups
    WHERE owner_id = v_user_id LIMIT 1;
    IF NOT FOUND THEN
      RETURN jsonb_build_object('ok', false, 'error', 'group_not_found');
    END IF;
  END IF;

  -- Insertar anuncio
  INSERT INTO public.advertisements (
    advertiser_id, package_id, type,
    title, subtitle, button_text, button_url,
    media_url, media_type,
    link_type, link_id, link_url,
    target_group_id,
    target_location_type, target_locations,
    status
  ) VALUES (
    v_user_id, p_package_id, p_type,
    p_title, p_subtitle, p_button_text, p_button_url,
    p_media_url, p_media_type,
    CASE WHEN p_type = 'sponsored_group' THEN 'group' ELSE p_link_type END,
    CASE WHEN p_type = 'sponsored_group' THEN v_group_id ELSE NULL END,
    p_link_url,
    p_target_group_id,
    v_loc_type,
    CASE WHEN v_loc_type = 'national' THEN NULL ELSE p_locations END,
    'pending_review'
  )
  RETURNING id INTO v_ad_id;

  -- Para sponsored_group: crear registro en sponsored_groups (inactivo hasta aprobar)
  IF p_type = 'sponsored_group' AND v_group_id IS NOT NULL AND v_pkg.duration_days IS NOT NULL THEN
    INSERT INTO public.sponsored_groups (
      group_id, advertiser_id, package_id,
      starts_at, ends_at, is_active
    ) VALUES (
      v_group_id, v_user_id, p_package_id,
      now(), now() + (v_pkg.duration_days || ' days')::INTERVAL,
      false
    ) ON CONFLICT DO NOTHING;
  END IF;

  RETURN jsonb_build_object(
    'ok',           true,
    'ad_id',        v_ad_id,
    'amount',       COALESCE(v_pkg.price, 0),
    'type',         p_type,
    'group_id',     v_group_id,
    'location_type', v_loc_type
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.create_advertisement_order(TEXT,TEXT,TEXT,TEXT,TEXT,TEXT,UUID,UUID,TEXT,TEXT,TEXT,TEXT,JSONB) TO authenticated;


-- ── 5. get_active_banner_ads — filtro por ciudad ──────────────────────────────

DROP FUNCTION IF EXISTS public.get_active_banner_ads();
DROP FUNCTION IF EXISTS public.get_active_banner_ads(TEXT);
CREATE OR REPLACE FUNCTION public.get_active_banner_ads(p_city TEXT DEFAULT NULL)
RETURNS TABLE (
  id           UUID,
  title        TEXT,
  subtitle     TEXT,
  tag          TEXT,
  button_text  TEXT,
  media_url    TEXT,
  media_type   TEXT,
  media_offset INT,
  link_type    TEXT,
  link_id      UUID,
  link_url     TEXT,
  order_index  INT
)
LANGUAGE plpgsql
SECURITY DEFINER STABLE
SET search_path = public
AS $$
BEGIN
  PERFORM public.expire_advertisements();
  RETURN QUERY
  SELECT a.id, a.title, a.subtitle, a.tag, a.button_text,
         a.media_url, a.media_type, a.media_offset,
         a.link_type, a.link_id, a.link_url, a.order_index
  FROM   public.advertisements a
  WHERE  a.type   = 'banner_home'
    AND  a.status = 'active'
    AND  (a.starts_at IS NULL OR a.starts_at <= now())
    AND  (a.ends_at   IS NULL OR a.ends_at   >  now())
    AND  (
      -- Sin segmentación: mostrar siempre (fallback global)
      a.target_location_type IS NULL
      OR a.target_location_type = 'national'
      -- Caller no especificó ciudad: mostrar todo
      OR p_city IS NULL
      -- Ciudad del caller está en la lista objetivo
      OR (a.target_locations IS NOT NULL
          AND a.target_locations @> jsonb_build_array(p_city))
    )
  ORDER  BY a.order_index, a.created_at;
END;
$$;

GRANT EXECUTE ON FUNCTION public.get_active_banner_ads(TEXT) TO anon, authenticated;


-- ── 6. get_profile_ads — filtro por ciudad ────────────────────────────────────

DROP FUNCTION IF EXISTS public.get_profile_ads(UUID);
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
  link_url    TEXT,
  button_url  TEXT
)
LANGUAGE plpgsql
SECURITY DEFINER STABLE
SET search_path = public
AS $$
BEGIN
  RETURN QUERY
  SELECT a.id, a.title, a.subtitle, a.button_text,
         a.media_url, a.media_type,
         a.link_url, a.button_url
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
  ORDER  BY a.order_index
  LIMIT  1;
END;
$$;

GRANT EXECUTE ON FUNCTION public.get_profile_ads(UUID, TEXT) TO authenticated;


-- ── 7. get_sponsored_group_ids — filtro por ciudad del grupo ─────────────────
-- Los grupos patrocinados se segmentan por la ciudad del propio grupo.
-- Si p_city = NULL, se devuelven todos (sin filtro).

DROP FUNCTION IF EXISTS public.get_sponsored_group_ids();
DROP FUNCTION IF EXISTS public.get_sponsored_group_ids(TEXT);
CREATE OR REPLACE FUNCTION public.get_sponsored_group_ids(p_city TEXT DEFAULT NULL)
RETURNS TABLE (group_id UUID, ends_at TIMESTAMPTZ)
LANGUAGE plpgsql
SECURITY DEFINER STABLE
SET search_path = public
AS $$
BEGIN
  RETURN QUERY
  SELECT DISTINCT sg.group_id, sg.ends_at
  FROM   public.sponsored_groups sg
  JOIN   public.groups           g  ON g.id = sg.group_id
  WHERE  sg.is_active = true
    AND  sg.ends_at   > now()
    AND  (p_city IS NULL OR g.city ILIKE p_city)
  ORDER  BY sg.ends_at DESC;
END;
$$;

GRANT EXECUTE ON FUNCTION public.get_sponsored_group_ids(TEXT) TO authenticated;


SELECT '123_ad_location_targeting.sql ejecutado ✅' AS status;
SELECT 'Nuevas columnas: target_location_type, target_locations en advertisements' AS cols;
SELECT 'Nueva columna: location_scope en ad_packages' AS pkg_col;
SELECT 'RPCs actualizados: get_active_banner_ads, get_profile_ads, get_sponsored_group_ids' AS rpcs;
SELECT 'Paquetes nuevos: city y multi_city para cada tipo de anuncio' AS packages;
