-- ════════════════════════════════════════════════════════════════════════════
-- 146_advertising_packages_screen.sql
-- RPCs para la pantalla AdvertisingPackages del grupo.
--
-- FUNCIONES:
--   · get_my_advertising_overview()             — estado actual del grupo
--                                                 (bid + boost + ads activos + ciudad)
--   · get_advertising_packages_for_city(p_city) — todos los paquetes disponibles
--                                                 con slots en tiempo real por ciudad
--
-- USO:
--   Estas RPCs se llaman al abrir AdvertisingPackages (deep-link desde notificaciones
--   de tipo high_demand / ad_space_available / no_ads_in_city / first_ad_reminder).
--
--   1. Al montar la pantalla → get_my_advertising_overview()
--      → muestra bid/boost/ads activos + urgencia de ciudad
--   2. Al mostrar la lista de paquetes → get_advertising_packages_for_city(city)
--      → muestra slots libres en tiempo real + precios
--
-- Ejecutar DESPUÉS de 145_notification_engine.sql
-- ════════════════════════════════════════════════════════════════════════════


-- ── 1. get_my_advertising_overview() ─────────────────────────────────────────
-- Devuelve el estado completo de visibilidad pagada del grupo autenticado:
--   · bid activo (monto, días restantes)
--   · boost activo (score, días restantes)
--   · anuncios activos (sponsored_group, banner_home)
--   · demanda y slots libres en su ciudad
--
-- Solo puede llamarlo el owner del grupo (role = 'group').

DROP FUNCTION IF EXISTS public.get_my_advertising_overview();
CREATE OR REPLACE FUNCTION public.get_my_advertising_overview()
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER STABLE
SET search_path = public
AS $$
DECLARE
  v_uid       UUID := auth.uid();
  v_group     RECORD;
  v_city      TEXT;
  v_demand    JSONB;
  v_slots     JSONB;
  v_ads       JSONB;
  v_bid       JSONB;
  v_boost     JSONB;
BEGIN
  IF v_uid IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_authenticated');
  END IF;

  -- ── Cargar datos del grupo ─────────────────────────────────────────────────
  SELECT g.id,
         g.name,
         g.city,
         g.bid_amount,
         g.bid_ends_at,
         g.boost_score,
         g.boost_ends_at,
         g.rating,
         g.total_reviews,
         g.is_verified
  INTO   v_group
  FROM   public.groups g
  WHERE  g.owner_id  = v_uid
    AND  g.is_active = true
  LIMIT 1;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'group_not_found');
  END IF;

  v_city := v_group.city;

  -- ── Bid activo ─────────────────────────────────────────────────────────────
  IF v_group.bid_ends_at IS NOT NULL
     AND v_group.bid_ends_at > now()
     AND COALESCE(v_group.bid_amount, 0) > 0
  THEN
    v_bid := jsonb_build_object(
      'active',        true,
      'amount',        v_group.bid_amount,
      'ends_at',       v_group.bid_ends_at,
      'days_left',     GREATEST(0, EXTRACT(day FROM v_group.bid_ends_at - now())::INT)
    );
  ELSE
    v_bid := jsonb_build_object('active', false);
  END IF;

  -- ── Boost activo ───────────────────────────────────────────────────────────
  IF v_group.boost_ends_at IS NOT NULL
     AND v_group.boost_ends_at > now()
     AND COALESCE(v_group.boost_score, 0) > 0
  THEN
    v_boost := jsonb_build_object(
      'active',        true,
      'score',         v_group.boost_score,
      'ends_at',       v_group.boost_ends_at,
      'days_left',     GREATEST(0, EXTRACT(day FROM v_group.boost_ends_at - now())::INT)
    );
  ELSE
    v_boost := jsonb_build_object('active', false);
  END IF;

  -- ── Anuncios activos (sponsored_group y banner_home) ──────────────────────
  SELECT jsonb_agg(
    jsonb_build_object(
      'id',       a.id,
      'type',     a.type,
      'title',    a.title,
      'ends_at',  a.ends_at,
      'days_left', GREATEST(0, EXTRACT(day FROM a.ends_at - now())::INT)
    )
  )
  INTO v_ads
  FROM public.advertisements a
  WHERE a.advertiser_id = v_uid
    AND a.status        = 'active'
    AND a.ends_at       > now()
    AND a.type IN ('sponsored_group', 'banner_home', 'profile_ad');

  -- ── Demanda y slots en la ciudad ──────────────────────────────────────────
  IF v_city IS NOT NULL AND trim(v_city) <> '' THEN
    v_demand := public.get_city_demand_score(v_city);
    v_slots  := public.check_city_ad_slots(v_city);
  ELSE
    v_demand := jsonb_build_object('ok', false, 'error', 'no_city');
    v_slots  := jsonb_build_object('ok', false, 'error', 'no_city');
  END IF;

  RETURN jsonb_build_object(
    'ok',           true,
    'group_id',     v_group.id,
    'group_name',   v_group.name,
    'city',         v_city,
    'bid',          v_bid,
    'boost',        v_boost,
    'active_ads',   COALESCE(v_ads, '[]'::JSONB),
    'city_demand',  v_demand,
    'city_slots',   v_slots
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.get_my_advertising_overview() TO authenticated;


-- ── 2. get_advertising_packages_for_city(p_city) ─────────────────────────────
-- Devuelve todos los paquetes de visibilidad disponibles para una ciudad,
-- agrupados por categoría, con slots disponibles en tiempo real.
--
-- Categorías:
--   · bid      → bid_packages    (posicionamiento en resultados)
--   · boost    → boost_packages  (impulso de ranking)
--   · banner   → ad_packages tipo banner_home  (con slots de ciudad)
--   · featured → ad_packages tipo sponsored_group (con slots de ciudad)
--   · profile  → ad_packages tipo profile_ad   (con slots de ciudad)
--
-- Si p_city es NULL: devuelve paquetes sin info de slots.

DROP FUNCTION IF EXISTS public.get_advertising_packages_for_city(TEXT);
CREATE OR REPLACE FUNCTION public.get_advertising_packages_for_city(
  p_city TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER STABLE
SET search_path = public
AS $$
DECLARE
  v_slots       JSONB  := '{}'::JSONB;
  v_bid_pkgs    JSONB;
  v_boost_pkgs  JSONB;
  v_banner_pkgs JSONB;
  v_feat_pkgs   JSONB;
  v_prof_pkgs   JSONB;
BEGIN
  -- Slots de ciudad (si se especificó ciudad)
  IF p_city IS NOT NULL AND trim(p_city) <> '' THEN
    v_slots := public.check_city_ad_slots(p_city);
  END IF;

  -- ── Paquetes de bid ────────────────────────────────────────────────────────
  SELECT jsonb_agg(
    jsonb_build_object(
      'id',           bp.id,
      'category',     'bid',
      'name',         bp.name,
      'description',  bp.description,
      'duration_days',bp.duration_days,
      'price',        bp.min_bid,
      'min_bid',      bp.min_bid
    ) ORDER BY bp.duration_days ASC
  )
  INTO v_bid_pkgs
  FROM public.bid_packages bp
  WHERE bp.is_active = true;

  -- ── Paquetes de boost ──────────────────────────────────────────────────────
  SELECT jsonb_agg(
    jsonb_build_object(
      'id',           bop.id,
      'category',     'boost',
      'name',         bop.name,
      'description',  bop.description,
      'duration_days',bop.duration_days,
      'price',        bop.price,
      'boost_score',  bop.boost_score
    ) ORDER BY bop.duration_days ASC
  )
  INTO v_boost_pkgs
  FROM public.boost_packages bop
  WHERE bop.is_active = true;

  -- ── Paquetes de banner_home (con slots de ciudad) ─────────────────────────
  SELECT jsonb_agg(
    jsonb_build_object(
      'id',           ap.id,
      'category',     'banner',
      'name',         ap.name,
      'description',  ap.description,
      'duration_days',ap.duration_days,
      'price',        ap.price,
      'slots_total',  3,
      'slots_free',   COALESCE((v_slots->>'banner_free')::INT, NULL)
    ) ORDER BY ap.duration_days ASC
  )
  INTO v_banner_pkgs
  FROM public.ad_packages ap
  WHERE ap.is_active = true
    AND ap.type      = 'banner_home';

  -- ── Paquetes de sponsored_group (con slots de ciudad) ─────────────────────
  SELECT jsonb_agg(
    jsonb_build_object(
      'id',           ap.id,
      'category',     'featured',
      'name',         ap.name,
      'description',  ap.description,
      'duration_days',ap.duration_days,
      'price',        ap.price,
      'slots_total',  10,
      'slots_free',   COALESCE((v_slots->>'featured_free')::INT, NULL)
    ) ORDER BY ap.duration_days ASC
  )
  INTO v_feat_pkgs
  FROM public.ad_packages ap
  WHERE ap.is_active = true
    AND ap.type      = 'sponsored_group';

  -- ── Paquetes de profile_ad (con slots de ciudad) ──────────────────────────
  SELECT jsonb_agg(
    jsonb_build_object(
      'id',           ap.id,
      'category',     'profile',
      'name',         ap.name,
      'description',  ap.description,
      'duration_days',ap.duration_days,
      'price',        ap.price,
      'slots_total',  20,
      'slots_free',   COALESCE((v_slots->>'profile_free')::INT, NULL)
    ) ORDER BY ap.duration_days ASC
  )
  INTO v_prof_pkgs
  FROM public.ad_packages ap
  WHERE ap.is_active = true
    AND ap.type      = 'profile_ad';

  RETURN jsonb_build_object(
    'ok',      true,
    'city',    p_city,
    'slots',   v_slots,
    'packages', jsonb_build_object(
      'bid',      COALESCE(v_bid_pkgs,    '[]'::JSONB),
      'boost',    COALESCE(v_boost_pkgs,  '[]'::JSONB),
      'banner',   COALESCE(v_banner_pkgs, '[]'::JSONB),
      'featured', COALESCE(v_feat_pkgs,   '[]'::JSONB),
      'profile',  COALESCE(v_prof_pkgs,   '[]'::JSONB)
    )
  );
END;
$$;

-- Pública: cualquier usuario autenticado puede ver los paquetes disponibles
GRANT EXECUTE ON FUNCTION public.get_advertising_packages_for_city(TEXT) TO anon, authenticated;


-- ── 3. mark_notification_from_ad_seen(p_ntype) ───────────────────────────────
-- Marca como leída la notificación de marketing más reciente de ese tipo
-- para el usuario autenticado.
-- Se llama cuando el grupo llega a AdvertisingPackages desde el deep-link
-- de la notificación, para limpiar el badge.

DROP FUNCTION IF EXISTS public.mark_ad_notification_read(TEXT);
CREATE OR REPLACE FUNCTION public.mark_ad_notification_read(p_ntype TEXT)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid UUID := auth.uid();
  v_updated INT;
BEGIN
  IF v_uid IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_authenticated');
  END IF;

  -- Marcar como leídas las notificaciones de marketing de ese tipo
  UPDATE public.notifications
  SET    read_at    = COALESCE(read_at, now()),
         updated_at = now()
  WHERE  user_id    = v_uid
    AND  type       = p_ntype
    AND  read_at    IS NULL
    AND  (data->>'marketing')::BOOLEAN = true;

  GET DIAGNOSTICS v_updated = ROW_COUNT;

  RETURN jsonb_build_object('ok', true, 'marked_read', v_updated);
END;
$$;

GRANT EXECUTE ON FUNCTION public.mark_ad_notification_read(TEXT) TO authenticated;


SELECT '146_advertising_packages_screen.sql ejecutado ✅' AS status;
SELECT 'RPC: get_my_advertising_overview()              — bid + boost + ads + ciudad para el grupo' AS info;
SELECT 'RPC: get_advertising_packages_for_city(city)    — paquetes con slots en tiempo real' AS info;
SELECT 'RPC: mark_ad_notification_read(ntype)           — limpia badge al abrir desde notificación' AS info;
