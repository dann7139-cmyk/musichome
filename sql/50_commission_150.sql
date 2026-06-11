-- ════════════════════════════════════════════════════════════════════
-- 50_commission_150.sql
-- Cambia la comisión de $200/hora → $150/hora.
-- Actualiza trigger DB + regla en platform_fee_rules.
-- Ejecutar en Supabase SQL Editor.
-- ════════════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION public.calculate_commission()
RETURNS TRIGGER AS $func$
DECLARE
  v_duration_hours NUMERIC;
  COMMISSION_PER_HOUR CONSTANT NUMERIC := 150;
BEGIN
  -- Intentar obtener horas del paquete
  SELECT duration_hours INTO v_duration_hours
    FROM public.packages WHERE id = NEW.package_id;

  -- Si no hay paquete, buscar en cotización
  IF v_duration_hours IS NULL AND NEW.quote_id IS NOT NULL THEN
    SELECT duration_hours INTO v_duration_hours
      FROM public.quotes WHERE id = NEW.quote_id;
  END IF;

  NEW.commission_amount := COALESCE(v_duration_hours, 3) * COMMISSION_PER_HOUR;
  NEW.group_earnings    := NEW.total_price - NEW.commission_amount;

  RETURN NEW;
END;
$func$ LANGUAGE plpgsql SECURITY DEFINER;

-- Actualizar regla en la tabla configurable
UPDATE public.platform_fee_rules
SET amount = 150,
    name   = 'Comisión estándar $150/hora',
    updated_at = NOW()
WHERE fee_type = 'per_hour' AND is_active = TRUE;

SELECT '50_commission_150: OK ✅  (comisión ahora $150/hora)' AS status;
