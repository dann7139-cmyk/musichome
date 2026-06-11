-- ════════════════════════════════════════════════════════════════════════════
-- 155_update_profile_ad_prices.sql
-- Actualización de precios de paquetes profile_ad.
--
-- BASE_PER_DAY sube de $28 a $55 MXN/día.
-- Se actualizan los paquetes activos de la tabla ad_packages.
-- ════════════════════════════════════════════════════════════════════════════

UPDATE public.ad_packages
SET    price = 385
WHERE  type         = 'profile_ad'
  AND  duration_days = 7
  AND  is_active     = true;

UPDATE public.ad_packages
SET    price = 825
WHERE  type         = 'profile_ad'
  AND  duration_days = 15
  AND  is_active     = true;

UPDATE public.ad_packages
SET    price = 1650
WHERE  type         = 'profile_ad'
  AND  duration_days = 30
  AND  is_active     = true;


-- ── Verificación ─────────────────────────────────────────────────────────────
SELECT id, name, type, duration_days, price
FROM   public.ad_packages
WHERE  type     = 'profile_ad'
  AND  is_active = true
ORDER  BY duration_days;

SELECT '155_update_profile_ad_prices.sql ejecutado ✅' AS status;
