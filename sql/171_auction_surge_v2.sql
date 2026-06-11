-- ════════════════════════════════════════════════════════════════════
-- 171_auction_surge_v2.sql
-- 1. Columnas de subasta en recommendation_orders
--    (min_bid_increment, auto_renew)
-- 2. Incluir recommendation_orders en get_city_demand_score
-- 3. get_surge_multiplier(city) — helper para calcular multiplicador
-- 4. Vistas de detección de dinero perdido (orphan wallet)
-- ════════════════════════════════════════════════════════════════════

-- ══════════════════════════════════════════════════════════════════
-- 1. COLUMNAS DE SUBASTA
-- ══════════════════════════════════════════════════════════════════

ALTER TABLE public.recommendation_orders
  ADD COLUMN IF NOT EXISTS min_bid_increment NUMERIC(10,2) DEFAULT 50.00,
  ADD COLUMN IF NOT EXISTS auto_renew        BOOLEAN       DEFAULT FALSE;

COMMENT ON COLUMN public.recommendation_orders.min_bid_increment IS
  'Incremento mínimo para superar la puja actual. Default $50.';
COMMENT ON COLUMN public.recommendation_orders.auto_renew IS
  'Si TRUE, el sistema puede renovar automáticamente al vencer si sigue siendo el más alto.';


-- ══════════════════════════════════════════════════════════════════
-- 2. get_city_demand_score — incluye recommendation_orders activas
-- ══════════════════════════════════════════════════════════════════
-- (Recreamos la función para sumar las recomendaciones pagadas como señal)

CREATE OR REPLACE FUNCTION public.get_city_demand_score(p_city TEXT)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER STABLE
SET search_path = public
AS $$
DECLARE
  v_banners      INT := 0;
  v_sponsored    INT := 0;
  v_bids         INT := 0;
  v_boosts       INT := 0;
  v_reservations INT := 0;
  v_groups       INT := 0;
  v_recs         INT := 0;   -- ← NUEVO: recommendation_orders pagadas activas
  v_score        INT;
  v_level        TEXT;
BEGIN
  IF p_city IS NULL OR trim(p_city) = '' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'city_required');
  END IF;

  SELECT COUNT(*) INTO v_banners
  FROM   public.advertisements
  WHERE  status = 'active' AND type = 'banner_home' AND ends_at > now()
    AND (
      target_location_type IS NULL OR target_location_type = 'national'
      OR (target_locations IS NOT NULL AND target_locations @> jsonb_build_array(p_city))
    );

  SELECT COUNT(*) INTO v_sponsored
  FROM   public.sponsored_groups sg
  JOIN   public.groups g ON g.id = sg.group_id
  WHERE  sg.is_active = true AND sg.ends_at > now()
    AND  g.city ILIKE p_city;

  SELECT COUNT(*) INTO v_bids
  FROM   public.groups
  WHERE  city ILIKE p_city AND bid_ends_at > now()
    AND  COALESCE(bid_amount, 0) > 0;

  SELECT COUNT(*) INTO v_boosts
  FROM   public.groups
  WHERE  city ILIKE p_city AND boost_ends_at > now()
    AND  COALESCE(boost_score, 0) > 0;

  SELECT COUNT(*) INTO v_reservations
  FROM   public.reservations r
  JOIN   public.groups g ON g.id = r.group_id
  WHERE  g.city ILIKE p_city
    AND  r.created_at > now() - INTERVAL '30 days'
    AND  r.status NOT IN ('cancelled', 'expired');

  SELECT COUNT(*) INTO v_groups
  FROM   public.groups
  WHERE  city ILIKE p_city AND is_active = true;

  -- Recommendation orders pagadas y activas en esta ciudad
  SELECT COUNT(*) INTO v_recs
  FROM   public.recommendation_orders ro
  JOIN   public.groups g ON g.id = ro.group_id
  WHERE  ro.status    = 'paid'
    AND  ro.starts_at <= now()
    AND  ro.ends_at   >  now()
    AND  g.city ILIKE p_city;

  -- Score ponderado (recs = 12 puntos: señal fuerte de actividad paga)
  v_score := (v_banners   * 15)
           + (v_sponsored * 10)
           + (v_recs      * 12)
           + (v_bids      *  8)
           + (v_boosts    *  5)
           + (v_reservations * 2)
           + (v_groups    *  1);

  v_level := CASE
    WHEN v_score >= 60 THEN 'very_high'
    WHEN v_score >= 25 THEN 'high'
    WHEN v_score >= 5  THEN 'normal'
    ELSE                    'new'
  END;

  RETURN jsonb_build_object(
    'ok',                  true,
    'city',                p_city,
    'active_banners',      v_banners,
    'active_sponsored',    v_sponsored,
    'active_bids',         v_bids,
    'active_boosts',       v_boosts,
    'active_recs',         v_recs,
    'recent_reservations', v_reservations,
    'active_groups',       v_groups,
    'demand_score',        v_score,
    'demand_level',        v_level
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.get_city_demand_score(TEXT) TO anon, authenticated;


-- ══════════════════════════════════════════════════════════════════
-- 3. get_surge_multiplier(city) — devuelve factor numérico
-- ══════════════════════════════════════════════════════════════════
-- Uso: SELECT * FROM get_surge_multiplier('Guadalajara');
-- Devuelve: { multiplier: 1.5, demand_level: 'very_high' }

DROP FUNCTION IF EXISTS public.get_surge_multiplier(TEXT);
CREATE OR REPLACE FUNCTION public.get_surge_multiplier(p_city TEXT)
RETURNS JSONB
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_demand JSONB;
  v_level  TEXT;
  v_mult   NUMERIC;
BEGIN
  v_demand := public.get_city_demand_score(p_city);
  v_level  := v_demand->>'demand_level';

  v_mult := CASE v_level
    WHEN 'very_high' THEN 1.50
    WHEN 'high'      THEN 1.20
    ELSE                   1.00
  END;

  RETURN jsonb_build_object(
    'multiplier',    v_mult,
    'demand_level',  v_level,
    'demand_score',  (v_demand->>'demand_score')::INT,
    'city',          p_city
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.get_surge_multiplier(TEXT) TO anon, authenticated;


-- ══════════════════════════════════════════════════════════════════
-- 4. DETECCIÓN DE DINERO PERDIDO (orphan wallet)
-- ══════════════════════════════════════════════════════════════════

-- 4a. recommendation_orders pagadas sin wallet_transaction
-- reference_id almacenado: stripe_payment_id ó 'rec_' || order_id
CREATE OR REPLACE VIEW public.v_orphan_rec_orders AS
SELECT
  ro.id,
  ro.group_id,
  g.name AS group_name,
  ro.amount,
  ro.status,
  ro.stripe_payment_id,
  ro.created_at
FROM public.recommendation_orders ro
LEFT JOIN public.groups g ON g.id = ro.group_id
WHERE ro.status = 'paid'
  AND NOT EXISTS (
    SELECT 1 FROM public.wallet_transactions wt
    WHERE wt.type   = 'recommendation_income'
      AND wt.status = 'completed'
      AND (
        wt.reference_id = 'rec_' || ro.id::TEXT
        OR (ro.stripe_payment_id IS NOT NULL AND wt.reference_id = ro.stripe_payment_id)
      )
  );

-- 4b. bid_orders pagadas sin wallet_transaction
-- reference_id almacenado: 'bid_' || order_id
CREATE OR REPLACE VIEW public.v_orphan_bid_orders AS
SELECT
  bo.id,
  bo.group_id,
  g.name AS group_name,
  bo.amount,
  bo.status,
  bo.created_at
FROM public.bid_orders bo
LEFT JOIN public.groups g ON g.id = bo.group_id
WHERE bo.status = 'paid'
  AND NOT EXISTS (
    SELECT 1 FROM public.wallet_transactions wt
    WHERE wt.type        = 'bid_income'
      AND wt.reference_id = 'bid_' || bo.id::TEXT
      AND wt.status       = 'completed'
  );

-- 4c. advertisements activos sin ingreso registrado
-- (advertisements no tiene columna de presupuesto propia; el precio está en ad_packages)
CREATE OR REPLACE VIEW public.v_orphan_advertisements AS
SELECT
  a.id,
  a.title,
  a.type,
  a.status,
  COALESCE(p.price, 0) AS package_price,
  a.created_at
FROM public.advertisements a
LEFT JOIN public.ad_packages p ON p.id = a.package_id
WHERE a.status = 'active'
  AND NOT EXISTS (
    SELECT 1 FROM public.wallet_transactions wt
    WHERE wt.type        = 'ad_income'
      AND wt.reference_id = 'ad_' || a.id::TEXT   -- formato real: 'ad_' || ad_id
      AND wt.status       = 'completed'
  );

-- Para consultar dinero perdido:
-- SELECT * FROM v_orphan_rec_orders;    → recs sin wallet
-- SELECT * FROM v_orphan_bid_orders;    → bids sin wallet
-- SELECT * FROM v_orphan_advertisements; → ads sin ingreso


SELECT '171_auction_surge_v2.sql ejecutado ✅' AS status;
SELECT 'min_bid_increment + auto_renew agregados a recommendation_orders' AS info_1;
SELECT 'get_city_demand_score ahora incluye recs activas (12 pts cada una)' AS info_2;
SELECT 'get_surge_multiplier(city) disponible: 1.5× very_high | 1.2× high | 1.0× normal' AS info_3;
SELECT 'Vistas orphan: v_orphan_rec_orders, v_orphan_bid_orders, v_orphan_advertisements' AS info_4;
