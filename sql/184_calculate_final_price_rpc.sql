-- ════════════════════════════════════════════════════════════════════
-- 184_calculate_final_price_rpc.sql
--
-- OBJETIVO: RPC central que el frontend llama para obtener el precio
-- final AUTORIZADO por backend antes de confirmar cualquier reserva.
--
-- Función: calculate_final_price(base_price, city?)
--
-- Retorna:
--   base_price        — precio del grupo (lo que recibe)
--   commission_rate   — porcentaje aplicado (7, 8, 9, 10)
--   commission_amount — comisión exacta en $
--   final_price       — lo que paga el cliente (base + commission)
--   group_earnings    — igual a base_price (garantía explícita)
--
-- Uso:
--   Llamar ANTES de mostrar la confirmación de reserva.
--   El frontend usa final_price como p_total_price en create_booking_with_event.
--   El trigger recalcula por separado — doble verificación automática.
--
-- Requiere: 183_dynamic_commission.sql
-- ════════════════════════════════════════════════════════════════════


-- ── calculate_final_price ────────────────────────────────────────────────────

DROP FUNCTION IF EXISTS public.calculate_final_price(NUMERIC, TEXT);
CREATE OR REPLACE FUNCTION public.calculate_final_price(
  p_base_price NUMERIC,
  p_city       TEXT DEFAULT NULL   -- reservado para ajuste por demanda futuro
)
RETURNS JSONB
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_rate       NUMERIC;
  v_commission NUMERIC(12,2);
  v_final      NUMERIC(12,2);
BEGIN
  -- Validación básica
  IF p_base_price IS NULL OR p_base_price < 0 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_base_price');
  END IF;

  v_rate       := public.get_commission_rate(p_base_price);          -- 7, 8, 9 o 10
  v_commission := ROUND(p_base_price * v_rate / 100.0, 2);
  v_final      := p_base_price + v_commission;

  RAISE NOTICE '[CALCULATE_FINAL_PRICE] base=% rate=% commission=% final=%',
    p_base_price, v_rate, v_commission, v_final;

  RETURN jsonb_build_object(
    'ok',               true,
    'base_price',       p_base_price,
    'commission_rate',  v_rate,
    'commission_amount', v_commission,
    'final_price',      v_final,
    'group_earnings',   p_base_price   -- el grupo SIEMPRE recibe su precio base
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.calculate_final_price(NUMERIC, TEXT) TO authenticated, anon;


-- ── Verificación ──────────────────────────────────────────────────────────────

SELECT
  (public.calculate_final_price(base::NUMERIC))->>'commission_rate'   AS rate,
  (public.calculate_final_price(base::NUMERIC))->>'commission_amount' AS commission,
  (public.calculate_final_price(base::NUMERIC))->>'final_price'       AS client_pays,
  (public.calculate_final_price(base::NUMERIC))->>'group_earnings'    AS group_gets
FROM (VALUES
  (2500),    -- tier 7%  → $175 comisión
  (5000),    -- tier 8%  → $400 comisión
  (8000),    -- tier 9%  → $720 comisión
  (12000)    -- tier 10% → $1,200 comisión
) AS t(base);

SELECT '184_calculate_final_price_rpc.sql ejecutado ✅' AS status;
