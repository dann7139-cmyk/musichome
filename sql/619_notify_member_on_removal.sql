-- 619_notify_member_on_removal.sql
-- Pedido 2026-09-05: el dueño del grupo puede seguir sacando integrantes
-- libremente (no se le pide aceptar salir — si se pelean, el dueño tiene
-- que poder sacarlo igual), PERO el integrante removido debe enterarse
-- siempre. Esto evita que el dueño saque a alguien "en silencio" justo
-- antes de que le llegue un regalo, y lo vuelva a meter después sin que
-- el afectado se entere. Solo aplica a invitation_type='membership'
-- (integrante fijo del grupo), no a invitaciones de un solo evento/job.

CREATE OR REPLACE FUNCTION public.delete_group_invitation(p_invitation_id uuid)
 RETURNS json
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_group_id UUID;
  v_invited_user UUID;
  v_invitation_type TEXT;
  v_group_name TEXT;
BEGIN
  SELECT group_id, invited_user_id, invitation_type INTO v_group_id, v_invited_user, v_invitation_type
  FROM public.job_invitations
  WHERE id = p_invitation_id;

  IF NOT FOUND THEN
    RETURN json_build_object('error', 'Invitación no encontrada');
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.groups
    WHERE id = v_group_id AND owner_id = auth.uid()
  ) THEN
    RETURN json_build_object('error', 'Sin permiso');
  END IF;

  DELETE FROM public.job_invitations WHERE id = p_invitation_id;

  IF v_invitation_type = 'membership' AND v_invited_user IS NOT NULL THEN
    SELECT name INTO v_group_name FROM public.groups WHERE id = v_group_id;
    INSERT INTO public.notifications (user_id, type, title, body, data)
    VALUES (
      v_invited_user, 'system',
      '⚠️ Te sacaron de un grupo',
      COALESCE(v_group_name, 'Un grupo') || ' te quitó como integrante.',
      jsonb_build_object('screen', 'TalentHome')
    );
  END IF;

  RETURN json_build_object('success', true);
END;
$function$;
