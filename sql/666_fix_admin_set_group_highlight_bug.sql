-- sql/666 — corrige bug real en admin_set_group_highlight (sql/665)
--
-- Reportado por el usuario: al activar "brillo de marco" desde la web,
-- error "operator does not exist: boolean = integer". Causa: la función
-- declaraba `v_found BOOLEAN` para recibir `GET DIAGNOSTICS ... ROW_COUNT`
-- (que es un entero) y luego comparaba `IF v_found = 0 THEN` — Postgres no
-- tiene el operador boolean = integer, así que la función truena SIEMPRE
-- que se llama, exista o no el grupo. Nunca funcionó desde que se creó.
--
-- Fix: v_found ahora es INT, como debe ser para recibir ROW_COUNT.
--
-- Sandbox probado con BEGIN/ROLLBACK antes de aplicar en real.

CREATE OR REPLACE FUNCTION public.admin_set_group_highlight(p_group_id uuid, p_on boolean)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_caller_role TEXT;
  v_found       INT;
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
