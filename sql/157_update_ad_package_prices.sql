-- ════════════════════════════════════════════════════════════════════════════
-- 157_update_ad_package_prices.sql
-- Ajuste de precios escalados para banner_home y profile_ad.
--
-- Banner Home (premium, mayor visibilidad):
--   7 días  → $499
--   14 días → $899
--   30 días → $1,499
--
-- Profile Ad (volumen, nivel medio):
--   7 días  → $349
--   30 días → $899
-- ════════════════════════════════════════════════════════════════════════════

-- ── Banner Home ──────────────────────────────────────────────────────────────

UPDATE public.ad_packages
SET    price = 499
WHERE  type         = 'banner_home'
  AND  duration_days = 7
  AND  is_active     = true;

UPDATE public.ad_packages
SET    price = 899
WHERE  type         = 'banner_home'
  AND  duration_days = 14
  AND  is_active     = true;

UPDATE public.ad_packages
SET    price = 1499
WHERE  type         = 'banner_home'
  AND  duration_days = 30
  AND  is_active     = true;

-- ── Profile Ad ───────────────────────────────────────────────────────────────

UPDATE public.ad_packages
SET    price = 349
WHERE  type         = 'profile_ad'
  AND  duration_days = 7
  AND  is_active     = true;

UPDATE public.ad_packages
SET    price = 899
WHERE  type         = 'profile_ad'
  AND  duration_days = 30
  AND  is_active     = true;

-- ── Verificación ─────────────────────────────────────────────────────────────

SELECT id, name, type, duration_days, price
FROM   public.ad_packages
WHERE  type     IN ('banner_home', 'profile_ad')
  AND  is_active = true
ORDER  BY type, duration_days;

SELECT '157_update_ad_package_prices.sql ejecutado ✅' AS status;
