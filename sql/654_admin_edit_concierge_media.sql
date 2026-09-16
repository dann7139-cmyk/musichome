-- ============================================================================
-- sql/654_admin_edit_concierge_media.sql
-- Bug real: un admin/admin_ops no podía poner la foto ni subir video de un
-- grupo que él mismo dio de alta (modo conserjería) — update_group_photo
-- exigía owner_id = auth.uid() sin excepción, y la política de INSERT en
-- group_videos también era solo-dueño. update_group_video (versión vieja,
-- un solo video) además no tenía NINGÚN chequeo de dueño — cualquier usuario
-- autenticado podía sobreescribir el video de CUALQUIER grupo llamando el
-- RPC directo; se cierra esa fuga de paso.
--
-- Mismo patrón ya usado en group_videos (gv_admin_update/gv_owner_delete/
-- gv_public_read): admin completo siempre puede, admin_ops solo si el país
-- del grupo coincide con el suyo (admin_ops_country()), dueño real siempre
-- puede. Sin exigir concierge_mode=true — ya es así en las políticas
-- hermanas de esta misma tabla, se sigue ese precedente.
-- ============================================================================

-- 1) update_group_photo — agrega el mismo bypass de admin/admin_ops.
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
    NULL; -- columna no existe aún, se ignora
  END;

  RETURN jsonb_build_object('ok', true);
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$function$;

-- 2) update_group_video — antes SIN NINGÚN chequeo de dueño (fuga real).
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

-- 3) group_videos: INSERT solo dejaba al dueño — le falta el mismo bypass
--    que ya tienen las políticas hermanas de UPDATE/DELETE/SELECT de esta tabla.
DROP POLICY IF EXISTS gv_owner_insert ON public.group_videos;

CREATE POLICY gv_owner_insert ON public.group_videos
FOR INSERT
WITH CHECK (
  EXISTS (SELECT 1 FROM public.groups g WHERE g.id = group_videos.group_id AND g.owner_id = auth.uid())
  OR EXISTS (SELECT 1 FROM public.profiles p WHERE p.id = auth.uid() AND p.role = 'admin')
  OR (
    public.admin_ops_country() IS NOT NULL
    AND EXISTS (
      SELECT 1 FROM public.groups g
      WHERE g.id = group_videos.group_id
        AND public.country_code_of(g.country) = public.admin_ops_country()
    )
  )
);
