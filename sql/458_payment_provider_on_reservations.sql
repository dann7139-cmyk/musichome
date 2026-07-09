-- ============================================================
-- sql/458_payment_provider_on_reservations.sql
-- Columna para saber por qué proveedor se cobró cada reserva → para que el
-- REEMBOLSO vuelva por el rail correcto (Stripe / Conekta / MercadoPago).
--
-- Default 'stripe' (el flujo activo hoy). El webhook de Conekta la pondrá
-- en 'conekta' al confirmar el pago. NO toca wallet, GPS ni anti-fraude.
-- ============================================================

BEGIN;

ALTER TABLE public.reservations
  ADD COLUMN IF NOT EXISTS payment_provider TEXT NOT NULL DEFAULT 'stripe';

-- Constraint de valores válidos (NOT VALID: no revalida filas legacy)
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'reservations_payment_provider_check'
  ) THEN
    ALTER TABLE public.reservations
      ADD CONSTRAINT reservations_payment_provider_check
      CHECK (payment_provider IN ('stripe','conekta','mercadopago')) NOT VALID;
  END IF;
END $$;

COMMIT;

-- ── VERIFICACIÓN ────────────────────────────────────────────────────────────────
SELECT column_name, data_type, column_default
FROM information_schema.columns
WHERE table_name = 'reservations' AND column_name = 'payment_provider';
-- Esperado: payment_provider | text | 'stripe'::text

SELECT '458_payment_provider_on_reservations.sql ejecutado ✅' AS status;
