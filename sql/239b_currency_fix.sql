-- ============================================================
-- sql/239b_currency_fix.sql
--
-- Completa la migración de sql/239 que falló en el constraint.
-- Las columnas de reservations, wallet_transactions y group_wallets
-- ya se agregaron. Este script aplica lo que quedó pendiente:
--   1. Constraint de saldos no negativos (sintaxis corregida)
--   2. Columnas USD en wallets (admin)
--   3. Columna currency_code en extra_hours
--   4. Comentarios de documentación
-- ============================================================

-- ── 1. Constraint saldos USD no negativos ─────────────────────────────────────
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
    RAISE NOTICE 'chk_usd_balances_non_negative agregado ✅';
  ELSE
    RAISE NOTICE 'chk_usd_balances_non_negative ya existía — omitido';
  END IF;
END;
$$;

-- ── 2. wallets (admin): columnas USD ──────────────────────────────────────────
ALTER TABLE public.wallets
  ADD COLUMN IF NOT EXISTS available_balance_usd NUMERIC NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS total_earned_usd      NUMERIC NOT NULL DEFAULT 0;

-- ── 3. extra_hours: moneda del cobro ──────────────────────────────────────────
ALTER TABLE public.extra_hours
  ADD COLUMN IF NOT EXISTS currency_code TEXT DEFAULT 'MXN';

-- ── 4. Comentarios ────────────────────────────────────────────────────────────
COMMENT ON COLUMN public.reservations.currency_code
  IS 'MXN para eventos en México, USD para eventos en USA. Determina moneda de todos los movimientos de esta reserva.';
COMMENT ON COLUMN public.group_wallets.available_balance_usd
  IS 'Saldo disponible en USD. NUNCA sumar con available_balance (MXN).';
COMMENT ON COLUMN public.group_wallets.pending_balance_usd
  IS 'Ganancias retenidas en USD. NUNCA sumar con pending_balance (MXN).';
COMMENT ON COLUMN public.wallets.available_balance_usd
  IS 'Comisiones de plataforma en USD. NUNCA sumar con available_balance (MXN).';

SELECT '239b_currency_fix.sql: migración 239 completada ✅' AS status;
