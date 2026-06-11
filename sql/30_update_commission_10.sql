-- ============================================================
-- DARICEFY - 30_update_commission_10.sql
-- Cambiar comisión global a 10% (plataforma) / 90% (grupo)
-- Ejecutar en Supabase SQL Editor
-- ⚠️ No afecta reservas pasadas (solo nuevas reservas)
-- ============================================================

-- 1. Actualizar todos los países a 10%
UPDATE public.countries
SET
  commission_rate    = 10.0,
  default_commission = 10.0;

-- 2. Actualizar el trigger para usar 10% como fallback
CREATE OR REPLACE FUNCTION public.calculate_commission()
RETURNS TRIGGER AS $func$
DECLARE
  v_commission_rate DECIMAL;
BEGIN
  SELECT c.commission_rate INTO v_commission_rate
  FROM public.groups g
  JOIN public.countries c ON g.country_id = c.id
  WHERE g.id = NEW.group_id;

  -- Si no tiene país asignado, usar 10% por defecto
  IF v_commission_rate IS NULL THEN
    v_commission_rate := 10.0;
  END IF;

  NEW.platform_commission := ROUND((NEW.total_price * v_commission_rate) / 100.0, 2);
  NEW.group_earnings := NEW.total_price - NEW.platform_commission;

  RETURN NEW;
END;
$func$ LANGUAGE plpgsql SECURITY DEFINER;

SELECT 'Comisión actualizada a 10% correctamente ✅' AS status;
