-- ============================================================
-- 560_get_group_completed_events_count.sql
--
-- BUG CONFIRMADO (diagnosticado antes en esta sesión, pendiente de
-- aplicar): el badge "N eventos realizados" en GroupDetailScreen.tsx
-- se calcula con una consulta directa a reservations, filtrada por
-- RLS a "mis propias reservas" — un cliente que nunca contrató a ese
-- grupo siempre ve 0, sin importar cuántos eventos reales tenga el
-- grupo con OTROS clientes.
--
-- FIX: función SECURITY DEFINER que solo devuelve el conteo (nada de
-- datos sensibles de otras reservas) — mismo patrón que
-- get_group_reviews.
-- ============================================================

BEGIN;

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_proc WHERE proname='get_group_completed_events_count' AND pronamespace='public'::regnamespace) THEN
    RAISE EXCEPTION 'ABORT: get_group_completed_events_count ya existe';
  END IF;
END $$;

CREATE FUNCTION public.get_group_completed_events_count(p_group_id uuid)
RETURNS integer
LANGUAGE sql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
  SELECT COUNT(*)::int FROM public.reservations
  WHERE group_id = p_group_id AND status = 'completed';
$function$;

GRANT EXECUTE ON FUNCTION public.get_group_completed_events_count(uuid) TO authenticated, anon;

COMMIT;

SELECT '560_get_group_completed_events_count preparado' AS status;
