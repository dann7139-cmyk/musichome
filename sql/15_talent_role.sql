-- ============================================================
-- DARICEFY - 15_talent_role.sql
-- FASE 3 — Rol Talent + dos tipos de invitación
-- Ejecutar en Supabase SQL Editor
-- ============================================================

-- ─────────────────────────────────────────────────
-- 1. Añadir 'talent' al CHECK de profiles.role
-- ─────────────────────────────────────────────────
ALTER TABLE public.profiles
  DROP CONSTRAINT IF EXISTS profiles_role_check;

ALTER TABLE public.profiles
  ADD CONSTRAINT profiles_role_check
  CHECK (role IN ('admin', 'group', 'client', 'talent'));

-- ─────────────────────────────────────────────────
-- 2. Añadir invitation_type a job_invitations
--    'event'      → invitación para una tocada específica
--    'membership' → invitación para unirse al grupo de forma permanente
-- ─────────────────────────────────────────────────
ALTER TABLE public.job_invitations
  ADD COLUMN IF NOT EXISTS invitation_type TEXT NOT NULL DEFAULT 'event';

DO $$ BEGIN
  ALTER TABLE public.job_invitations
    ADD CONSTRAINT jinv_type_check
    CHECK (invitation_type IN ('event', 'membership'));
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

-- ─────────────────────────────────────────────────
-- 3. Trigger: crear job_board_profiles vacío
--    automáticamente cuando se registra un talento
-- ─────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.handle_new_talent()
RETURNS TRIGGER AS $$
BEGIN
  IF NEW.role = 'talent' THEN
    INSERT INTO public.job_board_profiles (
      user_id, instrument_or_role, bio, experience_years, is_visible, availability_status
    )
    VALUES (NEW.id, '', NULL, 0, TRUE, 'available')
    ON CONFLICT (user_id) DO NOTHING;
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

DROP TRIGGER IF EXISTS on_talent_profile_created ON public.profiles;
CREATE TRIGGER on_talent_profile_created
  AFTER INSERT ON public.profiles
  FOR EACH ROW EXECUTE FUNCTION public.handle_new_talent();

-- ─────────────────────────────────────────────────
-- 4. Actualizar notify_on_job_invitation
--    - Añadir SECURITY DEFINER (evita problemas de RLS)
--    - Diferenciar notificación según invitation_type
-- ─────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.notify_on_job_invitation()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_group_name TEXT;
  v_title      TEXT;
  v_body       TEXT;
BEGIN
  SELECT name INTO v_group_name
  FROM public.groups
  WHERE id = NEW.group_id;

  IF NEW.invitation_type = 'membership' THEN
    v_title := '🎸 Invitación para unirte al grupo';
    v_body  := COALESCE(v_group_name, 'Un grupo') || ' te invita a unirte como miembro permanente';
  ELSE
    v_title := '🎵 Nueva invitación de trabajo';
    v_body  := COALESCE(v_group_name, 'Un grupo') || ' te invitó a colaborar en un evento';
  END IF;

  INSERT INTO public.notifications (user_id, type, title, body, data)
  VALUES (
    NEW.invited_user_id,
    'job_invitation',
    v_title,
    v_body,
    jsonb_build_object(
      'invitation_id',           NEW.id,
      'group_id',                NEW.group_id,
      'event_id',                NEW.event_id,
      'invitation_type',         NEW.invitation_type,
      'proposed_payment_amount', NEW.proposed_payment_amount
    )
  );

  RETURN NEW;
END;
$$;

-- Re-create trigger with updated function
DROP TRIGGER IF EXISTS trigger_notify_job_invitation ON public.job_invitations;
CREATE TRIGGER trigger_notify_job_invitation
  AFTER INSERT ON public.job_invitations
  FOR EACH ROW EXECUTE FUNCTION public.notify_on_job_invitation();

-- ─────────────────────────────────────────────────
-- 5. RLS: talent puede leer su propio perfil aunque is_visible=FALSE
--    (ya cubierto por la política existente: is_visible=TRUE OR user_id=auth.uid())
--    Verificación:
-- ─────────────────────────────────────────────────
-- jbp_select: is_visible = TRUE OR user_id = auth.uid()  ✅ ya existe
-- jbp_insert: user_id = auth.uid()                       ✅ ya existe
-- jbp_update: user_id = auth.uid()                       ✅ ya existe

SELECT 'Talent role + invitation_type + trigger creados ✅' AS status;
