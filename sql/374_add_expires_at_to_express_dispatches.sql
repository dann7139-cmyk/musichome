-- ════════════════════════════════════════════════════════════════════
-- sql/374_add_expires_at_to_express_dispatches.sql
--
-- CAUSA RAÍZ: express_dispatches no tiene columna expires_at.
--   dispatch_express_request intenta INSERT con ese campo → falla en
--   runtime → EXCEPTION lo captura silenciosamente → dispatched=0 →
--   express_window_until nunca se setea → v_is_express=false siempre
--   → guard 2h dispara en todos los requests Express.
--
-- FIX: Agregar expires_at TIMESTAMPTZ a express_dispatches.
--   Idempotente (ADD COLUMN IF NOT EXISTS).
--
-- NO TOCA: pagos, wallets, Stripe, auth, webhooks.
-- ════════════════════════════════════════════════════════════════════

BEGIN;

ALTER TABLE public.express_dispatches
  ADD COLUMN IF NOT EXISTS expires_at TIMESTAMPTZ;

COMMIT;

-- Verificación: debe mostrar 'expires_at' en la lista de columnas
SELECT column_name, data_type, is_nullable
FROM information_schema.columns
WHERE table_schema = 'public'
  AND table_name   = 'express_dispatches'
  AND column_name  = 'expires_at';
