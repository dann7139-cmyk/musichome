-- ============================================================
-- 40_stripe_customer.sql
-- Guarda el Stripe Customer ID en profiles y el payment_method
-- en reservations para cobrar el 50% restante automáticamente.
-- ============================================================

-- Stripe Customer ID en profiles (para reutilizar entre reservas)
ALTER TABLE public.profiles
  ADD COLUMN IF NOT EXISTS stripe_customer_id TEXT;

-- Payment Method ID en reservations (guardado al pagar el anticipo)
ALTER TABLE public.reservations
  ADD COLUMN IF NOT EXISTS stripe_payment_method_id TEXT;

-- Índice para buscar rápido por stripe_customer_id
CREATE INDEX IF NOT EXISTS idx_profiles_stripe_customer
  ON public.profiles(stripe_customer_id)
  WHERE stripe_customer_id IS NOT NULL;

SELECT '40_stripe_customer: OK ✅' AS status;
