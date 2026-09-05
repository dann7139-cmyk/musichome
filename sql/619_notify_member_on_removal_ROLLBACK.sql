-- 619_notify_member_on_removal_ROLLBACK.sql
CREATE OR REPLACE FUNCTION public.delete_group_invitation(p_invitation_id uuid)
 RETURNS json
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_group_id UUID;
BEGIN
  SELECT group_id INTO v_group_id
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

  RETURN json_build_object('success', true);
END;
$function$;
