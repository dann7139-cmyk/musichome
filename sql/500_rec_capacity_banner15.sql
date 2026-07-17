-- ============================================================
-- sql/500_rec_capacity_banner15.sql
-- 📣 Ajustes de cupos (pedido 2026-07-17):
--
--  1. Banners: 10 → 15 por estado.
--  2. RECOMENDADOS ahora también tienen cupo, igual que Destacados:
--     máximo 10 GRUPOS distintos recomendados a la vez por estado.
--     (En el explorador pesan igual que los Destacados — deben jugar
--     con las mismas reglas.)
--     · check_recommendation_availability: la app/EF pregunta antes.
--     · place_recommendation_order: candado server-side.
--     · Las RENOVACIONES de un grupo que ya tiene su lugar NUNCA se
--       bloquean (su lugar ya es suyo) — por eso se cuentan GRUPOS
--       distintos, no órdenes.
-- ============================================================

BEGIN;

-- ── 1. Banners: 15 por estado ────────────────────────────────
CREATE OR REPLACE FUNCTION public.ad_state_limit(p_type TEXT)
RETURNS INT LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE p_type
    WHEN 'banner_home'     THEN 15
    WHEN 'sponsored_group' THEN 10
    WHEN 'profile_ad'      THEN 20
    ELSE 10
  END;
$$;

-- ── 2. Cupo de Recomendados: 10 grupos por estado ────────────
CREATE OR REPLACE FUNCTION public.check_recommendation_availability(
  p_group_id UUID
)
RETURNS JSONB
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_state TEXT;
  v_used  INT;
  v_limit INT := 10;
BEGIN
  SELECT normalize_state_name(state) INTO v_state
  FROM groups WHERE id = p_group_id;

  -- Grupos DISTINTOS con recomendación vigente en el mismo estado
  -- (excluyendo al propio grupo: renovar su lugar siempre se puede)
  SELECT COUNT(DISTINCT ro.group_id) INTO v_used
  FROM recommendation_orders ro
  WHERE ro.status = 'paid'
    AND ro.ends_at IS NOT NULL AND ro.ends_at > NOW()
    AND ro.group_id <> p_group_id
    AND (
      v_state IS NULL
      OR ro.state IS NULL              -- legacy sin estado = visible en todos
      OR ro.state = v_state
    );

  IF v_used >= v_limit THEN
    RETURN jsonb_build_object('ok', false, 'error', 'no_capacity',
      'scope', 'recommendation', 'state', v_state,
      'used', v_used, 'limit', v_limit);
  END IF;

  RETURN jsonb_build_object('ok', true, 'used', v_used, 'limit', v_limit, 'state', v_state);
END;
$$;

GRANT EXECUTE ON FUNCTION public.check_recommendation_availability(UUID) TO authenticated, service_role;

-- ── 3. place_recommendation_order v4 — candado de cupo ───────
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
  v_country  TEXT;
  v_order_id UUID;
  v_avail    JSONB;
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM public.groups WHERE id = p_group_id AND owner_id = auth.uid()
  ) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'unauthorized');
  END IF;

  -- 🚦 Cupo: máx. 10 grupos recomendados a la vez por estado
  v_avail := check_recommendation_availability(p_group_id);
  IF NOT COALESCE((v_avail->>'ok')::BOOLEAN, false) THEN
    RETURN v_avail;
  END IF;

  -- Pricing escalonado fijo (sin cambios respecto a sql/177)
  v_amount := CASE p_duration
    WHEN 1 THEN   79.00
    WHEN 3 THEN  199.00
    WHEN 7 THEN  399.00
    ELSE ROUND((79.00 * p_duration * 0.85)::NUMERIC, 2)
  END;

  v_per_day := ROUND((v_amount / p_duration)::NUMERIC, 2);

  SELECT city, normalize_state_name(state), country
  INTO   v_city, v_state, v_country
  FROM   public.groups
  WHERE  id = p_group_id;

  INSERT INTO public.recommendation_orders
    (group_id, duration_days, amount, price_per_day, status, city, state, country)
  VALUES
    (p_group_id, p_duration, v_amount, v_per_day, 'pending_payment',
     v_city, v_state, v_country)
  RETURNING id INTO v_order_id;

  RETURN jsonb_build_object(
    'ok',       true,
    'order_id', v_order_id,
    'amount',   v_amount,
    'per_day',  v_per_day,
    'duration', p_duration,
    'city',     v_city,
    'state',    v_state,
    'country',  v_country
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.place_recommendation_order(UUID, INT)
  TO authenticated;

COMMIT;

-- ── VERIFICACIÓN ──────────────────────────────────────────────────────────────
SELECT ad_state_limit('banner_home') AS banners_por_estado;
-- Esperado: 15

SELECT proname FROM pg_proc WHERE proname = 'check_recommendation_availability';
-- Esperado: 1 fila

SELECT prosrc LIKE '%check_recommendation_availability%' AS candado_recomendados
FROM pg_proc WHERE proname = 'place_recommendation_order';
-- Esperado: true

SELECT '500_rec_capacity_banner15.sql ejecutado ✅' AS status;
