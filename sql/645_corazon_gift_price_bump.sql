-- ============================================================
-- sql/645_corazon_gift_price_bump.sql
--
-- Hallazgo real (2026-09-11), revisando el regalo real de $30 (Fuego)
-- en el Stripe dashboard: el reparto de regalos es 60% grupo / 40%
-- plataforma (PLATFORM_CUT en create-gift-payment-intent, NO 85/15 como
-- asumían las pruebas viejas de sql/602 — esas quedan igual porque solo
-- verifican que el screen abierto sea GiftReveal, no el % exacto).
--
-- Con el 40% real, TODOS los regalos del catálogo son rentables después
-- de la comisión real de Stripe ((monto×3.6%+$3)×1.16 IVA) + Radar
-- ($0.95+IVA=$1.10 por transacción) — EXCEPTO Corazón ($10 MXN):
--   40% de $10 = $4.00 · comisión Stripe+Radar ≈ $5.00 · pierde ~$1.00
-- Fuego ($30) ya da +$6.17 neto, y sube desde ahí. Confirmado con el
-- usuario (AskUserQuestion): subir Corazón a $20 MXN.
--   40% de $20 = $8.00 · comisión Stripe+Radar ≈ $5.42 · gana ~$2.58
--
-- Precio en USD ($1) NO se toca — la estructura de comisión de EE.UU.
-- (2.9%+$0.30, sin Radar en pesos) no tiene el mismo problema: ya da
-- ganancia neta positiva a $1 USD.
--
-- Sin cambios de app necesarios: GiftPickerModal.tsx lee el precio en
-- vivo de gift_catalog_prices, nunca lo tiene escrito a mano.
-- ============================================================

BEGIN;

UPDATE gift_catalog_prices
SET amount = 20
WHERE currency_code = 'MXN'
  AND gift_id = (SELECT id FROM gift_catalog WHERE name = 'Corazón');

COMMIT;

-- ── VERIFICACIÓN ────────────────────────────────────────────
SELECT gc.name, gcp.currency_code, gcp.amount
FROM gift_catalog gc JOIN gift_catalog_prices gcp ON gcp.gift_id = gc.id
WHERE gc.name = 'Corazón';
-- Esperado: MXN 20, USD 1 (sin cambio)

SELECT '645_corazon_gift_price_bump.sql ejecutado ✅' AS status;
