-- ============================================================
-- sql/219_job_invitation_notify_trigger.sql
-- Fixes:
--   1. Re-aplica políticas RLS de job_invitations (idempotente)
--   2. Trigger que crea notificación in-app al talento
--      cada vez que un grupo le envía una invitación
-- Ejecutar en: Supabase Dashboard → SQL Editor
-- ============================================================

-- ── 1. RLS (idempotente, copia exacta de 218) ────────────────────────────────

CREATE OR REPLACE FUNCTION public.is_group_owner(p_group_id UUID)
RETURNS BOOLEAN LANGUAGE sql SECURITY DEFINER STABLE
SET search_path = public AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.groups WHERE id = p_group_id AND owner_id = auth.uid()
  );
$$;
GRANT EXECUTE ON FUNCTION public.is_group_owner(UUID) TO authenticated;

DROP POLICY IF EXISTS "jinv_insert" ON public.job_invitations;
CREATE POLICY "jinv_insert" ON public.job_invitations FOR INSERT
  WITH CHECK (public.is_group_owner(group_id));

DROP POLICY IF EXISTS "jinv_select" ON public.job_invitations;
CREATE POLICY "jinv_select" ON public.job_invitations FOR SELECT
  USING (
    invited_user_id = auth.uid()
    OR public.is_group_owner(group_id)
  );

DROP POLICY IF EXISTS "jinv_delete" ON public.job_invitations;
CREATE POLICY "jinv_delete" ON public.job_invitations FOR DELETE
  USING (public.is_group_owner(group_id));

DROP POLICY IF EXISTS "jinv_update" ON public.job_invitations;
CREATE POLICY "jinv_update" ON public.job_invitations FOR UPDATE
  USING (invited_user_id = auth.uid())
  WITH CHECK (status IN ('accepted', 'rejected'));

DROP POLICY IF EXISTS "jinv_admin" ON public.job_invitations;
CREATE POLICY "jinv_admin" ON public.job_invitations FOR ALL
  USING (EXISTS (
    SELECT 1 FROM public.profiles WHERE id = auth.uid() AND role = 'admin'
  ));

-- ── 2. Trigger: notifica al talento al recibir una invitación ────────────────

CREATE OR REPLACE FUNCTION public.notify_talent_on_job_invitation()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_group_name TEXT;
BEGIN
  SELECT name INTO v_group_name
  FROM public.groups
  WHERE id = NEW.group_id;

  INSERT INTO public.notifications (
    user_id, type, title, body, data, reference_id, is_read
  ) VALUES (
    NEW.invited_user_id,
    'job_invitation',
    'Nueva invitación de trabajo 🎵',
    CASE
      WHEN NEW.event_id IS NOT NULL
        THEN COALESCE(v_group_name, 'Un grupo') || ' te invitó a una tocada'
      ELSE
        COALESCE(v_group_name, 'Un grupo') || ' te invitó a unirse al grupo'
    END,
    jsonb_build_object(
      'invitation_id', NEW.id,
      'group_id',      NEW.group_id,
      'group_name',    v_group_name,
      'event_id',      NEW.event_id,
      'screen',        'Bolsa'
    ),
    NEW.id,
    false
  )
  ON CONFLICT DO NOTHING;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_notify_talent_on_job_invitation ON public.job_invitations;
CREATE TRIGGER trg_notify_talent_on_job_invitation
  AFTER INSERT ON public.job_invitations
  FOR EACH ROW
  EXECUTE FUNCTION public.notify_talent_on_job_invitation();

-- ── 3. El talento puede leer eventos vinculados a sus invitaciones ────────────
DROP POLICY IF EXISTS "events_talent_select" ON public.events;
CREATE POLICY "events_talent_select" ON public.events FOR SELECT
  USING (
    EXISTS (
      SELECT 1 FROM public.job_invitations ji
      WHERE ji.event_id = events.id
        AND ji.invited_user_id = auth.uid()
    )
  );

SELECT 'Trigger + RLS job_invitations aplicado ✅' AS status;
