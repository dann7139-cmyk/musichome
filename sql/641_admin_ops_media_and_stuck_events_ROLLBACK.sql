-- sql/641_admin_ops_media_and_stuck_events_ROLLBACK.sql
BEGIN;

DROP FUNCTION IF EXISTS public.admin_get_pending_media(integer);
DROP FUNCTION IF EXISTS public.admin_get_stuck_service_events(integer);

DROP POLICY IF EXISTS gep_posts_admin_update ON public.group_event_posts;
CREATE POLICY gep_posts_admin_update ON public.group_event_posts
  FOR UPDATE TO public
  USING (EXISTS (SELECT 1 FROM profiles p WHERE p.id = auth.uid() AND p.role = 'admin'));

DROP POLICY IF EXISTS gv_admin_update ON public.group_videos;
CREATE POLICY gv_admin_update ON public.group_videos
  FOR UPDATE TO public
  USING (EXISTS (SELECT 1 FROM profiles p WHERE p.id = auth.uid() AND p.role = 'admin'));

CREATE OR REPLACE FUNCTION public.approve_group_photo(p_group_id uuid)
RETURNS json LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM profiles WHERE id = auth.uid() AND role = 'admin') THEN
    RETURN json_build_object('ok', false, 'error', 'No autorizado');
  END IF;
  UPDATE groups SET photo_status = 'approved', photo_reject_reason = NULL WHERE id = p_group_id;
  IF NOT FOUND THEN RETURN json_build_object('ok', false, 'error', 'Grupo no encontrado'); END IF;
  RETURN json_build_object('ok', true);
END;
$$;

CREATE OR REPLACE FUNCTION public.reject_group_photo(p_group_id uuid, p_reason text)
RETURNS json LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM profiles WHERE id = auth.uid() AND role = 'admin') THEN
    RETURN json_build_object('ok', false, 'error', 'No autorizado');
  END IF;
  UPDATE groups SET photo_status = 'rejected', photo_reject_reason = p_reason WHERE id = p_group_id;
  IF NOT FOUND THEN RETURN json_build_object('ok', false, 'error', 'Grupo no encontrado'); END IF;
  RETURN json_build_object('ok', true);
END;
$$;

CREATE OR REPLACE FUNCTION public.approve_group_video(p_group_id uuid)
RETURNS json LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM profiles WHERE id = auth.uid() AND role = 'admin') THEN
    RETURN json_build_object('ok', false, 'error', 'No autorizado');
  END IF;
  UPDATE groups SET video_status = 'approved', video_reject_reason = NULL WHERE id = p_group_id;
  IF NOT FOUND THEN RETURN json_build_object('ok', false, 'error', 'Grupo no encontrado'); END IF;
  RETURN json_build_object('ok', true);
END;
$$;

CREATE OR REPLACE FUNCTION public.reject_group_video(p_group_id uuid, p_reason text)
RETURNS json LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM profiles WHERE id = auth.uid() AND role = 'admin') THEN
    RETURN json_build_object('ok', false, 'error', 'No autorizado');
  END IF;
  UPDATE groups SET video_status = 'rejected', video_reject_reason = p_reason WHERE id = p_group_id;
  IF NOT FOUND THEN RETURN json_build_object('ok', false, 'error', 'Grupo no encontrado'); END IF;
  RETURN json_build_object('ok', true);
END;
$$;

COMMIT;

SELECT '641_admin_ops_media_and_stuck_events_ROLLBACK.sql ejecutado ✅' AS status;
