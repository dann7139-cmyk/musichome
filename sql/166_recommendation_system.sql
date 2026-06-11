-- ════════════════════════════════════════════════════════════════════
-- 166_recommendation_system.sql
-- Sistema de Recomendación: grupos pagan para aparecer en
-- "Recomendado para ti" de la HomeScreen del cliente.
--
-- NUEVA FUENTE DE INGRESO: recommendation_income
-- Separado del bidding (ranking) y de publicidad (ads).
-- PAGO: exclusivamente vía Stripe (PaymentSheet nativo).
--
-- FLUJO:
--   1. Grupo llama place_recommendation_order(group_id, duration_days)
--   2. App llama Edge Function create-recommendation-payment → client_secret
--   3. Stripe PaymentSheet → pago confirmado
--   4. stripe-webhook llama confirm_recommendation_payment(order_id, stripe_pi_id)
--   5. Admin wallet recibe recommendation_income
--   6. HomeScreen llama get_active_recommendations(city, limit)
--      → devuelve grupos activos ordenados por amount DESC
--
-- PRICING (fijo, descuento por volumen):
--   1 día  →  $79
--   3 días → $199  (ahorra ~$38 vs 3×$79)
--   7 días → $399  (ahorra ~$154 vs 7×$79)
--
-- EJECUTAR DESPUÉS DE: 165_wallet_consistency.sql
-- ════════════════════════════════════════════════════════════════════


-- ── 1. Tabla recommendation_orders ──────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS public.recommendation_orders (
  id                  UUID          PRIMARY KEY DEFAULT gen_random_uuid(),
  group_id            UUID          NOT NULL REFERENCES public.groups(id) ON DELETE CASCADE,
  duration_days       INT           NOT NULL DEFAULT 1,
  amount              NUMERIC(10,2) NOT NULL,        -- precio total pagado (Stripe)
  price_per_day       NUMERIC(10,2) NOT NULL,        -- precio por día (información)
  status              TEXT          NOT NULL DEFAULT 'pending_payment',
  stripe_payment_id   TEXT,                          -- Stripe Payment Intent ID
  starts_at           TIMESTAMPTZ,
  ends_at             TIMESTAMPTZ,
  city                TEXT,                          -- ciudad del grupo al comprar

  -- Multiplicadores para pricing dinámico futuro (inactivos por ahora)
  city_multiplier        NUMERIC(4,2) DEFAULT 1.00,
  demand_multiplier      NUMERIC(4,2) DEFAULT 1.00,
  competition_multiplier NUMERIC(4,2) DEFAULT 1.00,

  created_at          TIMESTAMPTZ   NOT NULL DEFAULT now(),
  updated_at          TIMESTAMPTZ   NOT NULL DEFAULT now(),

  CONSTRAINT rec_orders_status_check CHECK (
    status IN ('pending_payment', 'paid', 'expired', 'cancelled')
  )
);

-- Renombrar mp_payment_id → stripe_payment_id si la tabla ya existía con el nombre viejo
DO $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name   = 'recommendation_orders'
      AND column_name  = 'mp_payment_id'
  ) THEN
    ALTER TABLE public.recommendation_orders
      RENAME COLUMN mp_payment_id TO stripe_payment_id;
  END IF;
END $$;

CREATE INDEX IF NOT EXISTS idx_rec_orders_group   ON public.recommendation_orders(group_id);
CREATE INDEX IF NOT EXISTS idx_rec_orders_status  ON public.recommendation_orders(status);
CREATE INDEX IF NOT EXISTS idx_rec_orders_ends_at ON public.recommendation_orders(ends_at);

-- Idempotencia: un stripe_payment_id no puede confirmarse dos veces
CREATE UNIQUE INDEX IF NOT EXISTS idx_rec_orders_stripe
  ON public.recommendation_orders(stripe_payment_id)
  WHERE stripe_payment_id IS NOT NULL;


-- ── 2. Ampliar tipos en wallet_transactions ──────────────────────────────────────

ALTER TABLE public.wallet_transactions
  DROP CONSTRAINT IF EXISTS wallet_transactions_type_check;

ALTER TABLE public.wallet_transactions
  ADD CONSTRAINT wallet_transactions_type_check
  CHECK (type IN (
    'event_earning',
    'extra_hour',
    'withdrawal',
    'commission',
    'adjustment',
    'refund',
    'platform_income',
    'ad_income',
    'bid_income',
    'recommendation_income'   -- ← NUEVO
  ));


-- ── 3. RLS para recommendation_orders ───────────────────────────────────────────

ALTER TABLE public.recommendation_orders ENABLE ROW LEVEL SECURITY;

-- Grupo ve sus propias órdenes
DROP POLICY IF EXISTS "rec_orders_group_select" ON public.recommendation_orders;
CREATE POLICY "rec_orders_group_select"
  ON public.recommendation_orders FOR SELECT
  USING (
    group_id IN (SELECT id FROM public.groups WHERE owner_id = auth.uid())
  );

-- Grupo puede crear sus propias órdenes
DROP POLICY IF EXISTS "rec_orders_group_insert" ON public.recommendation_orders;
CREATE POLICY "rec_orders_group_insert"
  ON public.recommendation_orders FOR INSERT
  WITH CHECK (
    group_id IN (SELECT id FROM public.groups WHERE owner_id = auth.uid())
  );

-- Admin ve y modifica todo
DROP POLICY IF EXISTS "rec_orders_admin_all" ON public.recommendation_orders;
CREATE POLICY "rec_orders_admin_all"
  ON public.recommendation_orders FOR ALL
  USING (EXISTS (
    SELECT 1 FROM public.profiles WHERE id = auth.uid() AND role = 'admin'
  ));

-- Service role sin restricciones (webhooks de Stripe)
DROP POLICY IF EXISTS "rec_orders_service_all" ON public.recommendation_orders;
CREATE POLICY "rec_orders_service_all"
  ON public.recommendation_orders FOR ALL
  USING (auth.role() = 'service_role');


-- ── 4. place_recommendation_order — crea orden pendiente de pago ────────────────

DROP FUNCTION IF EXISTS public.place_recommendation_order(UUID, INT);
CREATE OR REPLACE FUNCTION public.place_recommendation_order(
  p_group_id UUID,
  p_duration INT   -- días: 1, 3 o 7
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
  v_order_id UUID;
BEGIN
  -- Verificar que el caller es dueño del grupo
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
    ELSE ROUND((79.00 * p_duration * 0.85)::NUMERIC, 2)  -- fallback lineal -15%
  END;

  v_per_day := ROUND((v_amount / p_duration)::NUMERIC, 2);

  -- Ciudad del grupo (se guarda para análisis de ingresos por ciudad)
  SELECT city INTO v_city FROM public.groups WHERE id = p_group_id;

  INSERT INTO public.recommendation_orders
    (group_id, duration_days, amount, price_per_day, status, city)
  VALUES
    (p_group_id, p_duration, v_amount, v_per_day, 'pending_payment', v_city)
  RETURNING id INTO v_order_id;

  RETURN jsonb_build_object(
    'ok',       true,
    'order_id', v_order_id,
    'amount',   v_amount,
    'per_day',  v_per_day,
    'duration', p_duration,
    'city',     v_city
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.place_recommendation_order(UUID, INT) TO authenticated;


-- ── 5. confirm_recommendation_payment — confirma pago Stripe, registra ingreso ──
-- Llamado por stripe-webhook (service_role) con el Stripe Payment Intent ID.
-- CTE atómica: si el reference_id ya existe → ON CONFLICT DO NOTHING → no duplica.

DROP FUNCTION IF EXISTS public.confirm_recommendation_payment(UUID, TEXT);
CREATE OR REPLACE FUNCTION public.confirm_recommendation_payment(
  p_order_id        UUID,
  p_mp_payment_id   TEXT DEFAULT NULL   -- recibe el Stripe PI id (parámetro con nombre legacy)
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_order  RECORD;
  v_ends   TIMESTAMPTZ;
  v_admin  RECORD;
  v_ref_id TEXT;
BEGIN
  SELECT ro.*, g.name AS group_name, g.city AS group_city
  INTO   v_order
  FROM   public.recommendation_orders ro
  LEFT JOIN public.groups g ON g.id = ro.group_id
  WHERE  ro.id = p_order_id;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'order_not_found');
  END IF;

  -- Idempotencia: ya fue confirmado
  IF v_order.status = 'paid' THEN
    RETURN jsonb_build_object('ok', true, 'skipped', true, 'reason', 'already_paid');
  END IF;

  v_ends   := NOW() + (v_order.duration_days || ' days')::INTERVAL;
  -- reference_id: Stripe PI id si existe, fallback 'rec_' + order_id
  v_ref_id := COALESCE(NULLIF(p_mp_payment_id, ''), 'rec_' || p_order_id::TEXT);

  -- Activar la orden
  UPDATE public.recommendation_orders
  SET status          = 'paid',
      stripe_payment_id = p_mp_payment_id,
      starts_at       = NOW(),
      ends_at         = v_ends,
      updated_at      = NOW()
  WHERE id = p_order_id;

  -- Registrar recommendation_income en wallet de cada admin
  -- CTE atómica: INSERT ... ON CONFLICT DO NOTHING → RETURNING → UPDATE solo si INSERT ocurrió
  FOR v_admin IN SELECT id FROM public.profiles WHERE role = 'admin' LOOP

    INSERT INTO public.wallets (user_id)
    VALUES (v_admin.id)
    ON CONFLICT (user_id) DO NOTHING;

    WITH inserted AS (
      INSERT INTO public.wallet_transactions
        (user_id, amount, type, status, reference_id, description)
      VALUES (
        v_admin.id,
        v_order.amount,
        'recommendation_income',
        'completed',
        v_ref_id,
        'Recomendación: ' || COALESCE(v_order.group_name, v_order.group_id::TEXT)
          || ' · ' || v_order.duration_days || 'd'
          || CASE WHEN v_order.group_city IS NOT NULL THEN ' (' || v_order.group_city || ')' ELSE '' END
      )
      ON CONFLICT (reference_id) DO NOTHING
      RETURNING amount, user_id
    )
    UPDATE public.wallets w
    SET available_balance = w.available_balance + i.amount,
        total_earned      = w.total_earned      + i.amount,
        updated_at        = NOW()
    FROM inserted i
    WHERE w.user_id = i.user_id;

  END LOOP;

  RETURN jsonb_build_object(
    'ok',        true,
    'order_id',  p_order_id,
    'ends_at',   v_ends,
    'amount',    v_order.amount,
    'reference', v_ref_id
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.confirm_recommendation_payment(UUID, TEXT) TO service_role;
GRANT EXECUTE ON FUNCTION public.confirm_recommendation_payment(UUID, TEXT) TO authenticated;


-- ── 6. get_active_recommendations — para HomeScreen del cliente ──────────────────
-- Grupos con recommendation_orders activas (paid, ends_at > now()),
-- ordenados por amount DESC (mayor pago = primer lugar).

DROP FUNCTION IF EXISTS public.get_active_recommendations(TEXT, INT);
CREATE OR REPLACE FUNCTION public.get_active_recommendations(
  p_city   TEXT DEFAULT NULL,
  p_limit  INT  DEFAULT 5
)
RETURNS TABLE (
  group_id      UUID,
  group_name    TEXT,
  city          TEXT,
  genre         TEXT,
  rating        NUMERIC,
  profile_image TEXT,
  is_verified   BOOLEAN,
  bid_amount    NUMERIC,
  rec_amount    NUMERIC,
  rec_ends_at   TIMESTAMPTZ
)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
BEGIN
  RETURN QUERY
  SELECT
    g.id, g.name, g.city, g.genre, g.rating, g.profile_image, g.is_verified,
    g.bid_amount,
    ro.amount       AS rec_amount,
    ro.ends_at      AS rec_ends_at
  FROM public.recommendation_orders ro
  INNER JOIN public.groups g ON g.id = ro.group_id
  WHERE ro.status = 'paid'
    AND ro.ends_at > NOW()
    AND g.is_active = true
    AND (p_city IS NULL OR LOWER(g.city) = LOWER(p_city))
  ORDER BY ro.amount DESC, ro.ends_at DESC
  LIMIT p_limit;
END;
$$;

GRANT EXECUTE ON FUNCTION public.get_active_recommendations(TEXT, INT)
  TO anon, authenticated, service_role;


-- ── 7. get_my_recommendation_status — estado actual de un grupo ──────────────────

DROP FUNCTION IF EXISTS public.get_my_recommendation_status(UUID);
CREATE OR REPLACE FUNCTION public.get_my_recommendation_status(p_group_id UUID)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_active RECORD;
  v_last   RECORD;
BEGIN
  -- Orden activa (paid y no vencida)
  SELECT ro.id, ro.amount, ro.duration_days, ro.ends_at, ro.starts_at
  INTO   v_active
  FROM   public.recommendation_orders ro
  WHERE  ro.group_id = p_group_id
    AND  ro.status   = 'paid'
    AND  ro.ends_at  > NOW()
  ORDER BY ro.ends_at DESC
  LIMIT 1;

  IF FOUND THEN
    RETURN jsonb_build_object(
      'active',        true,
      'order_id',      v_active.id,
      'amount',        v_active.amount,
      'duration_days', v_active.duration_days,
      'ends_at',       v_active.ends_at,
      'starts_at',     v_active.starts_at
    );
  END IF;

  -- Sin activa → devolver última histórica
  SELECT ro.id, ro.amount, ro.status, ro.ends_at
  INTO   v_last
  FROM   public.recommendation_orders ro
  WHERE  ro.group_id = p_group_id
  ORDER BY ro.created_at DESC
  LIMIT 1;

  RETURN jsonb_build_object(
    'active',     false,
    'last_order', CASE WHEN v_last IS NULL THEN NULL
      ELSE jsonb_build_object(
        'order_id', v_last.id, 'status', v_last.status,
        'amount', v_last.amount, 'ends_at', v_last.ends_at
      )
    END
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.get_my_recommendation_status(UUID) TO authenticated;


-- ── 8. Expirar órdenes vencidas (backfill al ejecutar) ────────────────────────────
UPDATE public.recommendation_orders
SET status = 'expired', updated_at = NOW()
WHERE status = 'paid' AND ends_at <= NOW();


SELECT '166_recommendation_system.sql ejecutado ✅' AS status;
SELECT 'Tabla recommendation_orders + stripe_payment_id (no mp_payment_id)' AS nota_stripe;
SELECT 'Tipo recommendation_income en wallet_transactions' AS nuevo_tipo;
SELECT 'Multiplicadores city/demand/competition preparados (inactivos)' AS futuro;
