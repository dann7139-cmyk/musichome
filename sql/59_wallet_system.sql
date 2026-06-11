-- ════════════════════════════════════════════════════════════════════
-- 59_wallet_system.sql
-- Sistema de billetera interna (wallets, wallet_transactions, withdrawals)
-- Ejecutar en Supabase SQL Editor ANTES de 60 y 61.
-- ════════════════════════════════════════════════════════════════════

-- ── 1. Columnas nuevas en reservations ───────────────────────────────────────
ALTER TABLE public.reservations
  ADD COLUMN IF NOT EXISTS commission_rate     DECIMAL(5,4)   DEFAULT 0.08,
  ADD COLUMN IF NOT EXISTS platform_fee        NUMERIC(12,2),
  ADD COLUMN IF NOT EXISTS wallet_distributed  BOOLEAN        NOT NULL DEFAULT FALSE,
  ADD COLUMN IF NOT EXISTS mp_preference_id    TEXT,
  ADD COLUMN IF NOT EXISTS mp_payment_id       TEXT;

-- ── 2. WALLETS ────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.wallets (
  id                UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id           UUID        NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  available_balance NUMERIC(12,2) NOT NULL DEFAULT 0 CHECK (available_balance >= 0),
  pending_balance   NUMERIC(12,2) NOT NULL DEFAULT 0 CHECK (pending_balance   >= 0),
  total_earned      NUMERIC(12,2) NOT NULL DEFAULT 0,
  updated_at        TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
  CONSTRAINT wallets_user_unique UNIQUE (user_id)
);

CREATE INDEX IF NOT EXISTS idx_wallets_user ON public.wallets(user_id);

-- Crear wallet automáticamente cuando se inserta un profile
CREATE OR REPLACE FUNCTION public.create_wallet_for_new_profile()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
  INSERT INTO public.wallets (user_id)
  VALUES (NEW.id)
  ON CONFLICT (user_id) DO NOTHING;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS on_new_profile_create_wallet ON public.profiles;
CREATE TRIGGER on_new_profile_create_wallet
  AFTER INSERT ON public.profiles
  FOR EACH ROW EXECUTE FUNCTION public.create_wallet_for_new_profile();

-- Crear wallets para usuarios que ya existen (idempotente)
INSERT INTO public.wallets (user_id)
SELECT id FROM public.profiles
ON CONFLICT (user_id) DO NOTHING;

-- ── 3. WALLET_TRANSACTIONS ────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.wallet_transactions (
  id                 UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id            UUID        NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  amount             NUMERIC(12,2) NOT NULL,
  type               TEXT        NOT NULL CHECK (type IN (
                       'event_earning',   -- ganancia al terminar evento
                       'extra_hour',      -- ganancia por hora extra
                       'withdrawal',      -- retiro descontado de la wallet
                       'commission',      -- comisión retenida (registro admin)
                       'adjustment',      -- ajuste manual
                       'refund'           -- reembolso
                     )),
  status             TEXT        NOT NULL DEFAULT 'completed'
                       CHECK (status IN ('pending', 'completed', 'failed')),
  reference_event_id UUID        REFERENCES public.reservations(id) ON DELETE SET NULL,
  description        TEXT,
  created_at         TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_wt_user       ON public.wallet_transactions(user_id);
CREATE INDEX IF NOT EXISTS idx_wt_event      ON public.wallet_transactions(reference_event_id);
CREATE INDEX IF NOT EXISTS idx_wt_created    ON public.wallet_transactions(created_at DESC);

-- ── 4. WITHDRAWALS ────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.withdrawals (
  id               UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id          UUID        NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  amount           NUMERIC(12,2) NOT NULL CHECK (amount > 0),
  status           TEXT        NOT NULL DEFAULT 'pending'
                     CHECK (status IN ('pending', 'processing', 'completed', 'rejected')),
  payout_method    TEXT        NOT NULL DEFAULT 'spei',
  bank_clabe       TEXT,          -- CLABE interbancaria 18 dígitos
  bank_name        TEXT,
  account_holder   TEXT,
  rejection_reason TEXT,
  processed_at     TIMESTAMPTZ,
  created_at       TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_wd_user    ON public.withdrawals(user_id);
CREATE INDEX IF NOT EXISTS idx_wd_status  ON public.withdrawals(status);
CREATE INDEX IF NOT EXISTS idx_wd_created ON public.withdrawals(created_at DESC);

-- ── 5. RLS ────────────────────────────────────────────────────────────────────
ALTER TABLE public.wallets             ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.wallet_transactions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.withdrawals         ENABLE ROW LEVEL SECURITY;

-- WALLETS
DROP POLICY IF EXISTS "wallet_owner_select"  ON public.wallets;
DROP POLICY IF EXISTS "wallet_admin_select"  ON public.wallets;
DROP POLICY IF EXISTS "wallet_service_all"   ON public.wallets;

CREATE POLICY "wallet_owner_select"
  ON public.wallets FOR SELECT
  USING (auth.uid() = user_id);

CREATE POLICY "wallet_admin_select"
  ON public.wallets FOR SELECT
  USING (EXISTS (SELECT 1 FROM public.profiles WHERE id = auth.uid() AND role = 'admin'));

CREATE POLICY "wallet_service_all"
  ON public.wallets FOR ALL
  USING (true) WITH CHECK (true);

-- WALLET_TRANSACTIONS
DROP POLICY IF EXISTS "wt_owner_select"  ON public.wallet_transactions;
DROP POLICY IF EXISTS "wt_admin_select"  ON public.wallet_transactions;
DROP POLICY IF EXISTS "wt_service_all"   ON public.wallet_transactions;

CREATE POLICY "wt_owner_select"
  ON public.wallet_transactions FOR SELECT
  USING (auth.uid() = user_id);

CREATE POLICY "wt_admin_select"
  ON public.wallet_transactions FOR SELECT
  USING (EXISTS (SELECT 1 FROM public.profiles WHERE id = auth.uid() AND role = 'admin'));

CREATE POLICY "wt_service_all"
  ON public.wallet_transactions FOR ALL
  USING (true) WITH CHECK (true);

-- WITHDRAWALS
DROP POLICY IF EXISTS "wd_owner_all"   ON public.withdrawals;
DROP POLICY IF EXISTS "wd_admin_all"   ON public.withdrawals;
DROP POLICY IF EXISTS "wd_service_all" ON public.withdrawals;

CREATE POLICY "wd_owner_all"
  ON public.withdrawals FOR ALL
  USING (auth.uid() = user_id)
  WITH CHECK (auth.uid() = user_id);

CREATE POLICY "wd_admin_all"
  ON public.withdrawals FOR ALL
  USING (EXISTS (SELECT 1 FROM public.profiles WHERE id = auth.uid() AND role = 'admin'));

CREATE POLICY "wd_service_all"
  ON public.withdrawals FOR ALL
  USING (true) WITH CHECK (true);

SELECT '59_wallet_system: tablas wallets + wallet_transactions + withdrawals creadas ✅' AS status;
