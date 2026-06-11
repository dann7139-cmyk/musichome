-- ============================================================
-- sql/239_currency_fields.sql
--
-- FASE 2: Campos multi-moneda
-- México opera en MXN, USA opera en USD.
-- Balances separados — NUNCA mezclar ni convertir automáticamente.
-- Ejecutar ANTES de sql/240_currency_aware_rpcs.sql
-- ============================================================

-- ── reservations: moneda de la transacción ────────────────────────────────────
ALTER TABLE public.reservations
  ADD COLUMN IF NOT EXISTS currency_code TEXT DEFAULT 'MXN'
    CHECK (currency_code IN ('MXN', 'USD')),
  ADD COLUMN IF NOT EXISTS exchange_rate NUMERIC;  -- snapshot del tipo de cambio al reservar

-- Reservas antiguas → MXN (backward compat)
UPDATE public.reservations
  SET currency_code = 'MXN'
  WHERE currency_code IS NULL;

-- ── wallet_transactions: moneda de cada movimiento ────────────────────────────
ALTER TABLE public.wallet_transactions
  ADD COLUMN IF NOT EXISTS currency_code TEXT DEFAULT 'MXN';

-- Transacciones antiguas → MXN
UPDATE public.wallet_transactions
  SET currency_code = 'MXN'
  WHERE currency_code IS NULL;

-- ── group_wallets: saldos USD separados ──────────────────────────────────────
ALTER TABLE public.group_wallets
  ADD COLUMN IF NOT EXISTS available_balance_usd NUMERIC NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS pending_balance_usd   NUMERIC NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS total_earned_usd      NUMERIC NOT NULL DEFAULT 0;

-- Constraint: saldos no negativos (DO block porque IF NOT EXISTS no existe para constraints)
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname = 'chk_usd_balances_non_negative'
      AND conrelid = 'public.group_wallets'::regclass
  ) THEN
    ALTER TABLE public.group_wallets
      ADD CONSTRAINT chk_usd_balances_non_negative
        CHECK (
          available_balance_usd >= 0 AND
          pending_balance_usd   >= 0 AND
          total_earned_usd      >= 0
        );
  END IF;
END;
$$;

-- ── wallets (admin/platform): saldos USD separados ───────────────────────────
ALTER TABLE public.wallets
  ADD COLUMN IF NOT EXISTS available_balance_usd NUMERIC NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS total_earned_usd      NUMERIC NOT NULL DEFAULT 0;

-- ── extra_hours: moneda del cobro ─────────────────────────────────────────────
ALTER TABLE public.extra_hours
  ADD COLUMN IF NOT EXISTS currency_code TEXT DEFAULT 'MXN';

-- ── Comentarios ───────────────────────────────────────────────────────────────
COMMENT ON COLUMN public.reservations.currency_code
  IS 'MXN para eventos en México, USD para eventos en USA. Determina moneda de todos los movimientos de esta reserva.';
COMMENT ON COLUMN public.group_wallets.available_balance_usd
  IS 'Saldo disponible en USD. NUNCA sumar con available_balance (MXN).';
COMMENT ON COLUMN public.group_wallets.pending_balance_usd
  IS 'Ganancias retenidas en USD. NUNCA sumar con pending_balance (MXN).';
COMMENT ON COLUMN public.wallets.available_balance_usd
  IS 'Comisiones de plataforma en USD. NUNCA sumar con available_balance (MXN).';

SELECT '239_currency_fields.sql: campos multi-moneda agregados ✅' AS status;
