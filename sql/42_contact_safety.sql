-- ══════════════════════════════════════════════════════════════════════════════
-- 42_contact_safety.sql
-- Blindaje completo: tabla de log de intentos de intercambio de contacto.
-- Ejecutar en Supabase SQL Editor.
-- ══════════════════════════════════════════════════════════════════════════════

CREATE TABLE IF NOT EXISTS public.contact_violation_logs (
  id               UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  reservation_id   UUID        REFERENCES public.reservations(id) ON DELETE CASCADE,
  user_id          UUID        REFERENCES public.profiles(id) ON DELETE SET NULL,
  sender_role      TEXT        NOT NULL CHECK (sender_role IN ('group', 'client')),
  attempted_message TEXT       NOT NULL,
  violation_type   TEXT        NOT NULL CHECK (violation_type IN ('phone', 'email', 'keyword')),
  detected_pattern TEXT,
  created_at       TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_violation_logs_reservation
  ON public.contact_violation_logs(reservation_id);

CREATE INDEX IF NOT EXISTS idx_violation_logs_user
  ON public.contact_violation_logs(user_id);

ALTER TABLE public.contact_violation_logs ENABLE ROW LEVEL SECURITY;

-- Usuarios autenticados pueden insertar sus propias violaciones
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE tablename = 'contact_violation_logs' AND policyname = 'users_insert_own_violations'
  ) THEN
    CREATE POLICY "users_insert_own_violations"
      ON public.contact_violation_logs
      FOR INSERT
      WITH CHECK (user_id = auth.uid());
  END IF;
END $$;

-- Solo admin puede leer los logs
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE tablename = 'contact_violation_logs' AND policyname = 'admin_select_violations'
  ) THEN
    CREATE POLICY "admin_select_violations"
      ON public.contact_violation_logs
      FOR SELECT
      USING (
        EXISTS (
          SELECT 1 FROM public.profiles
          WHERE id = auth.uid() AND role = 'admin'
        )
      );
  END IF;
END $$;

SELECT '42_contact_safety: OK ✅' AS status;
