-- ============================================================================
-- ROLLBACK sql/655_admin_media_autoaprobado.sql
-- Regresa a que TODA foto/video (incluso subida por admin) quede 'pending'
-- esperando revisión manual en MediaReviewScreen — ⚠️ NO correr salvo
-- emergencia deliberada.
-- ============================================================================

CREATE OR REPLACE FUNCTION public.guard_group_videos_limit()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_count INT;
  v_plus  BOOLEAN;
  v_max   INT;
BEGIN
  v_plus := is_group_plus(NEW.group_id);
  v_max  := CASE WHEN v_plus THEN 3 ELSE 1 END;

  SELECT COUNT(*) INTO v_count FROM group_videos
  WHERE group_id = NEW.group_id AND status <> 'rejected';

  IF v_count >= v_max THEN
    IF v_plus THEN
      RAISE EXCEPTION 'Ya tienes % videos (el máximo con Plus es 3). Elimina uno para subir otro.', v_count;
    ELSE
      RAISE EXCEPTION 'Tu plan incluye 1 video. Con la insignia Plus desbloqueas 2 más (hasta 3).';
    END IF;
  END IF;

  RETURN NEW;
END;
$function$;

CREATE OR REPLACE FUNCTION public.update_group_photo(p_group_id uuid, p_photo_url text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_caller_role TEXT;
  v_group       RECORD;
BEGIN
  SELECT role INTO v_caller_role FROM public.profiles WHERE id = auth.uid();
  SELECT id, owner_id, country INTO v_group FROM public.groups WHERE id = p_group_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'group_not_found');
  END IF;

  IF NOT (
    v_group.owner_id = auth.uid()
    OR v_caller_role = 'admin'
    OR (v_caller_role = 'admin_ops' AND public.country_code_of(v_group.country) = public.admin_ops_country())
  ) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_owner');
  END IF;

  UPDATE public.groups
  SET profile_image = p_photo_url
  WHERE id = p_group_id;

  BEGIN
    EXECUTE 'UPDATE public.groups SET photo_status = ''pending'' WHERE id = $1'
      USING p_group_id;
  EXCEPTION WHEN OTHERS THEN
    NULL;
  END;

  RETURN jsonb_build_object('ok', true);
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$function$;

CREATE OR REPLACE FUNCTION public.update_group_video(p_group_id uuid, p_video_url text)
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_caller_role TEXT;
  v_group       RECORD;
BEGIN
  SELECT role INTO v_caller_role FROM public.profiles WHERE id = auth.uid();
  SELECT id, owner_id, country INTO v_group FROM public.groups WHERE id = p_group_id;
  IF NOT FOUND THEN
    RETURN json_build_object('ok', false, 'error', 'Grupo no encontrado');
  END IF;

  IF NOT (
    v_group.owner_id = auth.uid()
    OR v_caller_role = 'admin'
    OR (v_caller_role = 'admin_ops' AND public.country_code_of(v_group.country) = public.admin_ops_country())
  ) THEN
    RETURN json_build_object('ok', false, 'error', 'not_owner');
  END IF;

  UPDATE public.groups
  SET promo_video  = p_video_url,
      video_status = 'pending'
  WHERE id = p_group_id;

  RETURN json_build_object('ok', true);
END;
$function$;
