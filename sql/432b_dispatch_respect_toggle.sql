-- ============================================================
-- sql/432b_dispatch_respect_toggle.sql
-- BUG FIX: el toggle exprés del grupo (groups.availability, el
-- switch del dashboard vía set_group_availability — sql/94/118) NO
-- era consultado por el dispatch → el grupo lo apagaba y las
-- solicitudes exprés le llegaban igual.
--
-- Reemplaza ENTERO al sql/432 (misma definición) + UNA condición:
--   COALESCE(g.availability, 'available') = 'available'
--   · 'offline' → excluido (lo que el switch promete)
--   · 'busy'    → excluido también (decisión de producto: semántica
--     intuitiva y a prueba de futuro — un grupo "ocupado" no debe
--     recibir exprés aunque hoy nada escriba ese valor)
--   · NULL     → sigue recibiendo (grupos que nunca tocaron el switch)
--
-- NO toca: available_now/ranking (sql/103), trigger 431/434.
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
      -- [432b] Toggle exprés del grupo: offline Y busy excluyen;
      --        NULL (nunca tocó el switch) sigue recibiendo
      AND COALESCE(g.availability, 'available') = 'available'
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
SELECT
  routine_definition LIKE '%COALESCE(g.availability%'  AS toggle_respetado,
  routine_definition LIKE '%group_unavailability%'     AS filtro_bloqueo_hoy,
  routine_definition LIKE '%''in_progress''%'          AS filtro_tocando,
  routine_definition LIKE '%pending_broadcast%'        AS dispatch_intacto
FROM information_schema.routines
WHERE routine_schema = 'public' AND routine_name = 'dispatch_express_request';
-- Esperado: true | true | true | true

SELECT '432b_dispatch_respect_toggle.sql ejecutado ✅' AS status;
