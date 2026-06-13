-- ============================================================
-- sql/329_fix_admin_free_activations_guard.sql
--
-- FIX: los RPCs de activaciones gratis (sql/187) validaban admin
-- con auth.jwt()->'user_metadata'->>'role', pero las cuentas admin
-- tienen el rol en profiles.role (el metadata del JWT no lo trae).
-- Resultado: 'not_admin' al usar "+Gratis → Promociones de Grupo".
--
-- Se redefinen las 4 funciones con el guard estándar del proyecto:
--   service_role (claim del JWT) O profiles.role = 'admin'.
-- Los cuerpos quedan idénticos a sql/187.
-- ============================================================

-- Guard reutilizable (inline en cada función para no crear dependencias)

-- ── 1. admin_activate_sponsored ───────────────────────────────────────────────

CREATE OR REPLACE FUNCTION public.admin_activate_sponsored(
  p_group_id UUID,
  p_days     INT DEFAULT 7
)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_ends_at TIMESTAMPTZ;
BEGIN
  IF NOT (
    (auth.jwt()->>'role') = 'service_role'
    OR EXISTS (SELECT 1 FROM public.profiles WHERE id = auth.uid() AND role = 'admin')
  ) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_admin');
  END IF;

  v_ends_at := CASE WHEN p_days > 0
                 THEN NOW() + (p_days || ' days')::INTERVAL
                 ELSE NULL  -- sin límite
               END;

  INSERT INTO public.sponsored_groups (group_id, advertiser_id, starts_at, ends_at, is_active)
  VALUES (p_group_id, auth.uid(), NOW(), v_ends_at, TRUE)
  ON CONFLICT (group_id) DO UPDATE
    SET is_active  = TRUE,
        starts_at  = NOW(),
        ends_at    = v_ends_at,
        updated_at = NOW();

  RETURN jsonb_build_object('ok', true, 'type', 'sponsored', 'ends_at', v_ends_at);
END;
$$;

GRANT EXECUTE ON FUNCTION public.admin_activate_sponsored(UUID, INT) TO authenticated;

-- ── 2. admin_activate_recommendation ─────────────────────────────────────────

CREATE OR REPLACE FUNCTION public.admin_activate_recommendation(
  p_group_id UUID,
  p_days     INT DEFAULT 7
)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_ends_at  TIMESTAMPTZ;
  v_city     TEXT;
  v_state    TEXT;
  v_order_id UUID;
BEGIN
  IF NOT (
    (auth.jwt()->>'role') = 'service_role'
    OR EXISTS (SELECT 1 FROM public.profiles WHERE id = auth.uid() AND role = 'admin')
  ) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_admin');
  END IF;

  SELECT normalize_state_name(state), city
  INTO   v_state, v_city
  FROM   public.groups
  WHERE  id = p_group_id;

  v_ends_at := CASE WHEN p_days > 0
                 THEN NOW() + (p_days || ' days')::INTERVAL
                 ELSE NULL
               END;

  INSERT INTO public.recommendation_orders
    (group_id, amount, duration_days, status, is_free, city, state, starts_at, ends_at)
  VALUES
    (p_group_id, 0, p_days, 'paid', TRUE, v_city, v_state, NOW(), v_ends_at)
  RETURNING id INTO v_order_id;

  RETURN jsonb_build_object('ok', true, 'type', 'recommendation', 'order_id', v_order_id, 'ends_at', v_ends_at);
END;
$$;

GRANT EXECUTE ON FUNCTION public.admin_activate_recommendation(UUID, INT) TO authenticated;

-- ── 3. admin_activate_bidding ─────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION public.admin_activate_bidding(
  p_group_id   UUID,
  p_bid_amount NUMERIC DEFAULT 100,
  p_days       INT     DEFAULT 7
)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_ends_at  TIMESTAMPTZ;
  v_state    TEXT;
  v_order_id UUID;
BEGIN
  IF NOT (
    (auth.jwt()->>'role') = 'service_role'
    OR EXISTS (SELECT 1 FROM public.profiles WHERE id = auth.uid() AND role = 'admin')
  ) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_admin');
  END IF;

  SELECT normalize_state_name(state) INTO v_state
  FROM   public.groups
  WHERE  id = p_group_id;

  v_ends_at := CASE WHEN p_days > 0
                 THEN NOW() + (p_days || ' days')::INTERVAL
                 ELSE NULL
               END;

  INSERT INTO public.bid_orders
    (group_id, amount, duration_days, status, is_free, state, starts_at, ends_at)
  VALUES
    (p_group_id, p_bid_amount, p_days, 'paid', TRUE, v_state, NOW(), v_ends_at)
  RETURNING id INTO v_order_id;

  RETURN jsonb_build_object('ok', true, 'type', 'bidding', 'order_id', v_order_id, 'ends_at', v_ends_at);
END;
$$;

GRANT EXECUTE ON FUNCTION public.admin_activate_bidding(UUID, NUMERIC, INT) TO authenticated;

-- ── 4. admin_deactivate_group ─────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION public.admin_deactivate_group(
  p_group_id UUID,
  p_type     TEXT   -- 'sponsored' | 'recommendation' | 'bidding'
)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NOT (
    (auth.jwt()->>'role') = 'service_role'
    OR EXISTS (SELECT 1 FROM public.profiles WHERE id = auth.uid() AND role = 'admin')
  ) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_admin');
  END IF;

  IF p_type = 'sponsored' THEN
    UPDATE public.sponsored_groups
    SET is_active = FALSE, ends_at = NOW()
    WHERE group_id = p_group_id AND is_active = TRUE;

  ELSIF p_type = 'recommendation' THEN
    UPDATE public.recommendation_orders
    SET status = 'expired', ends_at = NOW()
    WHERE group_id = p_group_id AND is_free = TRUE AND status = 'paid';

  ELSIF p_type = 'bidding' THEN
    UPDATE public.bid_orders
    SET status = 'expired', ends_at = NOW()
    WHERE group_id = p_group_id AND is_free = TRUE AND status = 'paid';

  ELSE
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_type');
  END IF;

  RETURN jsonb_build_object('ok', true, 'type', p_type, 'group_id', p_group_id);
END;
$$;

GRANT EXECUTE ON FUNCTION public.admin_deactivate_group(UUID, TEXT) TO authenticated;

-- ── Verificación ──────────────────────────────────────────────────────────────
DO $$
BEGIN
  RAISE NOTICE '[329] admin_activate_sponsored/recommendation/bidding: guard via profiles ✅';
  RAISE NOTICE '[329] admin_deactivate_group: guard via profiles ✅';
END;
$$;

SELECT '329_fix_admin_free_activations_guard.sql ejecutado ✅' AS status;
