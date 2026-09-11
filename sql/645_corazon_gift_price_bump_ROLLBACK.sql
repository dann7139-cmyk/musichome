-- sql/645_corazon_gift_price_bump_ROLLBACK.sql
-- Revierte sql/645: regresa Corazón MXN a $10 (precio con el que se
-- pierde ~$1 por envío después de comisión de Stripe+Radar — ver
-- sql/645 para el detalle).
BEGIN;

UPDATE gift_catalog_prices
SET amount = 10
WHERE currency_code = 'MXN'
  AND gift_id = (SELECT id FROM gift_catalog WHERE name = 'Corazón');

COMMIT;

SELECT '645_corazon_gift_price_bump_ROLLBACK.sql ejecutado ✅' AS status;
