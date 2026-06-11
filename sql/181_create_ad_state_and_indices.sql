-- ════════════════════════════════════════════════════════════════════
-- 181_create_ad_state_and_indices.sql
--
-- OBJETIVO:
-- 1. create_advertisement_order — guardar target_state automáticamente:
--    si el anunciante tiene grupo → usa el state del grupo
--    si no → usa p_target_state si se envía
--    Normaliza con normalize_state_name() antes de guardar
--
-- 2. Índices de performance en tablas principales:
--    - advertisements(status, type, ends_at)
--    - advertisements(target_state)
--    - groups(bid_ends_at) para queries de bidding
--    - groups(city) ya existe; verificamos ends_at en bid/rec orders
--
-- Seguro: DROP FUNCTION IF EXISTS + firma exacta.
--         CREATE INDEX IF NOT EXISTS — no falla si ya existe.
-- Requiere: 180_expose_is_free_in_rpcs.sql
-- ════════════════════════════════════════════════════════════════════


-- ── 1. Índices de performance ────────────────────────────────────────────────

-- Advertisements: la query principal filtra por status + type + ends_at
CREATE INDEX IF NOT EXISTS idx_ads_status_type
  ON public.advertisements (status, type)
  WHERE status = 'active';           -- partial index: solo filas activas

CREATE INDEX IF NOT EXISTS idx_ads_ends_at
  ON public.advertisements (ends_at)
  WHERE ends_at IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_ads_target_state
  ON public.advertisements (target_state)
  WHERE target_state IS NOT NULL;

-- Bid orders: subqueries filtran por group_id + status + ends_at
CREATE INDEX IF NOT EXISTS idx_bid_orders_group_status
  ON public.bid_orders (group_id, status);

CREATE INDEX IF NOT EXISTS idx_bid_orders_ends_at
  ON public.bid_orders (ends_at)
  WHERE ends_at IS NOT NULL;

-- Recommendation orders
CREATE INDEX IF NOT EXISTS idx_rec_orders_ends_at
  ON public.recommendation_orders (ends_at)
  WHERE ends_at IS NOT NULL AND status = 'paid';

-- Groups: bid competition queries
CREATE INDEX IF NOT EXISTS idx_groups_bid_active
  ON public.groups (bid_ends_at, bid_amount)
  WHERE is_active = true AND bid_amount > 0;


-- ── 2. create_advertisement_order — guarda target_state ──────────────────────
-- Agrega p_target_state TEXT DEFAULT NULL.
-- Si el anunciante tiene grupo → usa el state del grupo (fallback automático).
-- Si no → usa p_target_state si se envió.
-- Siempre normaliza con normalize_state_name().

DROP FUNCTION IF EXISTS public.create_advertisement_order(TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, UUID, TEXT, UUID, TEXT, JSONB, INT, TEXT, INT, NUMERIC);
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
  p_target_state     TEXT     DEFAULT NULL   -- NUEVO: estado de segmentación
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_user_id    UUID := auth.uid();
  v_ad_id      UUID;
  v_group_id   UUID;
  v_group_state TEXT;
  v_pkg        RECORD;
  v_total      NUMERIC;
  v_dur_days   INT;
  v_state_norm TEXT;
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

  -- target_state: p_target_state explícito > estado del grupo > NULL (nacional)
  v_state_norm := normalize_state_name(
    COALESCE(NULLIF(TRIM(COALESCE(p_target_state, '')), ''), v_group_state)
  );

  v_total    := COALESCE(p_total_price, v_pkg.price, 0);
  v_dur_days := COALESCE(v_pkg.duration_days, p_custom_days, 7);

  RAISE NOTICE '[create_advertisement_order] type=% state=% pkg=% total=% dur_days=%',
    p_type, v_state_norm, p_package_id, v_total, v_dur_days;

  INSERT INTO public.advertisements (
    advertiser_id,
    package_id,
    type,
    title,
    subtitle,
    button_text,
    media_url,
    media_type,
    link_type,
    link_id,
    target_location_type,
    target_locations,
    target_state,
    duration_seconds,
    youtube_url,
    custom_days,
    total_price,
    effective_price,
    status,
    starts_at,
    ends_at
  ) VALUES (
    v_user_id,
    p_package_id,
    p_type,
    p_title,
    p_subtitle,
    COALESCE(p_button_text, 'Contratar'),
    p_media_url,
    COALESCE(p_media_type, 'none'),
    CASE WHEN p_type = 'sponsored_group' THEN 'group'
         ELSE COALESCE(p_link_type, 'none') END,
    CASE WHEN p_type = 'sponsored_group' THEN v_group_id
         ELSE p_link_id END,
    COALESCE(p_location_type, 'national'),
    p_locations,
    v_state_norm,                                    -- estado normalizado
    p_duration_seconds,
    CASE WHEN COALESCE(p_link_type, 'none') = 'video' THEN p_youtube_url ELSE NULL END,
    p_custom_days,
    v_total,
    v_total,
    'pending_review',
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
    'ok',      true,
    'ad_id',   v_ad_id,
    'state',   v_state_norm,
    'total',   v_total
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.create_advertisement_order(
  TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, UUID, TEXT, UUID, TEXT, JSONB, INT, TEXT, INT, NUMERIC, TEXT
) TO authenticated;


-- ── 3. Backfill target_state en advertisements existentes sin estado ──────────
-- Para anuncios que ya existen y cuyo anunciante tiene un grupo con estado.

UPDATE public.advertisements a
SET    target_state = normalize_state_name(g.state)
FROM   public.groups g
WHERE  g.owner_id   = a.advertiser_id
  AND  a.target_state IS NULL
  AND  g.state IS NOT NULL;


-- ── Verificación ──────────────────────────────────────────────────────────────

SELECT
  target_state IS NOT NULL AS tiene_estado,
  COUNT(*) AS total,
  COUNT(*) FILTER (WHERE status = 'active') AS activos
FROM public.advertisements
GROUP BY 1 ORDER BY 1;

SELECT '181_create_ad_state_and_indices.sql ejecutado ✅' AS status;
