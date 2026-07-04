-- ============================================================
-- sql/432_dispatch_express_availability.sql
-- LOTE 2 · Filtro de disponibilidad en el dispatch exprés
--
-- Base: definición VIGENTE de prod (pegada por líneas, 77 líneas) —
-- NO la del repo (sql/368). Cambio ÚNICO: dos NOT EXISTS en el WHERE
-- de selección de grupos:
--   (i)  bloqueó HOY — fecha LOCAL CDMX, no la fecha UTC de sesión
--        (familia sql/417)
--   (ii) está tocando AHORA MISMO (reservations.status='in_progress')
--
-- Un grupo bloqueado/ocupado ya no recibe la tarjeta exprés y su
-- slot del LIMIT lo toma un grupo que SÍ puede ir.
-- Deliberadamente NO se filtra por eventos confirmados de hoy a otra
-- hora (esa finura es el Lote 3 — sería sobre-bloquear).
--
-- CONSERVADO byte a byte: genre, ciudad/estado, is_active,
-- suspended_at, exclusión de ya-despachados, ORDER (ciudad exacta →
-- verificado → rating), LIMIT 10, ventana 60 min, ON CONFLICT,
-- express_window_until y el JSON de retorno.
-- NO toca: available_now/ranking (sql/103), candado 430, trigger 431.
-- ============================================================

BEGIN;

CREATE OR REPLACE FUNCTION public.dispatch_express_request(p_request_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_request         public.event_requests%ROWTYPE;
  v_group_row       RECORD;
  v_dispatched      int := 0;
  v_window_minutes  int := 60;
  v_max_groups      int := 10;
BEGIN
  SELECT * INTO v_request
  FROM public.event_requests
  WHERE id = p_request_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'request_not_found');
  END IF;

  IF v_request.status <> 'open' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'request_not_open', 'status', v_request.status);
  END IF;

  FOR v_group_row IN
    SELECT g.id AS group_id
    FROM public.groups g
    WHERE
      g.genre = v_request.genre
      AND (
        lower(trim(g.city))  = lower(trim(v_request.location_city))
        OR lower(trim(g.state)) = lower(trim(v_request.location_estado))
      )
      AND g.is_active = true
      AND g.suspended_at IS NULL
      AND NOT EXISTS (
        SELECT 1 FROM public.express_dispatches ed
        WHERE ed.request_id = p_request_id
          AND ed.group_id   = g.id
      )
      -- [432] (i) El grupo bloqueó HOY (fecha local CDMX)
      AND NOT EXISTS (
        SELECT 1 FROM public.group_unavailability gu
        WHERE gu.group_id = g.id
          AND gu.date = (NOW() AT TIME ZONE 'America/Mexico_City')::date
      )
      -- [432] (ii) El grupo está tocando en este momento
      AND NOT EXISTS (
        SELECT 1 FROM public.reservations r
        WHERE r.group_id = g.id
          AND r.status = 'in_progress'
      )
    ORDER BY
      (lower(trim(g.city)) = lower(trim(v_request.location_city))) DESC,
      g.is_verified DESC,
      g.rating DESC NULLS LAST
    LIMIT v_max_groups
  LOOP
    INSERT INTO public.express_dispatches (
      request_id, group_id, status, expires_at
    )
    VALUES (
      p_request_id,
      v_group_row.group_id,
      'pending_broadcast',
      NOW() + (v_window_minutes || ' minutes')::interval
    )
    ON CONFLICT DO NOTHING;

    v_dispatched := v_dispatched + 1;
  END LOOP;

  IF v_dispatched > 0 THEN
    UPDATE public.event_requests
    SET express_window_until = NOW() + (v_window_minutes || ' minutes')::interval
    WHERE id = p_request_id;
  END IF;

  RETURN jsonb_build_object(
    'ok',         true,
    'dispatched', v_dispatched,
    'request_id', p_request_id,
    'window_min', v_window_minutes
  );
END;
$function$;

COMMIT;

-- ── Verificaciones ────────────────────────────────────────────────────────────
-- V1: los 2 filtros nuevos + la lógica vigente intacta
SELECT
  routine_definition LIKE '%group_unavailability%'                     AS filtro_bloqueo_hoy,
  routine_definition LIKE '%America/Mexico_City%'                      AS fecha_local_ok,
  routine_definition LIKE '%''in_progress''%'                          AS filtro_tocando,
  routine_definition LIKE '%g.genre = v_request.genre%'                AS genre_intacto,
  routine_definition LIKE '%pending_broadcast%'                        AS dispatch_intacto
FROM information_schema.routines
WHERE routine_schema = 'public' AND routine_name = 'dispatch_express_request';
-- Esperado: true | true | true | true | true

SELECT '432_dispatch_express_availability.sql ejecutado ✅' AS status;
