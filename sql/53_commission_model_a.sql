-- ════════════════════════════════════════════════════════════════════
-- 53_commission_model_a.sql
-- Modelo A: comisión $150/hora calculada desde la cotización.
-- • Prioridad: quote_id → quotes.duration_hours
-- • Fallback:  package_id → packages.duration_hours  (compatibilidad)
-- • Sin datos: mínimo 3 horas
-- release-deposit-payout queda DEPRECADO; no se invoca desde la app.
-- ════════════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION public.calculate_commission()
RETURNS TRIGGER AS $func$
DECLARE
  v_duration_hours     NUMERIC;
  COMMISSION_PER_HOUR  CONSTANT NUMERIC := 150;
BEGIN
  -- 1. Intentar obtener horas desde la cotización (Modelo A)
  IF NEW.quote_id IS NOT NULL THEN
    SELECT duration_hours INTO v_duration_hours
      FROM public.quotes
     WHERE id = NEW.quote_id;
  END IF;

  -- 2. Fallback: paquete (compatibilidad hacia atrás)
  IF v_duration_hours IS NULL AND NEW.package_id IS NOT NULL THEN
    SELECT duration_hours INTO v_duration_hours
      FROM public.packages
     WHERE id = NEW.package_id;
  END IF;

  -- 3. Calcular comisión y ganancias del grupo
  NEW.commission_amount := COALESCE(v_duration_hours, 3) * COMMISSION_PER_HOUR;
  NEW.group_earnings    := NEW.total_price - NEW.commission_amount;

  RETURN NEW;
END;
$func$ LANGUAGE plpgsql SECURITY DEFINER;

-- Asegurar que la regla configurable también refleja $150/hora
UPDATE public.platform_fee_rules
   SET amount     = 150,
       name       = 'Comisión estándar $150/hora – Modelo A',
       updated_at = NOW()
 WHERE fee_type = 'per_hour' AND is_active = TRUE;

SELECT '53_commission_model_a: OK ✅  (prioridad quote_id, $150/hora)' AS status;
