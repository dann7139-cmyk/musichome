-- 206_stripe_full_payment.sql
-- Agrega columna stripe_payment_method_id a reservations.
-- Requiere: 205a aplicado (mp_payment_id ya existe).

ALTER TABLE reservations
  ADD COLUMN IF NOT EXISTS stripe_payment_method_id TEXT;

CREATE INDEX IF NOT EXISTS idx_res_stripe_pm
  ON reservations(stripe_payment_method_id)
  WHERE stripe_payment_method_id IS NOT NULL;

SELECT '206_stripe_full_payment.sql ejecutado ✅' AS status;
