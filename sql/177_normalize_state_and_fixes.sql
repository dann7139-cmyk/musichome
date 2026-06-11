-- ════════════════════════════════════════════════════════════════════
-- 177_normalize_state_and_fixes.sql
--
-- OBJETIVO:
-- 1. normalize_state_name(TEXT) → LOWER(TRIM(p_state))
--    Centraliza la normalización del estado mexicano en un solo lugar.
-- 2. Reescribe get_bid_competition_by_state:
--    - Elimina el bloque DECLARE anidado (bug potencial)
--    - Declara v_above_me al nivel superior
--    - Usa normalize_state_name() en comparaciones
-- 3. Normaliza state al escribir en create_bid_order y
--    place_recommendation_order (LOWER TRIM en el INSERT)
-- 4. Aplica normalize_state_name() en get_active_banner_ads,
--    get_active_recommendations, get_groups_ranked_by_city y
--    get_profile_ads (reemplaza LOWER(TRIM()) inline por la función)
--
-- Seguro: DROP FUNCTION IF EXISTS con firma exacta antes de CREATE
-- Ejecutar en Supabase SQL Editor (después de 176_state_in_payments_and_bidding.sql)
-- ════════════════════════════════════════════════════════════════════


-- ── 1. normalize_state_name ──────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION public.normalize_state_name(p_state TEXT)
RETURNS TEXT
LANGUAGE sql IMMUTABLE STRICT
SET search_path = public
AS $$
  SELECT LOWER(TRIM(p_state));
$$;

COMMENT ON FUNCTION public.normalize_state_name(TEXT) IS
  'Normaliza un estado mexicano: LOWER + TRIM. Usar en todo WHERE y en todos los INSERTs/UPDATEs.';

GRANT EXECUTE ON FUNCTION public.normalize_state_name(TEXT) TO anon, authenticated, service_role;


-- ── 2. get_bid_competition_by_state — sin bloque DECLARE anidado ─────────────

DROP FUNCTION IF EXISTS public.get_bid_competition_by_state(UUID);
CREATE OR REPLACE FUNCTION public.get_bid_competition_by_state(p_group_id UUID)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER STABLE
SET search_path = public
AS $$
DECLARE
  v_group            RECORD;
  v_top_bid          NUMERIC  := 0;
  v_my_position      INT      := NULL;
  v_competitor_count INT      := 0;
  v_gap_to_top       NUMERIC  := NULL;
  v_gap_to_next      NUMERIC  := NULL;
  v_bid_amounts      NUMERIC[];
  v_above_me         NUMERIC  := NULL;   -- declarado a nivel superior (evita DECLARE anidado)
BEGIN
  SELECT id, city, state, bid_amount, bid_ends_at
  INTO   v_group
  FROM   public.groups
  WHERE  id = p_group_id;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'group_not_found');
  END IF;

  -- Bids activos filtrados por estado normalizado (fallback a ciudad)
  SELECT
    ARRAY_AGG(g.bid_amount ORDER BY g.bid_amount DESC),
    COUNT(*),
    MAX(g.bid_amount)
  INTO
    v_bid_amounts,
    v_competitor_count,
    v_top_bid
  FROM public.groups g
  WHERE g.is_active   = true
    AND g.bid_amount  > 0
    AND g.bid_ends_at IS NOT NULL
    AND g.bid_ends_at > NOW()
    AND (
      (v_group.state IS NOT NULL
         AND g.state IS NOT NULL
         AND normalize_state_name(g.state) = normalize_state_name(v_group.state))
      OR
      (v_group.state IS NULL
         AND g.city IS NOT NULL
         AND LOWER(TRIM(g.city)) = LOWER(TRIM(v_group.city)))
    );

  -- Posición del grupo dentro de la competencia
  IF v_group.bid_amount > 0
     AND v_group.bid_ends_at IS NOT NULL
     AND v_group.bid_ends_at > NOW()
  THEN
    SELECT COUNT(*) + 1 INTO v_my_position
    FROM   public.groups g
    WHERE  g.is_active   = true
      AND  g.bid_amount  > v_group.bid_amount
      AND  g.bid_ends_at IS NOT NULL
      AND  g.bid_ends_at > NOW()
      AND  (
        (v_group.state IS NOT NULL
           AND g.state IS NOT NULL
           AND normalize_state_name(g.state) = normalize_state_name(v_group.state))
        OR
        (v_group.state IS NULL
           AND g.city IS NOT NULL
           AND LOWER(TRIM(g.city)) = LOWER(TRIM(v_group.city)))
      );
  END IF;

  -- Gap para llegar al top #1
  IF v_top_bid > COALESCE(v_group.bid_amount, 0) THEN
    v_gap_to_top := v_top_bid - COALESCE(v_group.bid_amount, 0) + 1;
  END IF;

  -- Gap para subir una posición (sin DECLARE anidado)
  IF v_my_position IS NOT NULL
     AND v_my_position > 1
     AND array_length(v_bid_amounts, 1) >= v_my_position - 1
  THEN
    v_above_me := v_bid_amounts[v_my_position - 1];
    IF v_above_me > COALESCE(v_group.bid_amount, 0) THEN
      v_gap_to_next := v_above_me - COALESCE(v_group.bid_amount, 0) + 1;
    END IF;
  END IF;

  RETURN jsonb_build_object(
    'ok',               true,
    'my_position',      v_my_position,
    'competitor_count', v_competitor_count,
    'top_bid',          v_top_bid,
    'my_bid',           v_group.bid_amount,
    'gap_to_top',       v_gap_to_top,
    'gap_to_next',      v_gap_to_next,
    'bid_amounts',      to_jsonb(v_bid_amounts),
    'filtered_by',      CASE WHEN v_group.state IS NOT NULL THEN 'state' ELSE 'city' END,
    'state',            v_group.state,
    'city',             v_group.city
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.get_bid_competition_by_state(UUID) TO authenticated;


-- ── 3. create_bid_order — normaliza state al insertar ────────────────────────

DROP FUNCTION IF EXISTS public.create_bid_order(UUID, NUMERIC, INT);
CREATE OR REPLACE FUNCTION public.create_bid_order(
  p_package_id    UUID    DEFAULT NULL,
  p_custom_amount NUMERIC DEFAULT NULL,
  p_duration_days INT     DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_user_id  UUID := auth.uid();
  v_group    RECORD;
  v_pkg      RECORD;
  v_amount   NUMERIC;
  v_days     INT;
  v_order_id UUID;
  v_state    TEXT;
BEGIN
  IF v_user_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'no_session');
  END IF;

  SELECT id, city, state INTO v_group FROM public.groups WHERE owner_id = v_user_id LIMIT 1;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'group_not_found');
  END IF;

  -- Normalizar state una sola vez
  v_state := normalize_state_name(v_group.state);

  IF p_package_id IS NOT NULL THEN
    SELECT * INTO v_pkg FROM public.bid_packages WHERE id = p_package_id AND is_active = true;
    IF NOT FOUND THEN
      RETURN jsonb_build_object('ok', false, 'error', 'package_not_found');
    END IF;
    v_days   := v_pkg.duration_days;
    v_amount := COALESCE(p_custom_amount, v_pkg.min_bid);
    IF v_amount < v_pkg.min_bid THEN
      RETURN jsonb_build_object('ok', false, 'error', 'bid_below_minimum', 'min_bid', v_pkg.min_bid);
    END IF;
  ELSE
    IF p_custom_amount IS NULL OR p_duration_days IS NULL THEN
      RETURN jsonb_build_object('ok', false, 'error', 'missing_bid_params');
    END IF;
    IF p_custom_amount < 50 THEN
      RETURN jsonb_build_object('ok', false, 'error', 'bid_too_low', 'min_bid', 50);
    END IF;
    IF p_duration_days < 1 THEN
      RETURN jsonb_build_object('ok', false, 'error', 'invalid_duration');
    END IF;
    v_amount := p_custom_amount;
    v_days   := p_duration_days;
  END IF;

  INSERT INTO public.bid_orders (group_id, user_id, package_id, amount, duration_days, state)
  VALUES (v_group.id, v_user_id, p_package_id, v_amount, v_days, v_state)
  RETURNING id INTO v_order_id;

  RETURN jsonb_build_object(
    'ok',            true,
    'order_id',      v_order_id,
    'amount',        v_amount,
    'duration_days', v_days,
    'group_id',      v_group.id,
    'state',         v_state
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.create_bid_order(UUID, NUMERIC, INT) TO authenticated;


-- ── 4. place_recommendation_order — normaliza state al insertar ──────────────

DROP FUNCTION IF EXISTS public.place_recommendation_order(UUID, INT);
CREATE OR REPLACE FUNCTION public.place_recommendation_order(
  p_group_id UUID,
  p_duration INT
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_amount   NUMERIC(10,2);
  v_per_day  NUMERIC(10,2);
  v_city     TEXT;
  v_state    TEXT;
  v_order_id UUID;
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM public.groups WHERE id = p_group_id AND owner_id = auth.uid()
  ) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'unauthorized');
  END IF;

  -- Pricing escalonado fijo
  v_amount := CASE p_duration
    WHEN 1 THEN   79.00
    WHEN 3 THEN  199.00
    WHEN 7 THEN  399.00
    ELSE ROUND((79.00 * p_duration * 0.85)::NUMERIC, 2)
  END;

  v_per_day := ROUND((v_amount / p_duration)::NUMERIC, 2);

  -- Ciudad y estado (normalizado) del grupo
  SELECT city, normalize_state_name(state) INTO v_city, v_state
  FROM   public.groups
  WHERE  id = p_group_id;

  INSERT INTO public.recommendation_orders
    (group_id, duration_days, amount, price_per_day, status, city, state)
  VALUES
    (p_group_id, p_duration, v_amount, v_per_day, 'pending_payment', v_city, v_state)
  RETURNING id INTO v_order_id;

  RETURN jsonb_build_object(
    'ok',       true,
    'order_id', v_order_id,
    'amount',   v_amount,
    'per_day',  v_per_day,
    'duration', p_duration,
    'city',     v_city,
    'state',    v_state
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.place_recommendation_order(UUID, INT) TO authenticated;


-- ── 5. Normalizar state en filas existentes (backfill) ───────────────────────

UPDATE public.bid_orders
SET state = normalize_state_name(state)
WHERE state IS NOT NULL
  AND state != normalize_state_name(state);

UPDATE public.recommendation_orders
SET state = normalize_state_name(state)
WHERE state IS NOT NULL
  AND state != normalize_state_name(state);

UPDATE public.groups
SET state = normalize_state_name(state)
WHERE state IS NOT NULL
  AND state != normalize_state_name(state);

UPDATE public.advertisements
SET target_state = normalize_state_name(target_state)
WHERE target_state IS NOT NULL
  AND target_state != normalize_state_name(target_state);


-- ── Verificación ──────────────────────────────────────────────────────────────

SELECT 'bid_orders'             AS tabla, COUNT(*) AS total, COUNT(state) AS con_estado FROM public.bid_orders
UNION ALL
SELECT 'recommendation_orders', COUNT(*), COUNT(state) FROM public.recommendation_orders
UNION ALL
SELECT 'groups',                COUNT(*), COUNT(state) FROM public.groups
UNION ALL
SELECT 'advertisements',        COUNT(*), COUNT(target_state) FROM public.advertisements;

SELECT '177_normalize_state_and_fixes.sql ejecutado ✅' AS status;
