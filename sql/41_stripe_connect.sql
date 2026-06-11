-- ══════════════════════════════════════════════════════════════════════════════
-- 41_stripe_connect.sql
-- Stripe Connect Express: cuentas de pago para grupos y referidores.
-- Ejecutar en Supabase SQL Editor.
-- ══════════════════════════════════════════════════════════════════════════════

-- ── 1. Tabla groups: Connect Express ──────────────────────────────────────────
ALTER TABLE public.groups
  ADD COLUMN IF NOT EXISTS stripe_account_id           TEXT,
  ADD COLUMN IF NOT EXISTS stripe_onboarding_completed BOOLEAN DEFAULT FALSE,
  ADD COLUMN IF NOT EXISTS referred_by_user_id         UUID REFERENCES public.profiles(id),
  ADD COLUMN IF NOT EXISTS referral_rate               NUMERIC(5,2) DEFAULT 0
    CHECK (referral_rate >= 0 AND referral_rate <= 100);

CREATE INDEX IF NOT EXISTS idx_groups_stripe_account
  ON public.groups(stripe_account_id)
  WHERE stripe_account_id IS NOT NULL;

-- ── 2. Tabla profiles: para referidores ───────────────────────────────────────
ALTER TABLE public.profiles
  ADD COLUMN IF NOT EXISTS stripe_account_id           TEXT,
  ADD COLUMN IF NOT EXISTS stripe_onboarding_completed BOOLEAN DEFAULT FALSE,
  ADD COLUMN IF NOT EXISTS referred_by                 UUID REFERENCES public.profiles(id),
  ADD COLUMN IF NOT EXISTS referral_rate               NUMERIC(5,2) DEFAULT 0
    CHECK (referral_rate >= 0 AND referral_rate <= 100);

CREATE INDEX IF NOT EXISTS idx_profiles_stripe_account_connect
  ON public.profiles(stripe_account_id)
  WHERE stripe_account_id IS NOT NULL;

-- ── 3. Tabla reservations: seguimiento de transferencias ──────────────────────
ALTER TABLE public.reservations
  ADD COLUMN IF NOT EXISTS payout_completed     BOOLEAN DEFAULT FALSE,
  ADD COLUMN IF NOT EXISTS deposit_transfer_id  TEXT,
  ADD COLUMN IF NOT EXISTS final_transfer_id    TEXT,
  ADD COLUMN IF NOT EXISTS referral_transfer_id TEXT;

-- ── 4. RLS: dueño del grupo puede leer sus campos Stripe ──────────────────────
-- (la política de UPDATE existente en groups ya cubre owner_id = auth.uid())

-- Aseguramos que admin pueda actualizar stripe_onboarding_completed via webhook
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE tablename = 'groups' AND policyname = 'admin_update_stripe_onboarding'
  ) THEN
    CREATE POLICY "admin_update_stripe_onboarding"
      ON public.groups FOR UPDATE
      USING (
        EXISTS (SELECT 1 FROM public.profiles WHERE id = auth.uid() AND role = 'admin')
        OR owner_id = auth.uid()
      );
  END IF;
END $$;

SELECT '41_stripe_connect: OK ✅' AS status;
