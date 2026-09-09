-- 630_admin_ops_verification_scope_ROLLBACK.sql
BEGIN;

DROP FUNCTION IF EXISTS public.admin_get_pending_group_verifications(integer);
DROP FUNCTION IF EXISTS public.admin_get_pending_profile_verifications(text, integer);

CREATE OR REPLACE FUNCTION public.admin_review_group_verification(p_attempt_id uuid, p_approved boolean, p_notes text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_caller_role TEXT;
  v_group_id    UUID;
  v_status      TEXT;
BEGIN
  SELECT role INTO v_caller_role
  FROM   public.profiles
  WHERE  id = auth.uid();

  IF v_caller_role <> 'admin' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_admin');
  END IF;

  SELECT group_id, status INTO v_group_id, v_status
  FROM   public.verification_requests
  WHERE  id = p_attempt_id;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'attempt_not_found');
  END IF;
  IF v_status <> 'pending' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'attempt_not_pending');
  END IF;

  UPDATE public.verification_requests
  SET    status      = CASE WHEN p_approved THEN 'approved' ELSE 'rejected' END,
         admin_notes = p_notes,
         reviewed_at = now()
  WHERE  id = p_attempt_id;

  IF p_approved THEN
    UPDATE public.groups
    SET    is_verified         = TRUE,
           admin_verified      = TRUE,
           verification_status = 'approved'
    WHERE  id = v_group_id;
  ELSE
    UPDATE public.groups
    SET    is_verified         = FALSE,
           admin_verified      = FALSE,
           verification_status = 'rejected'
    WHERE  id = v_group_id;
  END IF;

  RETURN jsonb_build_object('ok', true, 'group_id', v_group_id);
END;
$function$;

CREATE OR REPLACE FUNCTION public.admin_set_profile_verified(p_user_id uuid, p_verified boolean, p_note text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_admin_id  UUID;
  v_user_name TEXT;
  v_user_role TEXT;
BEGIN
  SELECT id INTO v_admin_id
  FROM public.profiles
  WHERE id = auth.uid() AND role = 'admin';

  IF v_admin_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_admin');
  END IF;

  SELECT full_name, role INTO v_user_name, v_user_role
  FROM public.profiles
  WHERE id = p_user_id;

  IF v_user_name IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'user_not_found');
  END IF;

  IF v_user_role NOT IN ('client', 'talent') THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_role');
  END IF;

  UPDATE public.profiles
  SET
    admin_verified           = p_verified,
    verification_status      = CASE WHEN p_verified THEN 'approved' ELSE 'rejected' END,
    verification_admin_notes = COALESCE(p_note, verification_admin_notes),
    verification_reviewed_at = NOW()
  WHERE id = p_user_id;

  RETURN jsonb_build_object('ok', true, 'verified', p_verified, 'user', v_user_name, 'role', v_user_role);
END;
$function$;

COMMIT;
