-- ============================================================================
-- ROLLBACK sql/654_admin_edit_concierge_media.sql
-- Regresa a las versiones "solo dueño" (y a update_group_video SIN chequeo
-- alguno, que era una fuga real) — ⚠️ NO correr salvo emergencia deliberada.
-- ============================================================================

CREATE OR REPLACE FUNCTION public.update_group_photo(p_group_id uuid, p_photo_url text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM public.groups WHERE id = p_group_id AND owner_id = auth.uid()
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
BEGIN
  UPDATE groups
  SET promo_video   = p_video_url,
      video_status  = 'pending'
  WHERE id = p_group_id;

  IF NOT FOUND THEN
    RETURN json_build_object('ok', false, 'error', 'Grupo no encontrado');
  END IF;

  RETURN json_build_object('ok', true);
END;
$function$;

DROP POLICY IF EXISTS gv_owner_insert ON public.group_videos;
CREATE POLICY gv_owner_insert ON public.group_videos
FOR INSERT
WITH CHECK (
  EXISTS (SELECT 1 FROM public.groups g WHERE g.id = group_videos.group_id AND g.owner_id = auth.uid())
);
