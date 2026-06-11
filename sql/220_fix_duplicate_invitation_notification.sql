-- ============================================================
-- sql/220_fix_duplicate_invitation_notification.sql
-- Fixes:
--   1. Elimina el trigger antiguo trigger_notify_job_invitation
--      (definido en sql/15 y sql/17) que generaba duplicado con
--      mensaje incorrecto: "Nuevo evento disponible / te invitó a colaborar"
--   2. Elimina la función antigua notify_on_job_invitation()
--   3. Confirma que el trigger correcto (sql/219) sigue activo
-- Ejecutar en: Supabase Dashboard → SQL Editor
-- ============================================================

-- ── 1. Eliminar trigger antiguo ──────────────────────────────────────────────

DROP TRIGGER IF EXISTS trigger_notify_job_invitation ON public.job_invitations;

-- ── 2. Eliminar función antigua ───────────────────────────────────────────────

DROP FUNCTION IF EXISTS public.notify_on_job_invitation() CASCADE;

-- ── 3. Verificar que el trigger correcto sigue en pie ────────────────────────
-- Debe devolver 1 fila: trg_notify_talent_on_job_invitation

SELECT
  trigger_name,
  event_manipulation,
  action_timing,
  action_statement
FROM information_schema.triggers
WHERE event_object_table = 'job_invitations'
  AND trigger_schema = 'public';

-- ── 4. Verificar políticas RLS vigentes ──────────────────────────────────────
-- Debe haber jinv_select con invited_user_id = auth.uid() para que el talento
-- vea sus invitaciones en la Bolsa de trabajo (tab Pendientes).

SELECT policyname, cmd, qual
FROM pg_policies
WHERE tablename = 'job_invitations';

SELECT '220: trigger duplicado eliminado ✅' AS status;
