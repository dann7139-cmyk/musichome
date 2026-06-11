-- ════════════════════════════════════════════════════════════════════
-- 189_dynamic_pricing.sql
--
-- OBJETIVO: Multiplicador de precio dinámico por estado.
--           Ajusta precios, anuncios y ranking automáticamente
--           según demanda real (bookings, grupos activos, bids).
--
-- Arquitectura:
--   state_demand_cache — tabla de caché, TTL 6 horas
--   refresh_state_demand_cache() — recalcula todo el caché
--   get_dynamic_state_multiplier(state) — lee caché, refresca si es viejo
--   calculate_final_price — actualizado: aplica multiplier
--   get_dynamic_ad_price(state, type) — precio sugerido para anuncios
--   get_recommended_bid(state) — cuánto pagar para ser #1
--
-- Fórmula del multiplier:
--   demand  = events_30d + (active_recs * 2) + (active_bids * 1.5)
--   ratio   = demand / max(active_groups, 1)
--   Si ratio ≥ 1 → raw = 1 + (ratio-1) × 0.08   (mercado caliente)
--   Si ratio < 1 → raw = 1 + (ratio-1) × 0.20   (mercado frío)
--   multiplier = CLAMP(raw, 0.85, 1.30)
--   Estado nuevo (sin datos) → 0.90
--
-- Control de cambios:
--   máximo +30% (multiplier ≤ 1.30)
--   mínimo −15% (multiplier ≥ 0.85)
--   TTL 6 horas → no cambia en cada reserva
--
-- Requiere: 188_state_filter_profiles.sql
-- ════════════════════════════════════════════════════════════════════


-- ── 1. Tabla state_demand_cache ──────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS public.state_demand_cache (
  state           TEXT PRIMARY KEY,
  active_groups   INT          NOT NULL DEFAULT 0,
  events_30d      INT          NOT NULL DEFAULT 0,
  active_bids     INT          NOT NULL DEFAULT 0,
  top_bid_amount  NUMERIC(12,2) NOT NULL DEFAULT 0,
  active_recs     INT          NOT NULL DEFAULT 0,
  demand_score    NUMERIC(10,4) NOT NULL DEFAULT 0,
  supply_score    NUMERIC(10,4) NOT NULL DEFAULT 1,
  multiplier      NUMERIC(5,4)  NOT NULL DEFAULT 1.0000,  -- [0.85, 1.30]
  recommended_bid NUMERIC(12,2) NOT NULL DEFAULT 100,
  refreshed_at    TIMESTAMPTZ   NOT NULL DEFAULT NOW()
);

-- RLS: solo el sistema puede escribir; lectura para authenticated/anon
ALTER TABLE public.state_demand_cache ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "state_demand_read" ON public.state_demand_cache;
CREATE POLICY "state_demand_read"
  ON public.state_demand_cache FOR SELECT
  USING (true);


-- ── 2. refresh_state_demand_cache() ──────────────────────────────────────────
-- Recalcula métricas para todos los estados con datos en los últimos 90 días.
-- Se llama desde get_dynamic_state_multiplier cuando el TTL expira.
-- También puede llamarse manualmente desde el panel admin.

CREATE OR REPLACE FUNCTION public.refresh_state_demand_cache()
RETURNS INT   -- filas actualizadas
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_updated  INT := 0;
  v_state    TEXT;
  v_grps     INT;
  v_evts     INT;
  v_bids     INT;
  v_top_bid  NUMERIC;
  v_recs     INT;
  v_demand   NUMERIC;
  v_supply   NUMERIC;
  v_ratio    NUMERIC;
  v_raw      NUMERIC;
  v_mult     NUMERIC;
  v_rec_bid  NUMERIC;
BEGIN
  -- Iterar sobre cada estado con grupos activos
  FOR v_state IN
    SELECT DISTINCT normalize_state_name(state)
    FROM public.groups
    WHERE is_active = TRUE AND state IS NOT NULL
  LOOP
    -- Grupos activos en el estado
    SELECT COUNT(*) INTO v_grps
    FROM public.groups
    WHERE is_active = TRUE
      AND normalize_state_name(state) = v_state;

    -- Reservas en los últimos 30 días (demanda real)
    SELECT COUNT(*) INTO v_evts
    FROM public.reservations r
    JOIN public.groups g ON g.id = r.group_id
    WHERE normalize_state_name(g.state) = v_state
      AND r.created_at > NOW() - INTERVAL '30 days'
      AND r.status NOT IN ('cancelled', 'rejected', 'expired');

    -- Bids activos (competencia por visibilidad)
    SELECT COUNT(*), COALESCE(MAX(amount), 0)
    INTO   v_bids, v_top_bid
    FROM public.bid_orders
    WHERE normalize_state_name(state) = v_state
      AND status = 'paid'
      AND (ends_at IS NULL OR ends_at > NOW());

    -- Recomendaciones activas
    SELECT COUNT(*) INTO v_recs
    FROM public.recommendation_orders
    WHERE normalize_state_name(state) = v_state
      AND status = 'paid'
      AND (ends_at IS NULL OR ends_at > NOW());

    -- ── Fórmula del multiplier ────────────────────────────────────────────
    -- demand_weighted: pondera eventos > recs > bids
    v_demand := (v_evts * 1.0) + (v_recs * 2.0) + (v_bids * 1.5);
    v_supply := GREATEST(v_grps, 1);
    v_ratio  := v_demand / v_supply;

    -- Sensibilidad asimétrica:
    --   Arriba de 1.0 → +8% por unidad de ratio (sube despacio)
    --   Abajo de 1.0  → -20% por unidad (mercado frío castiga más)
    IF v_ratio >= 1.0 THEN
      v_raw := 1.0 + (v_ratio - 1.0) * 0.08;
    ELSE
      v_raw := 1.0 + (v_ratio - 1.0) * 0.20;
    END IF;

    -- Clamp: nunca más de +30% ni menos de -15%
    v_mult := GREATEST(0.85, LEAST(1.30, ROUND(v_raw, 4)));

    -- Bid recomendado para ser #1: top_bid + max(10%, $50)
    v_rec_bid := v_top_bid + GREATEST(ROUND(v_top_bid * 0.10, 2), 50);

    -- Upsert en caché
    INSERT INTO public.state_demand_cache
      (state, active_groups, events_30d, active_bids, top_bid_amount,
       active_recs, demand_score, supply_score, multiplier, recommended_bid, refreshed_at)
    VALUES
      (v_state, v_grps, v_evts, v_bids, v_top_bid,
       v_recs, v_demand, v_supply, v_mult, v_rec_bid, NOW())
    ON CONFLICT (state) DO UPDATE SET
      active_groups   = EXCLUDED.active_groups,
      events_30d      = EXCLUDED.events_30d,
      active_bids     = EXCLUDED.active_bids,
      top_bid_amount  = EXCLUDED.top_bid_amount,
      active_recs     = EXCLUDED.active_recs,
      demand_score    = EXCLUDED.demand_score,
      supply_score    = EXCLUDED.supply_score,
      multiplier      = EXCLUDED.multiplier,
      recommended_bid = EXCLUDED.recommended_bid,
      refreshed_at    = NOW();

    v_updated := v_updated + 1;

    RAISE NOTICE '[DYN_PRICE] state=% groups=% evts=% bids=% recs=% ratio=% mult=%',
      v_state, v_grps, v_evts, v_bids, v_recs, ROUND(v_ratio,2), v_mult;
  END LOOP;

  RETURN v_updated;
END;
$$;

GRANT EXECUTE ON FUNCTION public.refresh_state_demand_cache() TO authenticated;


-- ── 3. get_dynamic_state_multiplier(state) ───────────────────────────────────
-- Retorna el multiplier actual para el estado dado.
-- Lazy-refresh: si el caché tiene > 6 horas se actualiza solo ese estado.
-- Estado sin datos (nuevo) → 0.90 (descuento de apertura).

-- Nota: esta función es STABLE (solo lectura).
-- Los estados nuevos no se insertan aquí; se crean en refresh_state_demand_cache().
-- Para agregar un estado al caché manualmente: SELECT refresh_state_demand_cache();

DROP FUNCTION IF EXISTS public.get_dynamic_state_multiplier(TEXT);
CREATE OR REPLACE FUNCTION public.get_dynamic_state_multiplier(p_state TEXT)
RETURNS NUMERIC
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_state  TEXT := normalize_state_name(p_state);
  v_mult   NUMERIC;
BEGIN
  IF v_state IS NULL OR TRIM(v_state) = '' THEN
    RETURN 1.0;  -- sin estado → precio base sin ajuste
  END IF;

  SELECT multiplier INTO v_mult
  FROM public.state_demand_cache
  WHERE state = v_state;

  -- Estado no encontrado en caché → descuento de apertura (0.90)
  -- El caché se llena con refresh_state_demand_cache() o cuando el estado
  -- tenga grupos activos en la próxima ejecución del refresh.
  RETURN COALESCE(v_mult, 0.90);
END;
$$;

GRANT EXECUTE ON FUNCTION public.get_dynamic_state_multiplier(TEXT) TO anon, authenticated;


-- ── 4. get_dynamic_ad_price(state, type) ─────────────────────────────────────
-- Retorna el multiplicador de precio para anuncios en ese estado.
-- El frontend lo aplica sobre el precio base del paquete.

DROP FUNCTION IF EXISTS public.get_dynamic_ad_price(TEXT, TEXT);
CREATE OR REPLACE FUNCTION public.get_dynamic_ad_price(
  p_state TEXT,
  p_type  TEXT DEFAULT 'banner_home'
)
RETURNS JSONB
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_state    TEXT    := normalize_state_name(p_state);
  v_mult     NUMERIC := public.get_dynamic_state_multiplier(p_state);
  -- Los anuncios en estados muy calientes son más valiosos → mayor multiplicador
  -- banner_home sube más rápido que profile_ad (más visibilidad)
  v_ad_mult  NUMERIC;
BEGIN
  v_ad_mult := CASE p_type
    WHEN 'banner_home' THEN GREATEST(0.80, LEAST(1.50, v_mult * 1.15))
    WHEN 'profile_ad'  THEN GREATEST(0.80, LEAST(1.40, v_mult * 1.10))
    ELSE v_mult
  END;

  RETURN jsonb_build_object(
    'ok',           true,
    'state',        v_state,
    'type',         p_type,
    'ad_multiplier', ROUND(v_ad_mult, 4),
    'demand_mult',   ROUND(v_mult, 4),
    -- Precio base orientativo por tipo (cliente lo multiplica)
    'base_price',   CASE p_type
                      WHEN 'banner_home' THEN 2000
                      WHEN 'profile_ad'  THEN 800
                      ELSE 500
                    END,
    'suggested_price', ROUND(
                         CASE p_type
                           WHEN 'banner_home' THEN 2000
                           WHEN 'profile_ad'  THEN 800
                           ELSE 500
                         END * v_ad_mult
                       , 2)
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.get_dynamic_ad_price(TEXT, TEXT) TO anon, authenticated;


-- ── 5. get_recommended_bid(state) ────────────────────────────────────────────
-- "Para ser #1 en tu estado, paga aprox $XXX"

DROP FUNCTION IF EXISTS public.get_recommended_bid(TEXT);
CREATE OR REPLACE FUNCTION public.get_recommended_bid(p_state TEXT)
RETURNS JSONB
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_state  TEXT    := normalize_state_name(p_state);
  v_cache  RECORD;
BEGIN
  SELECT * INTO v_cache
  FROM public.state_demand_cache
  WHERE state = v_state;

  IF NOT FOUND THEN
    RETURN jsonb_build_object(
      'ok',             true,
      'state',          v_state,
      'top_bid',        0,
      'recommended_bid', 100,
      'active_bids',    0,
      'message',        '¡Sé el primero en pujar en tu estado!'
    );
  END IF;

  RETURN jsonb_build_object(
    'ok',             true,
    'state',          v_state,
    'top_bid',        v_cache.top_bid_amount,
    'recommended_bid', v_cache.recommended_bid,
    'active_bids',    v_cache.active_bids,
    'multiplier',     v_cache.multiplier,
    'message',        CASE
      WHEN v_cache.active_bids = 0
        THEN '¡Sé el primero en pujar en tu estado!'
      WHEN v_cache.multiplier >= 1.15
        THEN '🔥 Estado caliente — ¡Actúa ya!'
      ELSE '🔝 Para aparecer #1 en tu estado:'
    END
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.get_recommended_bid(TEXT) TO authenticated;


-- ── 6. calculate_final_price — con multiplier de estado ──────────────────────
-- Agrega p_state para ajustar el precio según demanda regional.
-- El grupo SIEMPRE recibe su base_price original.
-- La diferencia (multiplier > 1) va a la plataforma como "demand premium".

-- VOLATILE (no STABLE) porque llama a get_dynamic_state_multiplier que lee
-- state_demand_cache, tabla que se actualiza con refresh_state_demand_cache().
-- Usar STABLE aquí causaría que el planner optimice la llamada y obtenga
-- valores desactualizados en transacciones largas.
DROP FUNCTION IF EXISTS public.calculate_final_price(NUMERIC, TEXT, BOOLEAN);
CREATE OR REPLACE FUNCTION public.calculate_final_price(
  p_base_price NUMERIC,
  p_city       TEXT    DEFAULT NULL,
  p_is_express BOOLEAN DEFAULT FALSE,
  p_state      TEXT    DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_multiplier   NUMERIC;
  v_adj_base     NUMERIC(12,2);
  v_rate         NUMERIC;
  v_commission   NUMERIC(12,2);
  v_express_fee  NUMERIC(12,2);
  v_demand_prem  NUMERIC(12,2);
  v_final        NUMERIC(12,2);
BEGIN
  IF p_base_price IS NULL OR p_base_price < 0 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_base_price');
  END IF;

  -- Multiplier de demanda regional [0.85, 1.30]
  -- Si no se pasa estado o el estado no tiene datos → 1.0 (sin ajuste)
  v_multiplier  := COALESCE(
                     NULLIF(public.get_dynamic_state_multiplier(p_state), 0),
                     1.0
                   );

  -- Base ajustada = lo que el cliente realmente paga al grupo
  -- (el grupo sigue recibiendo p_base_price — el delta va a plataforma)
  v_adj_base    := ROUND(p_base_price * v_multiplier, 2);
  v_demand_prem := ROUND(v_adj_base - p_base_price, 2);   -- puede ser negativo (descuento)

  -- Comisión sobre base ajustada (mercado caliente → más comisión también)
  v_rate        := public.get_commission_rate(v_adj_base);
  v_commission  := ROUND(v_adj_base * v_rate / 100.0, 2);

  -- Express: 15% sobre base ORIGINAL (no ajustada — es un cargo fijo del grupo)
  v_express_fee := CASE WHEN p_is_express
                     THEN ROUND(p_base_price * 0.15, 2)
                     ELSE 0
                   END;

  v_final := v_adj_base + v_commission + v_express_fee;

  RAISE NOTICE '[CALCULATE_FINAL_PRICE] base=% mult=% adj=% rate=% commission=% express=% final=%',
    p_base_price, v_multiplier, v_adj_base, v_rate, v_commission, v_express_fee, v_final;

  RETURN jsonb_build_object(
    'ok',              true,
    'base_price',      p_base_price,
    'multiplier',      v_multiplier,
    'adjusted_base',   v_adj_base,
    'demand_premium',  v_demand_prem,
    'commission_rate', v_rate,
    'commission_amount', v_commission,
    'express_fee',     v_express_fee,
    'final_price',     v_final,
    'group_earnings',  p_base_price    -- grupo siempre recibe su precio base exacto
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.calculate_final_price(NUMERIC, TEXT, BOOLEAN, TEXT) TO authenticated, anon;


-- ── 7. Poblar el caché inicial ────────────────────────────────────────────────

SELECT public.refresh_state_demand_cache() AS estados_actualizados;


-- ── Verificación ──────────────────────────────────────────────────────────────

SELECT
  state,
  active_groups,
  events_30d,
  active_bids,
  active_recs,
  ROUND(demand_score, 1)  AS demand,
  ROUND(supply_score, 0)  AS supply,
  multiplier,
  recommended_bid,
  TO_CHAR(refreshed_at, 'DD Mon HH24:MI') AS refreshed
FROM public.state_demand_cache
ORDER BY multiplier DESC;

-- Test del multiplier
SELECT
  public.get_dynamic_state_multiplier('jalisco')   AS jalisco,
  public.get_dynamic_state_multiplier('cdmx')       AS cdmx,
  public.get_dynamic_state_multiplier('nuevo_leon') AS nuevo_leon;

-- Test del precio final
SELECT public.calculate_final_price(3500, NULL, FALSE, 'jalisco') AS precio_normal;
SELECT public.calculate_final_price(3500, NULL, TRUE,  'jalisco') AS precio_express;

SELECT '189_dynamic_pricing.sql ejecutado ✅' AS status;
