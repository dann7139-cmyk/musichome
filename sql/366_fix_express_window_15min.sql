-- ════════════════════════════════════════════════════════════════════
-- sql/366_fix_express_window_15min.sql
--
-- Fixes Express:
--   1. dispatch_express_request: ventana 3 → 15 minutos
--   2. release_expired_express_locks: solo marca dispatches como
--      'expired', NO toca event_request.status
--   3. propose_event_request:
--        · Errores granulares (expired vs not_available)
--        · Guard de 2h omitido para solicitudes Express
-- ════════════════════════════════════════════════════════════════════


-- ── 1. Ventana Express: 3 → 15 minutos ───────────────────────────────────────

CREATE OR REPLACE FUNCTION public.dispatch_express_request(
  p_request_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_request          public.event_requests%ROWTYPE;
  v_group_row        RECORD;
  v_dispatched       int  := 0;
  v_window_minutes   int  := 15;   -- antes: 3 minutos
  v_max_groups       int  := 10;
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
      AND (g.suspended_at IS NULL)
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
    'ok',          true,
    'dispatched',  v_dispatched,
    'request_id',  p_request_id,
    'window_min',  v_window_minutes
  );

END;
$$;

GRANT EXECUTE ON FUNCTION public.dispatch_express_request(uuid) TO authenticated;


-- ── 2. release_expired_express_locks ─────────────────────────────────────────
-- DROP requerido: el tipo de retorno cambió (void/int → jsonb)

DROP FUNCTION IF EXISTS public.release_expired_express_locks();

CREATE FUNCTION public.release_expired_express_locks()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_released int := 0;
BEGIN
  -- Solo marca dispatches vencidos como 'expired'.
  -- NO cambia event_request.status — la request sigue 'open'.
  UPDATE public.express_dispatches
  SET    status     = 'expired',
         updated_at = NOW()
  WHERE  status    IN ('pending_broadcast', 'locked')
    AND  expires_at < NOW();

  GET DIAGNOSTICS v_released = ROW_COUNT;

  RETURN jsonb_build_object(
    'ok',       true,
    'released', v_released,
    'ran_at',   NOW()
  );

EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$$;

GRANT EXECUTE ON FUNCTION public.release_expired_express_locks() TO service_role;


-- ── 3. propose_event_request: errores granulares + Express omite guard 2h ────

CREATE OR REPLACE FUNCTION public.propose_event_request(
  p_request_id     UUID,
  p_price_per_hour NUMERIC  DEFAULT NULL,
  p_travel_cost    NUMERIC  DEFAULT 0,
  p_overtime_1h    NUMERIC  DEFAULT NULL,
  p_overtime_2h    NUMERIC  DEFAULT NULL,
  p_overtime_3h    NUMERIC  DEFAULT NULL,
  p_notes          TEXT     DEFAULT NULL,
  p_member_dist    JSONB    DEFAULT NULL,
  p_arrival_time   TEXT     DEFAULT NULL,
  p_start_time     TEXT     DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_req        RECORD;
  v_group      RECORD;
  v_hours      INTEGER;
  v_base       NUMERIC;
  v_total      NUMERIC;
  v_comm       NUMERIC;
  v_is_express BOOLEAN := false;
BEGIN
  SELECT * INTO v_group
  FROM   public.groups
  WHERE  owner_id = auth.uid()
  LIMIT  1;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'no_group_found');
  END IF;

  SELECT * INTO v_req
  FROM   public.event_requests
  WHERE  id = p_request_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'request_not_found');
  END IF;

  -- Error granular: 'expired'/'cancelled' → request_expired
  IF v_req.status IN ('expired', 'cancelled') THEN
    RETURN jsonb_build_object('ok', false, 'error', 'request_expired');
  END IF;

  -- Cualquier otro status distinto de 'open' → otro grupo llegó primero
  IF v_req.status <> 'open' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_available');
  END IF;

  IF v_req.expires_at < NOW() THEN
    RETURN jsonb_build_object('ok', false, 'error', 'request_expired');
  END IF;

  -- Detectar si viene del canal Express (dispatch activo para este grupo)
  SELECT EXISTS (
    SELECT 1 FROM public.express_dispatches ed
    WHERE  ed.request_id = p_request_id
      AND  ed.group_id   = v_group.id
      AND  ed.status     NOT IN ('expired', 'ignored', 'taken')
  ) INTO v_is_express;

  -- Guard de proximidad (< 2 h) — omitido para solicitudes Express,
  -- ya que Express es para eventos urgentes/inmediatos por definición.
  IF NOT v_is_express THEN
    IF (v_req.event_date::TIMESTAMP
        + COALESCE(v_req.event_time::INTERVAL, '0'::INTERVAL))
       < NOW() + INTERVAL '2 hours' THEN
      RETURN jsonb_build_object('ok', false, 'error', 'too_close_to_event');
    END IF;
  END IF;

  IF v_group.genre <> v_req.genre THEN
    RETURN jsonb_build_object('ok', false, 'error', 'genre_mismatch');
  END IF;

  v_hours := COALESCE(v_req.hours, 3);
  v_base  := COALESCE(p_price_per_hour, 0) * v_hours;
  v_total := v_base + COALESCE(p_travel_cost, 0);
  v_comm  := v_hours * 150;

  UPDATE public.event_requests
  SET
    status               = 'en_negociacion',
    negotiating_group_id = auth.uid(),
    proposal_data        = jsonb_build_object(
      'price_per_hour',    p_price_per_hour,
      'travel_cost',       COALESCE(p_travel_cost, 0),
      'base_price',        v_base,
      'total_amount',      v_total,
      'commission_amount', v_comm,
      'group_earnings',    GREATEST(v_total - v_comm, 0),
      'overtime_1h_price', p_overtime_1h,
      'overtime_2h_price', p_overtime_2h,
      'overtime_3h_price', p_overtime_3h,
      'notes',             p_notes,
      'arrival_time',      p_arrival_time,
      'start_time',        p_start_time,
      'member_dist',       p_member_dist
    )
  WHERE id = p_request_id;

  RETURN jsonb_build_object(
    'ok',             true,
    'group_id',       v_group.id,
    'request_id',     p_request_id,
    'total_amount',   v_total,
    'group_earnings', GREATEST(v_total - v_comm, 0)
  );

EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$$;

GRANT EXECUTE ON FUNCTION public.propose_event_request(
  UUID, NUMERIC, NUMERIC, NUMERIC, NUMERIC, NUMERIC, TEXT, JSONB, TEXT, TEXT
) TO authenticated;


SELECT '366_fix_express_window_15min.sql ejecutado ✅' AS status;
