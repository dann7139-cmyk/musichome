-- ════════════════════════════════════════════════════════════════════════════
-- 160_tier_pricing.sql
-- Escalera de precios por tier para banner_home.
--
-- top_4_10 (accesible):  7d=$499  14d=$899  30d=$1,499
-- top_1_3  (premium):    7d=$699  14d=$1,199 30d=$1,999
--
-- El precio base se almacena en DB y la UI lo multiplica por
-- demandInfo.multiplier × cityStatus.price_multiplier.
-- ════════════════════════════════════════════════════════════════════════════

-- ── 1. Columna tier en ad_packages ───────────────────────────────────────────

ALTER TABLE public.ad_packages
  ADD COLUMN IF NOT EXISTS tier TEXT
    CHECK (tier IN ('top_1_3', 'top_4_10'));

CREATE INDEX IF NOT EXISTS idx_ad_packages_type_tier
  ON public.ad_packages (type, tier, duration_days);

-- ── 2. Marcar paquetes banner_home existentes como top_4_10 ──────────────────

UPDATE public.ad_packages
SET    tier = 'top_4_10'
WHERE  type = 'banner_home'
  AND  tier IS NULL;

-- ── 3. Ajustar precios de top_4_10 según especificación ──────────────────────

UPDATE public.ad_packages
SET price = 499
WHERE type = 'banner_home' AND tier = 'top_4_10' AND duration_days = 7  AND is_active = true;

UPDATE public.ad_packages
SET price = 899
WHERE type = 'banner_home' AND tier = 'top_4_10' AND duration_days = 14 AND is_active = true;

UPDATE public.ad_packages
SET price = 1499
WHERE type = 'banner_home' AND tier = 'top_4_10' AND duration_days = 30 AND is_active = true;

-- ── 4. Insertar paquetes top_1_3 (solo si no existen ya) ─────────────────────

INSERT INTO public.ad_packages (name, type, tier, duration_days, price, description, is_active)
SELECT 'Banner Inicio Premium 7 días', 'banner_home', 'top_1_3', 7, 699,
       'Posición Top 1–3 en el carousel del inicio. Máxima visibilidad para tu grupo.', true
WHERE NOT EXISTS (
  SELECT 1 FROM public.ad_packages
  WHERE type = 'banner_home' AND tier = 'top_1_3' AND duration_days = 7
);

INSERT INTO public.ad_packages (name, type, tier, duration_days, price, description, is_active)
SELECT 'Banner Inicio Premium 14 días', 'banner_home', 'top_1_3', 14, 1199,
       'Posición Top 1–3 en el carousel del inicio. Máxima visibilidad para tu grupo.', true
WHERE NOT EXISTS (
  SELECT 1 FROM public.ad_packages
  WHERE type = 'banner_home' AND tier = 'top_1_3' AND duration_days = 14
);

INSERT INTO public.ad_packages (name, type, tier, duration_days, price, description, is_active)
SELECT 'Banner Inicio Premium 30 días', 'banner_home', 'top_1_3', 30, 1999,
       'Posición Top 1–3 en el carousel del inicio. Máxima visibilidad para tu grupo.', true
WHERE NOT EXISTS (
  SELECT 1 FROM public.ad_packages
  WHERE type = 'banner_home' AND tier = 'top_1_3' AND duration_days = 30
);

-- ── 5. Verificación ───────────────────────────────────────────────────────────

SELECT name, type, tier, duration_days, price, is_active
FROM   public.ad_packages
WHERE  type = 'banner_home'
ORDER  BY tier NULLS LAST, duration_days;

SELECT '160_tier_pricing.sql ejecutado ✅' AS status;
