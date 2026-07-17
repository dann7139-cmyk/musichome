-- ============================================================
-- sql/501_promo_pricing_ladder.sql
-- 💰 ESCALERA DE PRECIOS de promociones (2026-07-17)
--
--  Lógica: el Destacado vale MÁS que el Recomendado porque es la
--  columna DORADA y va PRIMERO (la gente lee de izquierda a derecha),
--  además de la insignia DEST en la tarjeta. El Recomendado es el
--  escalón de entrada. Populares no se vende (se gana con eventos).
--
--    Populares    → gratis (orgánico)
--    Recomendado  → $79 (1d) · $199 (3d) · $399 (7d) · sub $399/sem
--    Destacado    → $499 (7d) · $899 (14d) · $1,699 (30d) · sub $1,699/mes
--    Banner Home  → tiers $499-$1,999 (alcance masivo, sin cambio)
--
--  La suscripción mensual del Destacado toma el precio del paquete
--  de 30 días automáticamente (effective_price) — no hay que tocar
--  nada más. El piso anti-fraude (sql/496) también sigue el precio
--  del paquete solo.
-- ============================================================

BEGIN;

-- Ver qué paquetes de Destacado existen HOY (informativo)
-- SELECT id, name, duration_days, price FROM ad_packages
-- WHERE type = 'sponsored_group' ORDER BY duration_days;

UPDATE public.ad_packages SET price = 499
WHERE type = 'sponsored_group' AND duration_days = 7  AND is_active = true;

UPDATE public.ad_packages SET price = 899
WHERE type = 'sponsored_group' AND duration_days = 14 AND is_active = true;

UPDATE public.ad_packages SET price = 1699
WHERE type = 'sponsored_group' AND duration_days = 30 AND is_active = true;

COMMIT;

-- ── VERIFICACIÓN ──────────────────────────────────────────────────────────────
SELECT name, duration_days, price
FROM public.ad_packages
WHERE type = 'sponsored_group' AND is_active = true
ORDER BY duration_days;
-- Esperado: 7d=$499 · 14d=$899 · 30d=$1,699
-- (si alguna duración no existe, el UPDATE de esa fila afecta 0 —
--  dime qué paquetes te salieron y ajusto)

SELECT '501_promo_pricing_ladder.sql ejecutado ✅' AS status;
