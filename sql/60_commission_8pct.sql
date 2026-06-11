-- ════════════════════════════════════════════════════════════════════
-- 60_commission_8pct.sql
-- Cambia el modelo de comisión de $150/hora fija → 8% del total del evento.
-- Reemplaza el trigger de 53_commission_model_a.sql.
-- Ejecutar DESPUÉS de 59_wallet_system.sql.
-- ════════════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION public.calculate_commission()
RETURNS TRIGGER AS $func$
DECLARE
  COMMISSION_RATE CONSTANT NUMERIC := 0.08;   -- 8% de la plataforma
BEGIN
  -- Calcular comisión como porcentaje del precio total
  NEW.commission_amount := ROUND(NEW.total_price * COMMISSION_RATE, 2);
  NEW.platform_fee      := NEW.commission_amount;
  NEW.group_earnings    := NEW.total_price - NEW.commission_amount;
  NEW.commission_rate   := COMMISSION_RATE;

  RETURN NEW;
END;
$func$ LANGUAGE plpgsql SECURITY DEFINER;

-- El trigger ya existe desde 34_comision_fija_por_hora.sql (BEFORE INSERT OR UPDATE)
-- Solo reemplazamos la función — no es necesario recrear el trigger.
-- Si por alguna razón no existe, lo creamos aquí:
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_trigger
    WHERE tgname = 'trg_calculate_commission'
      AND tgrelid = 'public.reservations'::regclass
  ) THEN
    EXECUTE $t$
      CREATE TRIGGER trg_calculate_commission
        BEFORE INSERT OR UPDATE OF total_price ON public.reservations
        FOR EACH ROW EXECUTE FUNCTION public.calculate_commission();
    $t$;
  END IF;
END;
$$;

-- Actualizar la regla en platform_fee_rules para reflejar el nuevo modelo
UPDATE public.platform_fee_rules
   SET fee_type   = 'percentage',
       amount     = 8,
       name       = 'Comisión estándar 8% – MercadoPago',
       updated_at = NOW()
 WHERE is_active = TRUE;

-- Recalcular reservas existentes que aún no tienen payment_status = 'fully_paid'
-- (solo actualiza commission_amount y group_earnings; no toca montos ya pagados)
UPDATE public.reservations
   SET commission_amount = ROUND(total_price * 0.08, 2),
       platform_fee      = ROUND(total_price * 0.08, 2),
       group_earnings    = total_price - ROUND(total_price * 0.08, 2),
       commission_rate   = 0.08
 WHERE payment_status NOT IN ('fully_paid')
   AND total_price IS NOT NULL
   AND total_price > 0;

SELECT '60_commission_8pct: comisión actualizada a 8% ✅' AS status;
