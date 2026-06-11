-- ════════════════════════════════════════════════════════════════════════════
-- 154_update_banner_prices.sql
-- Actualización de precios de paquetes banner_home.
--
-- CAMBIOS:
--   · 7  días  : $499 MXN
--   · 15 días  : $799 MXN  (era $199)
--   · 30 días  : $1,399 MXN
--
-- Los precios son BASE. El sistema de precio dinámico (multiplier) los
-- ajusta automáticamente según demanda de la ciudad.
-- ════════════════════════════════════════════════════════════════════════════

UPDATE public.ad_packages
SET    price = 499
WHERE  type         = 'banner_home'
  AND  duration_days = 7
  AND  is_active     = true;

UPDATE public.ad_packages
SET    price = 799
WHERE  type         = 'banner_home'
  AND  duration_days = 15
  AND  is_active     = true;

UPDATE public.ad_packages
SET    price = 1399
WHERE  type         = 'banner_home'
  AND  duration_days = 30
  AND  is_active     = true;


-- ── Verificación ─────────────────────────────────────────────────────────────
SELECT id, name, type, duration_days, price
FROM   public.ad_packages
WHERE  type     = 'banner_home'
  AND  is_active = true
ORDER  BY duration_days;

SELECT '154_update_banner_prices.sql ejecutado ✅' AS status;
