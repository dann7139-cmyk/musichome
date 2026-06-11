-- ════════════════════════════════════════════════════════════════════
-- 185_express_fee_separation.sql
--
-- OBJETIVO: Separar express_fee de la comisión base.
--
-- Antes:
--   commission = adjustedPrice(incluye express) × rate
--   → la app cobraba comisión SOBRE el recargo express (incorrecto)
--
-- Ahora:
--   base_price = precio del grupo (sin express)
--   commission = base_price × rate          (7–10% según tier)
--   express_fee = base_price × 0.15         (si aplica, va a plataforma)
--   final_price = base_price + commission + express_fee
--   group_earnings = base_price             (grupo recibe solo su precio)
--
-- Ejemplo ($3,500 base, express):
--   commission  = $3,500 × 7%  = $245
--   express_fee = $3,500 × 15% = $525
--   final_price = $3,500 + $245 + $525 = $4,270
--   grupo recibe: $3,500  |  plataforma gana: $770
--
-- Cambios:
--   1. calculate_final_price — acepta p_is_express, retorna express_fee
--   2. calculate_commission trigger — usa total_price - base_price (universal)
--
-- Requiere: 184_calculate_final_price_rpc.sql
-- ════════════════════════════════════════════════════════════════════


-- ── 1. calculate_final_price — con express_fee separado ──────────────────────

DROP FUNCTION IF EXISTS public.calculate_final_price(NUMERIC, TEXT);
CREATE OR REPLACE FUNCTION public.calculate_final_price(
  p_base_price NUMERIC,
  p_city       TEXT    DEFAULT NULL,
  p_is_express BOOLEAN DEFAULT FALSE
)
RETURNS JSONB
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_rate        NUMERIC;
  v_commission  NUMERIC(12,2);
  v_express_fee NUMERIC(12,2);
  v_final       NUMERIC(12,2);
BEGIN
  IF p_base_price IS NULL OR p_base_price < 0 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_base_price');
  END IF;

  v_rate        := public.get_commission_rate(p_base_price);         -- 7, 8, 9 o 10
  v_commission  := ROUND(p_base_price * v_rate / 100.0, 2);
  v_express_fee := CASE WHEN p_is_express
                     THEN ROUND(p_base_price * 0.15, 2)
                     ELSE 0
                   END;
  v_final       := p_base_price + v_commission + v_express_fee;

  RAISE NOTICE '[CALCULATE_FINAL_PRICE] base=% rate=% commission=% express=% final=%',
    p_base_price, v_rate, v_commission, v_express_fee, v_final;

  RETURN jsonb_build_object(
    'ok',                true,
    'base_price',        p_base_price,
    'commission_rate',   v_rate,
    'commission_amount', v_commission,
    'express_fee',       v_express_fee,
    'final_price',       v_final,
    'group_earnings',    p_base_price   -- grupo SIEMPRE recibe su precio base exacto
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.calculate_final_price(NUMERIC, TEXT, BOOLEAN) TO authenticated, anon;


-- ── 2. calculate_commission trigger — fórmula universal ─────────────────────
--
-- Antes: recalculaba tiers desde base_price.
-- Ahora: platform_commission = total_price - base_price
--        Cubre automáticamente commission + express_fee + cualquier cargo futuro.
--        group_earnings = base_price (lo que el grupo cotizó, siempre exacto).

CREATE OR REPLACE FUNCTION public.calculate_commission()
RETURNS TRIGGER AS $func$
DECLARE
  v_base NUMERIC;
BEGIN
  -- base_price = lo que el grupo recibe
  -- Fallback para reservas antiguas sin base_price: estimar con tier 7%
  v_base := COALESCE(NEW.base_price, ROUND(NEW.total_price * 100.0 / 107.0, 2));

  -- platform_commission = todo lo que cobra la plataforma (commission + express + lo que sea)
  NEW.platform_commission := ROUND(NEW.total_price - v_base, 2);
  NEW.group_earnings       := v_base;

  RAISE NOTICE '[COMMISSION_TRIGGER] group=% base=% total=% platform_commission=% group_earnings=%',
    NEW.group_id, v_base, NEW.total_price, NEW.platform_commission, NEW.group_earnings;

  RETURN NEW;
END;
$func$ LANGUAGE plpgsql SECURITY DEFINER;


-- ── Verificación ──────────────────────────────────────────────────────────────

-- Sin express
SELECT public.calculate_final_price(3500, NULL, FALSE) AS normal;

-- Con express
SELECT public.calculate_final_price(3500, NULL, TRUE) AS express;

-- Tabla completa de tiers con y sin express
SELECT
  base,
  (public.calculate_final_price(base::NUMERIC, NULL, FALSE))->>'commission_rate'    AS rate,
  (public.calculate_final_price(base::NUMERIC, NULL, FALSE))->>'commission_amount'  AS commission,
  (public.calculate_final_price(base::NUMERIC, NULL, FALSE))->>'final_price'        AS final_normal,
  (public.calculate_final_price(base::NUMERIC, NULL, TRUE))->>'express_fee'         AS express_fee,
  (public.calculate_final_price(base::NUMERIC, NULL, TRUE))->>'final_price'         AS final_express
FROM (VALUES (2500), (5000), (8000), (12000)) AS t(base);

SELECT '185_express_fee_separation.sql ejecutado ✅' AS status;
