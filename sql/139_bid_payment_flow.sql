-- ============================================================
-- 139 – Bid payment flow
-- Adds bid_orders table + create_bid_order + confirm_bid_payment
-- so bidding goes through Mercado Pago instead of activating directly.
-- ============================================================

-- 1. Tabla de órdenes de puja
CREATE TABLE IF NOT EXISTS public.bid_orders (
  id            UUID        DEFAULT gen_random_uuid() PRIMARY KEY,
  group_id      UUID        NOT NULL REFERENCES public.groups(id) ON DELETE CASCADE,
  user_id       UUID        NOT NULL,
  package_id    UUID        REFERENCES public.bid_packages(id),
  amount        NUMERIC     NOT NULL CHECK (amount > 0),
  duration_days INT         NOT NULL CHECK (duration_days >= 1),
  status        TEXT        NOT NULL DEFAULT 'pending_payment'
                            CHECK (status IN ('pending_payment', 'paid', 'failed')),
  mp_payment_id TEXT,
  created_at    TIMESTAMPTZ DEFAULT NOW(),
  updated_at    TIMESTAMPTZ DEFAULT NOW()
);

ALTER TABLE public.bid_orders ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "bid_orders_owner" ON public.bid_orders;
CREATE POLICY "bid_orders_owner" ON public.bid_orders
  FOR ALL USING (user_id = auth.uid());


-- 2. create_bid_order — crea el registro de orden antes de pagar
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
  v_group_id UUID;
  v_pkg      RECORD;
  v_amount   NUMERIC;
  v_days     INT;
  v_order_id UUID;
BEGIN
  IF v_user_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'no_session');
  END IF;

  SELECT id INTO v_group_id FROM public.groups WHERE owner_id = v_user_id LIMIT 1;
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

  INSERT INTO public.bid_orders (group_id, user_id, package_id, amount, duration_days)
  VALUES (v_group_id, v_user_id, p_package_id, v_amount, v_days)
  RETURNING id INTO v_order_id;

  RETURN jsonb_build_object(
    'ok',          true,
    'order_id',    v_order_id,
    'amount',      v_amount,
    'duration_days', v_days,
    'group_id',    v_group_id
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.create_bid_order(UUID, NUMERIC, INT) TO authenticated;


-- 3. confirm_bid_payment — activa la puja cuando el pago es aprobado
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
BEGIN
  SELECT * INTO v_order FROM public.bid_orders WHERE id = p_order_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'order_not_found');
  END IF;

  IF v_order.status = 'paid' THEN
    RETURN jsonb_build_object('ok', true, 'skipped', true); -- idempotente
  END IF;

  v_ends_at := NOW() + (v_order.duration_days || ' days')::INTERVAL;

  -- Activar la puja en el grupo (misma lógica que place_bid)
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

  -- Marcar orden como pagada
  UPDATE public.bid_orders
  SET status = 'paid', mp_payment_id = p_mp_payment_id, updated_at = NOW()
  WHERE id = p_order_id;

  RETURN jsonb_build_object(
    'ok',       true,
    'group_id', v_order.group_id,
    'ends_at',  v_ends_at
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.confirm_bid_payment(UUID, TEXT) TO service_role;
