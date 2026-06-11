-- ════════════════════════════════════════════════════════════════════
-- 168_commission_and_multipliers.sql
-- 1. Agrega commission_percentage a grupos (default 10%).
-- 2. Valida que el sistema de comisiones coincide con calculations.ts.
-- 3. Prepara multiplicadores de pricing para recomendaciones (futuro).
--
-- PRINCIPIO CLAVE (igual que en calculations.ts):
--   El grupo siempre recibe su precio completo.
--   La plataforma cobra commission_percentage AL CLIENTE (on top).
--
--   client_pays   = group_price × (1 + commission_pct)   → lo que paga el cliente
--   platform_fee  = group_price × commission_pct          → ingreso de plataforma
--   group_earns   = group_price                           → lo que recibe el grupo
--
-- EJEMPLO (commission_pct = 0.10):
--   Grupo define: $3,500
--   Cliente paga: $3,850  (+$350 plataforma)
--   Grupo recibe: $3,500  (íntegro)
--
-- EJECUTAR DESPUÉS DE: 166_recommendation_system.sql
-- ════════════════════════════════════════════════════════════════════


-- ── 1. Comisión configurable por grupo ───────────────────────────────────────────
-- Permite que en el futuro algunos grupos tengan comisión diferente.
-- Por defecto 0.10 (10%), que ya usa calculations.ts (PLATFORM_FEE_RATE).

ALTER TABLE public.groups
  ADD COLUMN IF NOT EXISTS commission_percentage NUMERIC(4,2) DEFAULT 0.10;

-- Actualizar grupos existentes que tengan NULL
UPDATE public.groups
SET commission_percentage = 0.10
WHERE commission_percentage IS NULL;

-- Agregar constraint: entre 0% y 50%
ALTER TABLE public.groups
  DROP CONSTRAINT IF EXISTS groups_commission_pct_check;
ALTER TABLE public.groups
  ADD CONSTRAINT groups_commission_pct_check
  CHECK (commission_percentage >= 0 AND commission_percentage <= 0.50);

COMMENT ON COLUMN public.groups.commission_percentage IS
  'Tasa de comisión que la plataforma agrega SOBRE el precio del grupo para cobrar al cliente. '
  'Default 0.10 (10%). El grupo siempre recibe su precio íntegro. '
  'client_pays = group_price × (1 + commission_pct)';


-- ── 2. Función RPC: get_package_client_price ─────────────────────────────────────
-- Dado un package_id, devuelve el precio del grupo y el precio total que paga el cliente.
-- Útil para mostrar en BookingScreen / QuoteForm sin recalcular en frontend.

DROP FUNCTION IF EXISTS public.get_package_client_price(UUID);
CREATE OR REPLACE FUNCTION public.get_package_client_price(p_package_id UUID)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_pkg RECORD;
  v_commission NUMERIC(4,2);
BEGIN
  SELECT p.price, p.duration_hours, p.name,
         COALESCE(g.commission_percentage, 0.10) AS commission_pct,
         g.name AS group_name
  INTO   v_pkg
  FROM   public.packages p
  JOIN   public.groups g ON g.id = p.group_id
  WHERE  p.id = p_package_id;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'package_not_found');
  END IF;

  v_commission := v_pkg.commission_pct;

  RETURN jsonb_build_object(
    'ok',             true,
    'group_price',    v_pkg.price,
    'commission_pct', v_commission,
    'platform_fee',   ROUND((v_pkg.price * v_commission)::NUMERIC, 2),
    'client_pays',    ROUND((v_pkg.price * (1 + v_commission))::NUMERIC, 2),
    'group_earns',    v_pkg.price,    -- siempre el precio íntegro
    'package_name',   v_pkg.name,
    'group_name',     v_pkg.group_name
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.get_package_client_price(UUID) TO authenticated, anon;


-- ── 3. Multiplicadores de recomendación — preparados, inactivos ──────────────────
-- Las columnas ya existen en recommendation_orders (SQL 166).
-- Esta sección documenta la lógica futura y crea una función helper.

-- Función futura: calcular precio ajustado de recomendación con multiplicadores.
-- Por ahora retorna el precio base sin multiplicar.
-- Cuando esté listo, se actualiza con la lógica real.

DROP FUNCTION IF EXISTS public.calc_recommendation_price(TEXT, TEXT, INT);
CREATE OR REPLACE FUNCTION public.calc_recommendation_price(
  p_city     TEXT    DEFAULT NULL,
  p_genre    TEXT    DEFAULT NULL,
  p_duration INT     DEFAULT 1
)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  -- Precios base (mismos que en RecommendationScreen.tsx)
  v_base NUMERIC(10,2) := CASE p_duration
    WHEN 1 THEN   79.00
    WHEN 3 THEN  199.00
    WHEN 7 THEN  399.00
    ELSE ROUND((79.00 * p_duration * 0.85)::NUMERIC, 2)
  END;

  -- Multiplicadores (valor = 1.0 mientras pricing dinámico no esté activo)
  v_city_mult        NUMERIC(4,2) := 1.00;
  v_demand_mult      NUMERIC(4,2) := 1.00;
  v_competition_mult NUMERIC(4,2) := 1.00;

  -- TODO (futuro): calcular multiplicadores según:
  --   v_city_mult        ← ciudades premium cobran hasta 1.5×
  --   v_demand_mult      ← alta demanda = precios dinámicos
  --   v_competition_mult ← poca competencia = precio más alto

  v_final NUMERIC(10,2);
BEGIN
  v_final := ROUND((v_base * v_city_mult * v_demand_mult * v_competition_mult)::NUMERIC, 2);

  RETURN jsonb_build_object(
    'base_price',          v_base,
    'city_multiplier',     v_city_mult,
    'demand_multiplier',   v_demand_mult,
    'competition_mult',    v_competition_mult,
    'final_price',         v_final,
    'dynamic_pricing',     false,   -- ← cambiar a true cuando se active
    'duration_days',       p_duration
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.calc_recommendation_price(TEXT, TEXT, INT) TO authenticated, anon;


-- ── 4. Vista de auditoría: ingresos confirmados vs órdenes ───────────────────────
-- Detecta órdenes pagadas sin wallet_transaction correspondiente.

CREATE OR REPLACE VIEW public.v_recommendation_audit AS
SELECT
  ro.id             AS order_id,
  ro.group_id,
  g.name            AS group_name,
  g.city,
  ro.amount,
  ro.status,
  ro.stripe_payment_id,
  ro.ends_at,
  EXISTS (
    SELECT 1 FROM public.wallet_transactions wt
    WHERE wt.type = 'recommendation_income'
      AND (wt.reference_id = ro.stripe_payment_id
        OR wt.reference_id = 'rec_' || ro.id::TEXT)
  ) AS has_wallet_entry
FROM public.recommendation_orders ro
LEFT JOIN public.groups g ON g.id = ro.group_id
WHERE ro.status = 'paid';

COMMENT ON VIEW public.v_recommendation_audit IS
  'Órdenes pagadas. has_wallet_entry = false indica ingreso no registrado (pérdida de dinero).';


SELECT '168_commission_and_multipliers.sql ejecutado ✅' AS status;
SELECT 'commission_percentage en grupos (default 0.10 = 10%)' AS comision;
SELECT 'client_pays = group_price × 1.10 | group_earns = group_price' AS formula;
SELECT 'calc_recommendation_price preparado (multiplicadores inactivos)' AS futuro;
SELECT 'v_recommendation_audit: detecta órdenes pagadas sin wallet entry' AS auditoria;
