-- ════════════════════════════════════════════════════════════════════
-- 54_packages_extra_hour_price.sql
-- Agrega precio de hora extra fija a los paquetes.
-- El grupo define cuánto cobra por cada hora adicional al crear el paquete.
-- ════════════════════════════════════════════════════════════════════

ALTER TABLE public.packages
  ADD COLUMN IF NOT EXISTS extra_hour_price NUMERIC(10,2) DEFAULT NULL;

SELECT '54_packages_extra_hour_price: OK ✅' AS status;
