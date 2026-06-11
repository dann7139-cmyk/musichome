-- ════════════════════════════════════════════════════════════════════
-- 47_connected_payouts.sql
-- 1. Agrega stripe_payouts_enabled a profiles
-- 2. Crea tabla connected_payouts para registrar cada transfer individual
-- Ejecutar en Supabase SQL Editor
-- ════════════════════════════════════════════════════════════════════

-- ── 1. Columna stripe_payouts_enabled en profiles ─────────────────────
ALTER TABLE public.profiles
  ADD COLUMN IF NOT EXISTS stripe_payouts_enabled BOOLEAN DEFAULT FALSE;

-- ── 2. Tabla connected_payouts ────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.connected_payouts (
  id                 UUID          PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id            UUID          REFERENCES public.profiles(id)     ON DELETE SET NULL,
  reservation_id     UUID          REFERENCES public.reservations(id) ON DELETE SET NULL,
  stripe_transfer_id TEXT,
  amount             NUMERIC(12,2) NOT NULL,
  currency           TEXT          NOT NULL DEFAULT 'mxn',
  status             TEXT          NOT NULL DEFAULT 'pending'
                     CHECK (status IN ('pending', 'completed', 'failed')),
  payout_type        TEXT
                     CHECK (payout_type IN (
                       'deposit_group',
                       'final_group',
                       'deposit_referral',
                       'final_referral',
                       'talent_invited',
                       'member'
                     )),
  created_at         TIMESTAMPTZ   NOT NULL DEFAULT NOW()
);

-- ── 3. Índices ────────────────────────────────────────────────────────
CREATE INDEX IF NOT EXISTS idx_connected_payouts_user        ON public.connected_payouts(user_id);
CREATE INDEX IF NOT EXISTS idx_connected_payouts_reservation ON public.connected_payouts(reservation_id);
CREATE INDEX IF NOT EXISTS idx_connected_payouts_status      ON public.connected_payouts(status);
CREATE INDEX IF NOT EXISTS idx_connected_payouts_created     ON public.connected_payouts(created_at DESC);

-- ── 4. RLS ────────────────────────────────────────────────────────────
ALTER TABLE public.connected_payouts ENABLE ROW LEVEL SECURITY;

-- Borrar políticas si ya existen (para poder re-ejecutar sin error)
DROP POLICY IF EXISTS "users_see_own_payouts"  ON public.connected_payouts;
DROP POLICY IF EXISTS "admin_see_all_payouts"  ON public.connected_payouts;
DROP POLICY IF EXISTS "service_insert_payouts" ON public.connected_payouts;

-- Cada usuario ve solo sus propios payouts
CREATE POLICY "users_see_own_payouts" ON public.connected_payouts
  FOR SELECT
  USING (user_id = auth.uid());

-- Admin ve todos
CREATE POLICY "admin_see_all_payouts" ON public.connected_payouts
  FOR SELECT
  USING (EXISTS (
    SELECT 1 FROM public.profiles WHERE id = auth.uid() AND role = 'admin'
  ));

-- Edge Functions (service role) pueden insertar
CREATE POLICY "service_insert_payouts" ON public.connected_payouts
  FOR INSERT
  WITH CHECK (true);

SELECT '47_connected_payouts: OK ✅' AS status;
