-- ══════════════════════════════════════════════════════════════════════════════
-- 35_payment_status.sql
-- Agrega payment_status a reservations para rastrear el ciclo de pago.
-- Ejecutar en Supabase SQL Editor.
-- ══════════════════════════════════════════════════════════════════════════════

ALTER TABLE public.reservations
  ADD COLUMN IF NOT EXISTS payment_status TEXT DEFAULT 'unpaid'
    CHECK (payment_status IN ('unpaid', 'deposit_pending', 'deposit_paid', 'fully_paid'));

-- Índice para consultas por estado de pago
CREATE INDEX IF NOT EXISTS idx_reservations_payment_status
  ON public.reservations(payment_status);

SELECT 'payment_status agregado a reservations ✅' AS status;
