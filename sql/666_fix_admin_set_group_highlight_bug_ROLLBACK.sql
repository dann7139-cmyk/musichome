-- ROLLBACK de sql/666 — regresa admin_set_group_highlight a la versión
-- con el bug (v_found BOOLEAN). NO se recomienda correr esto salvo
-- emergencia: dejaría el botón de brillo de marco roto otra vez.

CREATE OR REPLACE FUNCTION public.admin_set_group_highlight(p_group_id uuid, p_on boolean)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_caller_role TEXT;
  v_found       BOOLEAN;
BEGIN
  SELECT role INTO v_caller_role FROM public.profiles WHERE id = auth.uid();
  IF v_caller_role IS DISTINCT FROM 'admin' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'Acceso denegado');
  END IF;

  UPDATE public.groups SET admin_highlight = p_on WHERE id = p_group_id;
  GET DIAGNOSTICS v_found = ROW_COUNT;
  IF v_found = 0 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'Grupo no encontrado');
  END IF;

  RETURN jsonb_build_object('ok', true, 'admin_highlight', p_on);
END;
$function$;
