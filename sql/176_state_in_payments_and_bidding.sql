-- ════════════════════════════════════════════════════════════════════
-- 176_state_in_payments_and_bidding.sql
--
-- OBJETIVO: Asegurar que el estado (estado mexicano) siempre se guarda
-- en bid_orders y recommendation_orders al momento del pago,
-- y que la competencia de bidding se filtra por estado correctamente.
--
-- 1. Agrega columna `state` a bid_orders y recommendation_orders
-- 2. Backfill state desde groups para filas existentes
-- 3. Actualiza create_bid_order para guardar state del grupo
-- 4. Actualiza confirm_bid_payment para also actualizar state en bid_orders
-- 5. Actualiza place_recommendation_order para guardar state del grupo
-- 6. Crea get_bid_competition_by_state — stats de competencia filtradas por estado
-- 7. Scoring: GREATEST(score, 0) en calcMonetizationScore (aplicado en app)
--
-- Seguro: ADD COLUMN IF NOT EXISTS, DROP IF EXISTS antes de CREATE OR REPLACE
-- Ejecutar en Supabase SQL Editor (después de 175_state_filtering_and_images.sql)
-- ════════════════════════════════════════════════════════════════════


-- ── 1. Columnas nuevas en tablas de pagos ────────────────────────────────────

ALTER TABLE public.bid_orders
  ADD COLUMN IF NOT EXISTS state     TEXT;
ALTER TABLE public.bid_orders
  ADD COLUMN IF NOT EXISTS starts_at TIMESTAMPTZ;
ALTER TABLE public.bid_orders
  ADD COLUMN IF NOT EXISTS ends_at   TIMESTAMPTZ;

ALTER TABLE public.recommendation_orders
  ADD COLUMN IF NOT EXISTS state TEXT;

COMMENT ON COLUMN public.bid_orders.state IS
  'Estado mexicano donde el grupo quiere aparecer (se copia de groups.state al crear la orden).';
COMMENT ON COLUMN public.recommendation_orders.state IS
  'Estado mexicano del grupo al momento del pago (se copia de groups.state).';

-- Índices
CREATE INDEX IF NOT EXISTS idx_bid_orders_state ON public.bid_orders (state);
CREATE INDEX IF NOT EXISTS idx_rec_orders_state ON public.recommendation_orders (state);


-- ── 2. Backfill: poblar state desde el grupo para filas existentes ────────────

UPDATE public.bid_orders bo
SET    state = g.state
FROM   public.groups g
WHERE  g.id = bo.group_id
  AND  bo.state IS NULL
  AND  g.state IS NOT NULL;

UPDATE public.recommendation_orders ro
SET    state = g.state
FROM   public.groups g
WHERE  g.id = ro.group_id
  AND  ro.state IS NULL
  AND  g.state IS NOT NULL;


-- ── 3. create_bid_order — guarda state del grupo ─────────────────────────────

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
BEGIN
  IF v_user_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'no_session');
  END IF;

  SELECT id, city, state INTO v_group FROM public.groups WHERE owner_id = v_user_id LIMIT 1;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'group_not_found');
  END IF;

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

  -- Guardar state del grupo en la orden para filtrado posterior
  INSERT INTO public.bid_orders (group_id, user_id, package_id, amount, duration_days, state)
  VALUES (v_group.id, v_user_id, p_package_id, v_amount, v_days, v_group.state)
  RETURNING id INTO v_order_id;

  RETURN jsonb_build_object(
    'ok',           true,
    'order_id',     v_order_id,
    'amount',       v_amount,
    'duration_days', v_days,
    'group_id',     v_group.id,
    'state',        v_group.state
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.create_bid_order(UUID, NUMERIC, INT) TO authenticated;


-- ── 4. confirm_bid_payment — asegurar que state se actualiza también ──────────
-- (La versión de SQL 164 ya hace ingreso a wallet; aquí añadimos el update de state)

DROP FUNCTION IF EXISTS public.confirm_bid_payment(UUID, TEXT);
CREATE OR REPLACE FUNCTION public.confirm_bid_payment(
  p_order_id      UUID,
  p_mp_payment_id TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_order   RECORD;
  v_ends_at TIMESTAMPTZ;
  v_admin   RECORD;
BEGIN
  SELECT bo.*, g.city AS group_city, g.name AS group_name, g.state AS group_state
  INTO   v_order
  FROM   public.bid_orders bo
  LEFT JOIN public.groups g ON g.id = bo.group_id
  WHERE  bo.id = p_order_id;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'order_not_found');
  END IF;

  IF v_order.status = 'paid' THEN
    RETURN jsonb_build_object('ok', true, 'skipped', true);  -- idempotente
  END IF;

  v_ends_at := NOW() + (v_order.duration_days || ' days')::INTERVAL;

  -- Activar puja en el grupo
  UPDATE public.groups
  SET
    bid_amount  = CASE
                    WHEN bid_ends_at IS NOT NULL AND bid_ends_at > NOW()
                    THEN GREATEST(bid_amount, v_order.amount)
                    ELSE v_order.amount
                  END,
    bid_ends_at = CASE
                    WHEN bid_ends_at IS NOT NULL AND bid_ends_at > NOW()
                         AND bid_amount >= v_order.amount
                    THEN bid_ends_at
                    ELSE v_ends_at
                  END
  WHERE id = v_order.group_id;

  -- Marcar orden como pagada y asegurar que state está guardado
  UPDATE public.bid_orders
  SET status        = 'paid',
      mp_payment_id = p_mp_payment_id,
      state         = COALESCE(state, v_order.group_state),  -- backfill si faltaba
      starts_at     = NOW(),
      ends_at       = v_ends_at,
      updated_at    = NOW()
  WHERE id = p_order_id;

  -- Registrar ingreso en wallet de CADA admin (deduplicado)
  FOR v_admin IN SELECT id FROM public.profiles WHERE role = 'admin' LOOP

    INSERT INTO public.wallets (user_id)
    VALUES (v_admin.id)
    ON CONFLICT (user_id) DO NOTHING;

    INSERT INTO public.wallet_transactions
      (user_id, amount, type, status, reference_id, description)
    SELECT
      v_admin.id,
      v_order.amount,
      'bid_income',
      'completed',
      'bid_' || p_order_id,
      'Posicionamiento: ' || COALESCE(v_order.group_name, v_order.group_id::TEXT)
        || CASE WHEN v_order.group_state IS NOT NULL
               THEN ' (' || v_order.group_state || ')'
               ELSE '' END
    WHERE NOT EXISTS (
      SELECT 1 FROM public.wallet_transactions
      WHERE reference_id = 'bid_' || p_order_id
        AND user_id      = v_admin.id
    );

    UPDATE public.wallets
    SET available_balance = available_balance + v_order.amount,
        total_earned      = total_earned      + v_order.amount,
        updated_at        = NOW()
    WHERE user_id = v_admin.id
      AND NOT EXISTS (
        SELECT 1 FROM public.wallet_transactions
        WHERE reference_id = 'bid_' || p_order_id
          AND user_id      = v_admin.id
          AND created_at   < now() - interval '1 second'
      );

  END LOOP;

  RETURN jsonb_build_object(
    'ok',       true,
    'group_id', v_order.group_id,
    'ends_at',  v_ends_at,
    'amount',   v_order.amount,
    'state',    v_order.group_state
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.confirm_bid_payment(UUID, TEXT) TO service_role, authenticated;


-- ── 5. place_recommendation_order — guarda state del grupo ───────────────────

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

  -- Ciudad y estado del grupo
  SELECT city, state INTO v_city, v_state FROM public.groups WHERE id = p_group_id;

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


-- ── 6. get_bid_competition_by_state — stats de competencia filtradas por estado ─
-- Usada por BiddingScreen para obtener posición real del grupo dentro de su estado.

DROP FUNCTION IF EXISTS public.get_bid_competition_by_state(UUID);
CREATE OR REPLACE FUNCTION public.get_bid_competition_by_state(p_group_id UUID)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER STABLE
SET search_path = public
AS $$
DECLARE
  v_group         RECORD;
  v_top_bid       NUMERIC  := 0;
  v_my_position   INT      := NULL;
  v_competitor_count INT   := 0;
  v_gap_to_top    NUMERIC  := NULL;
  v_gap_to_next   NUMERIC  := NULL;
  v_bid_amounts   NUMERIC[];
BEGIN
  SELECT id, city, state, bid_amount, bid_ends_at
  INTO   v_group
  FROM   public.groups
  WHERE  id = p_group_id;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'group_not_found');
  END IF;

  -- Obtener bids activos filtrados por estado (o ciudad si no hay estado)
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
    -- Filtrar por estado si está disponible, si no por ciudad
    AND (
      (v_group.state IS NOT NULL AND g.state IS NOT NULL
         AND LOWER(TRIM(g.state)) = LOWER(TRIM(v_group.state)))
      OR
      (v_group.state IS NULL AND g.city IS NOT NULL
         AND LOWER(TRIM(g.city)) = LOWER(TRIM(v_group.city)))
    );

  -- Calcular posición del grupo dentro de la competencia
  IF v_group.bid_amount > 0 AND v_group.bid_ends_at IS NOT NULL AND v_group.bid_ends_at > NOW() THEN
    SELECT COUNT(*) + 1 INTO v_my_position
    FROM   public.groups g
    WHERE  g.is_active   = true
      AND  g.bid_amount  > v_group.bid_amount
      AND  g.bid_ends_at IS NOT NULL
      AND  g.bid_ends_at > NOW()
      AND  (
        (v_group.state IS NOT NULL AND g.state IS NOT NULL
           AND LOWER(TRIM(g.state)) = LOWER(TRIM(v_group.state)))
        OR
        (v_group.state IS NULL AND g.city IS NOT NULL
           AND LOWER(TRIM(g.city)) = LOWER(TRIM(v_group.city)))
      );
  END IF;

  -- Gap para llegar al top #1
  IF v_top_bid > COALESCE(v_group.bid_amount, 0) THEN
    v_gap_to_top := v_top_bid - COALESCE(v_group.bid_amount, 0) + 1;
  END IF;

  -- Gap para subir una posición
  IF v_my_position IS NOT NULL AND v_my_position > 1 AND array_length(v_bid_amounts, 1) >= v_my_position - 1 THEN
    DECLARE
      v_above_me NUMERIC := v_bid_amounts[v_my_position - 1];
    BEGIN
      IF v_above_me > COALESCE(v_group.bid_amount, 0) THEN
        v_gap_to_next := v_above_me - COALESCE(v_group.bid_amount, 0) + 1;
      END IF;
    END;
  END IF;

  RETURN jsonb_build_object(
    'ok',              true,
    'my_position',     v_my_position,
    'competitor_count', v_competitor_count,
    'top_bid',         v_top_bid,
    'my_bid',          v_group.bid_amount,
    'gap_to_top',      v_gap_to_top,
    'gap_to_next',     v_gap_to_next,
    'bid_amounts',     to_jsonb(v_bid_amounts),
    'filtered_by',     CASE WHEN v_group.state IS NOT NULL THEN 'state' ELSE 'city' END,
    'state',           v_group.state,
    'city',            v_group.city
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.get_bid_competition_by_state(UUID) TO authenticated;


-- ── Verificación ──────────────────────────────────────────────────────────────

SELECT
  'bid_orders' AS tabla,
  COUNT(*) AS total,
  COUNT(state) AS con_estado,
  COUNT(*) FILTER (WHERE status = 'paid') AS pagados
FROM public.bid_orders

UNION ALL

SELECT
  'recommendation_orders',
  COUNT(*),
  COUNT(state),
  COUNT(*) FILTER (WHERE status = 'paid')
FROM public.recommendation_orders;

SELECT '176_state_in_payments_and_bidding.sql ejecutado ✅' AS status;
