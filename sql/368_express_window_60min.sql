-- ════════════════════════════════════════════════════════════════════
-- sql/368_express_window_60min.sql
--
-- Extiende la ventana Express de 15 → 60 minutos.
-- Solo cambia v_window_minutes. El resto de dispatch_express_request
-- es idéntico a sql/367.
-- ════════════════════════════════════════════════════════════════════

BEGIN;

CREATE OR REPLACE FUNCTION public.dispatch_express_request(
  p_request_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
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
$$;

GRANT EXECUTE ON FUNCTION public.dispatch_express_request(uuid) TO authenticated;

COMMIT;

-- Verificación: debe mostrar 60 en la definición
SELECT position('60' IN pg_get_functiondef(oid)) > 0 AS ventana_60min
FROM pg_proc
WHERE proname = 'dispatch_express_request'
  AND pronamespace = 'public'::regnamespace;
