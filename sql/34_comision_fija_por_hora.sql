-- ============================================================
-- DARICEFY - 34_comision_fija_por_hora.sql
-- Nuevo modelo de comisión: $200 MXN fijos por hora contratada
-- Aplica SOLO a nuevas reservas. No modifica reservas pasadas.
-- Ejecutar en Supabase SQL Editor
-- ============================================================

-- ─────────────────────────────────────────────────────────────
-- 1. Reemplazar el trigger de comisión (paquetes normales)
--    Antes: commission_rate % sobre el total
--    Ahora: $200 × duration_hours del paquete
-- ─────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.calculate_commission()
RETURNS TRIGGER AS $func$
DECLARE
  v_duration_hours NUMERIC;
  COMMISSION_PER_HOUR CONSTANT NUMERIC := 200;
BEGIN
  -- Solo aplica en INSERT (nuevas reservas)
  -- No modificar reservas pasadas

  -- Obtener duración del paquete
  SELECT duration_hours
    INTO v_duration_hours
    FROM public.packages
   WHERE id = NEW.package_id;

  -- Comisión = $200 × horas del paquete
  NEW.commission_amount := COALESCE(v_duration_hours, 0) * COMMISSION_PER_HOUR;

  -- Ganancia neta del grupo = total pagado − comisión
  NEW.group_earnings := NEW.total_price - NEW.commission_amount;

  RETURN NEW;
END;
$func$ LANGUAGE plpgsql SECURITY DEFINER;

-- El trigger ya existe (fue creado en scripts anteriores), solo reemplazamos la función.
-- Si no existe, lo creamos:
DROP TRIGGER IF EXISTS calculate_commission_on_reservation ON public.reservations;
CREATE TRIGGER calculate_commission_on_reservation
  BEFORE INSERT ON public.reservations
  FOR EACH ROW
  EXECUTE FUNCTION public.calculate_commission();

-- ─────────────────────────────────────────────────────────────
-- 2. Actualizar el trigger de extra_hours para usar $200/h
--    (si la tabla extra_hours ya existe)
-- ─────────────────────────────────────────────────────────────
-- Los campos platform_commission y group_extra_earnings
-- se calculan desde la app con la nueva lógica. No se necesita
-- trigger en DB para esto.

-- ─────────────────────────────────────────────────────────────
-- 3. Verificación: mostrar la tasa de comisión actual
-- ─────────────────────────────────────────────────────────────
SELECT
  'Comisión fija: $200 MXN por hora de servicio' AS modelo,
  'Las reservas existentes NO se modifican'        AS aviso,
  'Solo afecta nuevas reservas'                    AS alcance;

SELECT 'Modelo de comisión $200/hora configurado correctamente ✅' AS status;
