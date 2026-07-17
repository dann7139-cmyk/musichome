-- ============================================================
-- sql/499_ad_capacity_and_fixes.sql
-- 📣 CUPOS DE PUBLICIDAD POR ESTADO + arreglos (2026-07-17)
--
--  1. get_groups_ranked_by_city: quedaron DOS versiones conviviendo
--     (3 args de sql/480/493 y 4 args con p_country de sql/361).
--     Llamarla sin p_country era AMBIGUO → el explorador en modo
--     regalo podía quedar vacío. Se deja UNA sola función canónica:
--     4 args (p_city, p_state, p_country, p_limit) con castigo de
--     visibilidad (480), boost, filtro de país (361) y Plus EFECTIVO
--     al final (493).
--
--  2. Publicidad internacional arreglada:
--     · target_country='global' no coincidía con ningún país → esos
--       anuncios NO se mostraban a nadie. Ahora 'global' = todos.
--     · Al comprar internacional se guardaba target_state del estado
--       del anunciante → solo se veía en ESE estado. Ahora
--       internacional = sin estado (visible en todo el país objetivo
--       o el mundo).
--
--  3. CUPOS por estado (la publicidad NO choca):
--     · Cada estado tiene sus propios lugares por tipo:
--         banner_home 10 · sponsored_group 10 · profile_ad 20
--       (el carrusel rota, así que caben varios al día)
--     · Nacional/Internacional (sin estado) sale en TODOS los estados
--       → tiene una bolsa aparte y limitada:
--         banner_home 4 · sponsored_group 4 · profile_ad 6
--     · check_ad_availability: la app pregunta ANTES de cobrar; si un
--       estado está lleno se le dice al usuario cuál.
--     · create_advertisement_order rechaza si no hay espacio (el
--       candado real vive en el servidor).
--     · approve_ad respeta el cupo POR MERCADO (antes contaba TODOS
--       los anuncios del país como si compitieran entre sí).
-- ============================================================

BEGIN;

-- ════════════════════════════════════════════════════════════
-- 1. UNA sola get_groups_ranked_by_city (4 args, canónica)
-- ════════════════════════════════════════════════════════════
DROP FUNCTION IF EXISTS public.get_groups_ranked_by_city(TEXT, INT);
DROP FUNCTION IF EXISTS public.get_groups_ranked_by_city(TEXT, TEXT, INT);
DROP FUNCTION IF EXISTS public.get_groups_ranked_by_city(TEXT, TEXT, TEXT, INT);

CREATE OR REPLACE FUNCTION public.get_groups_ranked_by_city(
  p_city    TEXT,
  p_state   TEXT DEFAULT NULL,
  p_country TEXT DEFAULT NULL,
  p_limit   INT  DEFAULT 50
)
RETURNS TABLE (
  id                    UUID,
  name                  TEXT,
  genre                 TEXT,
  city                  TEXT,
  state                 TEXT,
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
  is_local              BOOLEAN,
  is_plus_active        BOOLEAN
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
    g.state,
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
    (v_city_norm IS NULL OR normalize_city_name(g.city) = v_city_norm) AS is_local,
    -- 🏆 Plus EFECTIVO (activo Y no vencido)
    (COALESCE(g.is_plus_active, false)
      AND (g.plus_expires_at IS NULL OR g.plus_expires_at > now())) AS is_plus_active
  FROM public.groups g
  WHERE g.is_active = true
    AND (
      v_city_norm IS NULL
      OR normalize_city_name(g.city) = v_city_norm
      OR EXISTS (
        SELECT 1
        FROM jsonb_array_elements_text(COALESCE(g.service_cities, '[]'::JSONB)) sc(city_name)
        WHERE normalize_city_name(sc.city_name) = v_city_norm
      )
    )
    AND (
      v_state_norm IS NULL
      OR g.state IS NULL
      OR normalize_state_name(g.state) = v_state_norm
    )
    -- Filtro país (de sql/361): g.country NULL = legacy → visible en todos
    AND (
      v_country_norm IS NULL
      OR g.country IS NULL
      OR normalize_state_name(g.country) = v_country_norm
    )
  ORDER BY
    (g.visibility_penalty_until IS NOT NULL AND g.visibility_penalty_until > now()) ASC,
    (v_city_norm IS NULL OR normalize_city_name(g.city) = v_city_norm) DESC,
    (g.bid_ends_at IS NOT NULL AND g.bid_ends_at > now()
      AND COALESCE(g.bid_amount, 0) > 0) DESC,
    COALESCE(g.bid_amount, 0) DESC,
    COALESCE(g.boost_score, 0) DESC,
    (COALESCE(g.is_plus_active, false)
      AND (g.plus_expires_at IS NULL OR g.plus_expires_at > now())) DESC,
    COALESCE(g.rating, 0) DESC,
    COALESCE(g.total_reviews, 0) DESC,
    g.created_at DESC
  LIMIT p_limit;
END;
$$;

GRANT EXECUTE ON FUNCTION public.get_groups_ranked_by_city(TEXT, TEXT, TEXT, INT)
  TO anon, authenticated;

-- ════════════════════════════════════════════════════════════
-- 2a. get_active_banner_ads v5 — 'global' = todos los países
-- ════════════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION public.get_active_banner_ads(
  p_city    TEXT DEFAULT NULL,
  p_state   TEXT DEFAULT NULL,
  p_country TEXT DEFAULT NULL
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
    -- País: NULL o 'global' = todos (FIX: 'global' no coincidía con nadie)
    AND  (
      a.target_country IS NULL
      OR LOWER(a.target_country) = 'global'
      OR p_country IS NULL
      OR LOWER(a.target_country) = LOWER(p_country)
    )
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

-- ════════════════════════════════════════════════════════════
-- 3. CUPOS: helper de límites + disponibilidad
-- ════════════════════════════════════════════════════════════

-- Límite de anuncios VISIBLES por estado, por tipo
CREATE OR REPLACE FUNCTION public.ad_state_limit(p_type TEXT)
RETURNS INT LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE p_type
    WHEN 'banner_home'     THEN 10
    WHEN 'sponsored_group' THEN 10
    WHEN 'profile_ad'      THEN 20
    ELSE 10
  END;
$$;

-- Límite de la bolsa nacional/internacional (sin estado → sale en TODOS)
CREATE OR REPLACE FUNCTION public.ad_global_limit(p_type TEXT)
RETURNS INT LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE p_type
    WHEN 'banner_home'     THEN 4
    WHEN 'sponsored_group' THEN 4
    WHEN 'profile_ad'      THEN 6
    ELSE 4
  END;
$$;

-- ¿Hay lugar para un anuncio nuevo?
--  p_states: estados objetivo (o NULL si nacional/internacional)
--  Ocupan lugar: anuncios active + pending_review (ya pagados o en
--  proceso). pending_payment NO aparta lugar (carritos abandonados).
CREATE OR REPLACE FUNCTION public.check_ad_availability(
  p_type   TEXT,
  p_states TEXT[] DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_state_limit  INT := ad_state_limit(p_type);
  v_global_limit INT := ad_global_limit(p_type);
  v_global_cnt   INT;
  v_full         TEXT[] := '{}';
  v_st           TEXT;
  v_st_norm      TEXT;
  v_cnt          INT;
BEGIN
  IF p_type NOT IN ('banner_home', 'sponsored_group', 'profile_ad') THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_type');
  END IF;

  -- Bolsa nacional/internacional (anuncios sin estado: visibles en todos)
  SELECT COUNT(*) INTO v_global_cnt
  FROM advertisements a
  WHERE a.type = p_type
    AND a.status IN ('active', 'pending_review')
    AND (a.ends_at IS NULL OR a.ends_at > NOW())
    AND a.target_states IS NULL
    AND a.target_state IS NULL;

  IF p_states IS NULL OR array_length(p_states, 1) IS NULL THEN
    -- El anuncio nuevo es nacional/internacional
    IF v_global_cnt >= v_global_limit THEN
      RETURN jsonb_build_object(
        'ok', false, 'error', 'no_capacity',
        'scope', 'global',
        'used', v_global_cnt, 'limit', v_global_limit
      );
    END IF;
    RETURN jsonb_build_object('ok', true, 'scope', 'global',
      'used', v_global_cnt, 'limit', v_global_limit);
  END IF;

  -- El anuncio nuevo apunta a estados concretos: revisar cada uno.
  -- Visible en el estado X = lo apunta directamente O es nacional/int'l.
  FOREACH v_st IN ARRAY p_states LOOP
    v_st_norm := normalize_state_name(v_st);
    SELECT COUNT(*) INTO v_cnt
    FROM advertisements a
    WHERE a.type = p_type
      AND a.status IN ('active', 'pending_review')
      AND (a.ends_at IS NULL OR a.ends_at > NOW())
      AND (
        (a.target_states IS NULL AND a.target_state IS NULL)      -- nacional/int'l
        OR (a.target_states IS NOT NULL AND v_st_norm = ANY(a.target_states))
        OR (a.target_states IS NULL AND a.target_state = v_st_norm)
      );
    IF v_cnt >= v_state_limit THEN
      v_full := array_append(v_full, v_st);
    END IF;
  END LOOP;

  IF array_length(v_full, 1) IS NOT NULL THEN
    RETURN jsonb_build_object(
      'ok', false, 'error', 'no_capacity',
      'scope', 'state',
      'full_states', to_jsonb(v_full),
      'limit', v_state_limit
    );
  END IF;

  RETURN jsonb_build_object('ok', true, 'scope', 'state', 'limit', v_state_limit);
END;
$$;

GRANT EXECUTE ON FUNCTION public.check_ad_availability(TEXT, TEXT[]) TO authenticated;

-- ════════════════════════════════════════════════════════════
-- 4. create_advertisement_order v4:
--    · internacional → SIN estado (visible en todo el país/mundo)
--    · candado de cupo server-side (no_capacity + estados llenos)
-- ════════════════════════════════════════════════════════════
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
  v_floor       NUMERIC;
  v_dur_days    INT;
  v_state_norm  TEXT;
  v_states_arr  TEXT[];
  v_check_states TEXT[];
  v_avail       JSONB;
  v_intl        BOOLEAN := COALESCE(p_location_type, 'national') = 'international';
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

  SELECT id, state INTO v_group_id, v_group_state
  FROM   public.groups
  WHERE  owner_id = v_user_id
  LIMIT  1;

  -- 🌎 INTERNACIONAL: sin estado — visible en todo el país objetivo (o
  -- 'global' = el mundo). Antes heredaba el estado del anunciante y el
  -- anuncio "internacional" solo se veía en UN estado.
  IF v_intl THEN
    v_state_norm := NULL;
    v_states_arr := NULL;
  ELSE
    IF p_type = 'sponsored_group' THEN
      v_state_norm := normalize_state_name(v_group_state);
    ELSE
      v_state_norm := normalize_state_name(
        COALESCE(NULLIF(TRIM(COALESCE(p_target_state, '')), ''), v_group_state)
      );
    END IF;

    IF p_type IN ('banner_home', 'profile_ad')
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
  END IF;

  -- 🚦 CUPO: ¿hay lugar donde va a salir este anuncio?
  v_check_states := COALESCE(v_states_arr,
    CASE WHEN v_state_norm IS NOT NULL THEN ARRAY[v_state_norm] ELSE NULL END);
  v_avail := check_ad_availability(p_type, v_check_states);
  IF NOT COALESCE((v_avail->>'ok')::BOOLEAN, false) THEN
    RETURN v_avail;  -- {ok:false, error:'no_capacity', full_states/scope...}
  END IF;

  IF p_package_id IS NOT NULL THEN
    v_total    := COALESCE(p_total_price, v_pkg.price, 0);
    v_dur_days := COALESCE(v_pkg.duration_days, p_custom_days, 7);
  ELSE
    v_total    := COALESCE(p_total_price, 0);
    v_dur_days := COALESCE(p_custom_days, 7);
  END IF;

  -- 🔒 Piso server-side (sql/496)
  v_floor := ad_price_floor(p_type, p_package_id, p_custom_days);
  IF v_total < v_floor THEN
    RETURN jsonb_build_object('ok', false, 'error', 'price_below_minimum', 'minimum', v_floor);
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

-- ════════════════════════════════════════════════════════════
-- 5. approve_ad v3 — cupo POR MERCADO (antes contaba todo junto)
-- ════════════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION public.approve_ad(p_id UUID, p_duration_days INT DEFAULT NULL)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_ad     public.advertisements%ROWTYPE;
  v_days   INT;
  v_states TEXT[];
  v_st     TEXT;
  v_cnt    INT;
  v_limit  INT;
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM public.profiles WHERE id = auth.uid() AND role = 'admin'
  ) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_admin');
  END IF;

  SELECT * INTO v_ad FROM public.advertisements WHERE id = p_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_found');
  END IF;

  IF v_ad.status = 'pending_payment' AND COALESCE(v_ad.is_free, false) = false THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_paid_yet');
  END IF;

  v_days := COALESCE(
    p_duration_days,
    NULLIF(GREATEST(EXTRACT(DAY FROM (v_ad.ends_at - v_ad.created_at))::INT, 0), 0),
    CASE v_ad.type
      WHEN 'banner_home'     THEN 7
      WHEN 'sponsored_group' THEN 30
      WHEN 'profile_ad'      THEN 14
      ELSE 7
    END
  );

  -- 🚦 Cupo POR MERCADO: solo cuentan los ACTIVOS que se verían en los
  -- mismos estados que este anuncio (o la bolsa global si es nacional)
  v_states := COALESCE(v_ad.target_states,
    CASE WHEN v_ad.target_state IS NOT NULL THEN ARRAY[v_ad.target_state] ELSE NULL END);

  IF v_states IS NULL THEN
    v_limit := ad_global_limit(v_ad.type);
    SELECT COUNT(*) INTO v_cnt
    FROM public.advertisements a
    WHERE a.type = v_ad.type AND a.status = 'active' AND a.id <> p_id
      AND (a.ends_at IS NULL OR a.ends_at > NOW())
      AND a.target_states IS NULL AND a.target_state IS NULL;
    IF v_cnt >= v_limit THEN
      RETURN jsonb_build_object('ok', false, 'error', 'limit_reached',
        'scope', 'global', 'count', v_cnt, 'limit', v_limit);
    END IF;
  ELSE
    v_limit := ad_state_limit(v_ad.type);
    FOREACH v_st IN ARRAY v_states LOOP
      SELECT COUNT(*) INTO v_cnt
      FROM public.advertisements a
      WHERE a.type = v_ad.type AND a.status = 'active' AND a.id <> p_id
        AND (a.ends_at IS NULL OR a.ends_at > NOW())
        AND (
          (a.target_states IS NULL AND a.target_state IS NULL)
          OR (a.target_states IS NOT NULL AND v_st = ANY(a.target_states))
          OR (a.target_states IS NULL AND a.target_state = v_st)
        );
      IF v_cnt >= v_limit THEN
        RETURN jsonb_build_object('ok', false, 'error', 'limit_reached',
          'scope', 'state', 'state', v_st, 'count', v_cnt, 'limit', v_limit);
      END IF;
    END LOOP;
  END IF;

  UPDATE public.advertisements
  SET status    = 'active',
      starts_at = NOW(),
      ends_at   = NOW() + (v_days || ' days')::INTERVAL,
      updated_at = NOW()
  WHERE id = p_id;

  IF v_ad.type = 'sponsored_group' THEN
    UPDATE public.sponsored_groups
    SET is_active = true,
        ends_at   = NOW() + (v_days || ' days')::INTERVAL
    WHERE id = (
      SELECT id FROM public.sponsored_groups
      WHERE advertiser_id = v_ad.advertiser_id
        AND is_active = false
      ORDER BY created_at DESC
      LIMIT 1
    );
  END IF;

  RETURN jsonb_build_object('ok', true, 'days', v_days);
END;
$$;

COMMIT;

-- ── VERIFICACIÓN ──────────────────────────────────────────────────────────────
SELECT COUNT(*) AS versiones_ranked  -- Esperado: 1 (solo la de 4 argumentos)
FROM pg_proc WHERE proname = 'get_groups_ranked_by_city';

SELECT proname FROM pg_proc
WHERE proname IN ('check_ad_availability', 'ad_state_limit', 'ad_global_limit');
-- Esperado: 3 filas

SELECT prosrc LIKE '%no_capacity%' AS candado_cupo
FROM pg_proc WHERE proname = 'create_advertisement_order';
-- Esperado: true

SELECT prosrc LIKE '%global%' AS banner_global_fix
FROM pg_proc WHERE proname = 'get_active_banner_ads';
-- Esperado: true

SELECT '499_ad_capacity_and_fixes.sql ejecutado ✅' AS status;
