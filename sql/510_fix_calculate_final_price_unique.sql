-- ============================================================
-- sql/510_fix_calculate_final_price_unique.sql
-- 🐞 FIX 42725 "calculate_final_price is not unique" (2026-07-18)
--
--  Causa: sql/189 creó la firma (NUMERIC, TEXT, BOOLEAN, TEXT) y
--  sql/203 creó (NUMERIC, BOOLEAN, TEXT, TEXT) sin tirar la anterior.
--  Ambas aceptan los MISMOS nombres de parámetros → cualquier llamada
--  (posicional o por nombre, incluida la de la app) era ambigua y
--  fallaba en silencio (la app caía a su precio local).
--
--  Fix: se eliminan TODAS las versiones existentes (cualquier firma)
--  y se recrea UNA sola — la canónica del modelo 20% (sql/509).
-- ============================================================

BEGIN;

-- Tirar TODAS las sobrecargas, tengan la firma que tengan
DO $$
DECLARE r RECORD;
BEGIN
  FOR r IN
    SELECT oid::regprocedure AS sig
    FROM pg_proc
    WHERE proname = 'calculate_final_price'
      AND pronamespace = 'public'::regnamespace
  LOOP
    EXECUTE format('DROP FUNCTION %s', r.sig);
    RAISE NOTICE '[510] Eliminada: %', r.sig;
  END LOOP;
END $$;

-- Única versión canónica: markup 20% (idéntica a sql/509)
CREATE FUNCTION public.calculate_final_price(
  p_base_price NUMERIC,
  p_is_express BOOLEAN DEFAULT FALSE,
  p_state      TEXT    DEFAULT NULL,
  p_city       TEXT    DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_commission  NUMERIC(12,2);
  v_final       NUMERIC(12,2);
BEGIN
  IF p_base_price IS NULL OR p_base_price < 0 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_base_price');
  END IF;

  -- 🎯 MODELO ÚNICO: markup 20% en TODA la app
  v_commission := ROUND(p_base_price * 0.20, 2);
  v_final      := p_base_price + v_commission;

  RETURN jsonb_build_object(
    'ok',                true,
    'base_price',        p_base_price,
    'commission_rate',   20,
    'commission_amount', v_commission,
    'final_price',       v_final,
    'group_earnings',    p_base_price,
    'multiplier',        1.0,
    'is_express',        COALESCE(p_is_express, false)
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.calculate_final_price(NUMERIC, BOOLEAN, TEXT, TEXT)
  TO authenticated, anon;

COMMIT;

-- ── VERIFICACIÓN ──────────────────────────────────────────────────────────────
SELECT COUNT(*) AS versiones  -- Esperado: 1
FROM pg_proc WHERE proname = 'calculate_final_price';

SELECT (calculate_final_price(1000)->>'final_price')::NUMERIC AS precio_1000;
-- Esperado: 1200 (ya sin ambigüedad)

SELECT '510_fix_calculate_final_price_unique.sql ejecutado ✅' AS status;
