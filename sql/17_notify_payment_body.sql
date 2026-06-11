-- ============================================================
-- sql/17_notify_payment_body.sql
-- FASE 3 PASO 4 — Notificaciones con monto en el cuerpo
-- Actualiza notify_on_job_invitation para incluir:
--   "Monto: $XXX" cuando la invitación tiene pago propuesto
-- Ejecutar en: Supabase Dashboard → SQL Editor
-- ============================================================

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
    v_title := '🎵 Nuevo evento disponible';
    v_body  := COALESCE(v_group_name, 'Un grupo') || ' te invitó a colaborar';
  END IF;

  -- Agregar monto propuesto si existe
  IF NEW.proposed_payment_amount IS NOT NULL AND NEW.proposed_payment_amount > 0 THEN
    v_body := v_body || '. Monto: $' || ROUND(NEW.proposed_payment_amount)::TEXT;
  END IF;

  -- Insertar notificación interna (push_sent_at = NULL → Edge Function la recoge)
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

-- Re-attach trigger (idempotente)
DROP TRIGGER IF EXISTS trigger_notify_job_invitation ON public.job_invitations;
CREATE TRIGGER trigger_notify_job_invitation
  AFTER INSERT ON public.job_invitations
  FOR EACH ROW EXECUTE FUNCTION public.notify_on_job_invitation();

SELECT 'notify_on_job_invitation actualizado con monto ✅' AS status;
