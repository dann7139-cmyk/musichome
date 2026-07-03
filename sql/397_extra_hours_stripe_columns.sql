-- ════════════════════════════════════════════════════════════════════
-- sql/397 — Stripe columns + constraints para extra_hours (FASE B)
--
-- Contexto:
--   FASE B habilita pago de horas extra directamente con Stripe + MSI.
--   extra_hours necesita columnas para registrar el pago Stripe y el
--   ciclo de vida del payout (held → half_released → released).
--
-- Cambios:
--   A. 7 columnas nuevas (idempotentes con IF NOT EXISTS).
--   B. Status CHECK ampliado: agrega 'paid' (Stripe pagado).
--   C. payout_status CHECK nuevo: held/half_released/released/blocked/refunded.
-- ════════════════════════════════════════════════════════════════════

BEGIN;

-- ── A. Columnas nuevas ────────────────────────────────────────────────────────

ALTER TABLE public.extra_hours
  ADD COLUMN IF NOT EXISTS stripe_payment_id TEXT,
  ADD COLUMN IF NOT EXISTS paid_at           TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS msi_months        INTEGER       DEFAULT 1,
  ADD COLUMN IF NOT EXISTS msi_fee_amount    NUMERIC(12,2) DEFAULT 0,
  ADD COLUMN IF NOT EXISTS payout_status     TEXT          DEFAULT 'held',
  ADD COLUMN IF NOT EXISTS half_released_at  TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS released_at       TIMESTAMPTZ;

-- ── B. Status CHECK — ampliar con 'paid' ─────────────────────────────────────
-- Usar DO block para encontrar y dropear cualquier constraint de status
-- independientemente del nombre (seguro contra renombres históricos).

DO $$
DECLARE
  v_con TEXT;
BEGIN
  FOR v_con IN
    SELECT c.conname
    FROM   pg_constraint c
    JOIN   pg_class      t ON t.oid = c.conrelid
    WHERE  t.relname       = 'extra_hours'
      AND  t.relnamespace  = (SELECT oid FROM pg_namespace WHERE nspname = 'public')
      AND  c.contype       = 'c'
      AND  pg_get_constraintdef(c.oid) LIKE '%status%'
      AND  c.conname NOT LIKE '%payout_status%'
  LOOP
    EXECUTE format('ALTER TABLE public.extra_hours DROP CONSTRAINT IF EXISTS %I', v_con);
    RAISE NOTICE '[397] Dropped status constraint: %', v_con;
  END LOOP;
END;
$$;

ALTER TABLE public.extra_hours
  ADD CONSTRAINT extra_hours_status_check
    CHECK (status IN (
      'pending',
      'client_requested',
      'awaiting_group_confirmation',
      'accepted',
      'rejected',
      'expired',
      'paid'
    ));

-- ── C. payout_status CHECK ────────────────────────────────────────────────────

DO $$
DECLARE
  v_con TEXT;
BEGIN
  FOR v_con IN
    SELECT c.conname
    FROM   pg_constraint c
    JOIN   pg_class      t ON t.oid = c.conrelid
    WHERE  t.relname      = 'extra_hours'
      AND  t.relnamespace = (SELECT oid FROM pg_namespace WHERE nspname = 'public')
      AND  c.contype      = 'c'
      AND  pg_get_constraintdef(c.oid) LIKE '%payout_status%'
  LOOP
    EXECUTE format('ALTER TABLE public.extra_hours DROP CONSTRAINT IF EXISTS %I', v_con);
    RAISE NOTICE '[397] Dropped payout_status constraint: %', v_con;
  END LOOP;
END;
$$;

ALTER TABLE public.extra_hours
  ADD CONSTRAINT extra_hours_payout_status_check
    CHECK (payout_status IN (
      'held',
      'half_released',
      'released',
      'blocked',
      'refunded'
    ));

COMMIT;

-- ════════════════════════════════════════════════════════════════════
-- VERIFICACIONES (ejecutar separado después del COMMIT)
-- ════════════════════════════════════════════════════════════════════

-- V1: Columnas nuevas existen
SELECT
  COUNT(*) FILTER (WHERE column_name = 'stripe_payment_id') > 0 AS col_stripe_payment_id,
  COUNT(*) FILTER (WHERE column_name = 'paid_at')           > 0 AS col_paid_at,
  COUNT(*) FILTER (WHERE column_name = 'msi_months')        > 0 AS col_msi_months,
  COUNT(*) FILTER (WHERE column_name = 'payout_status')     > 0 AS col_payout_status,
  COUNT(*) FILTER (WHERE column_name = 'msi_fee_amount')    > 0 AS col_msi_fee_amount
FROM information_schema.columns
WHERE table_schema = 'public' AND table_name = 'extra_hours';
-- Esperado: true | true | true | true | true

-- V2: Status constraint incluye 'paid'
SELECT pg_get_constraintdef(c.oid) LIKE '%paid%' AS status_incluye_paid
FROM   pg_constraint c
JOIN   pg_class      t ON t.oid = c.conrelid
WHERE  t.relname    = 'extra_hours'
  AND  c.conname    = 'extra_hours_status_check';
-- Esperado: true

-- V3: payout_status constraint existe
SELECT COUNT(*) = 1 AS payout_constraint_existe
FROM   pg_constraint c
JOIN   pg_class      t ON t.oid = c.conrelid
WHERE  t.relname    = 'extra_hours'
  AND  c.conname    = 'extra_hours_payout_status_check';
-- Esperado: true

-- V4: Tabla sigue accesible tras los cambios
SELECT COUNT(*) >= 0 AS tabla_accesible FROM public.extra_hours;
-- Esperado: true
