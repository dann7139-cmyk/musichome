-- ════════════════════════════════════════════════════════════════════
-- sql/351_propose_request_proximity_guard.sql
--
-- Agrega validación de proximidad a propose_event_request():
--   Si el evento es en < 2 horas, devuelve 'too_close_to_event'.
--   Cubre la ventana de riesgo en que el grupo tiene ProposeRequestScreen
--   abierta antes de que el cron marque la solicitud como expirada.
--
-- Insertar la validación DESPUÉS de la verificación de expires_at (línea 61
-- del 67_proposal_data.sql), manteniendo el resto de la función idéntico.
--
-- Ejecutar DESPUÉS de 350.
-- ════════════════════════════════════════════════════════════════════

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
  v_req   RECORD;
  v_group RECORD;
  v_hours INTEGER;
  v_base  NUMERIC;
  v_total NUMERIC;
  v_comm  NUMERIC;
BEGIN
  SELECT * INTO v_group
  FROM   public.groups
  WHERE  owner_id = auth.uid()
  LIMIT  1;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'no_group_found');
  END IF;

  -- Bloquear fila (evita race condition)
  SELECT * INTO v_req
  FROM   public.event_requests
  WHERE  id = p_request_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'request_not_found');
  END IF;

  IF v_req.status <> 'open' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_available');
  END IF;

  IF v_req.expires_at < NOW() THEN
    RETURN jsonb_build_object('ok', false, 'error', 'request_expired');
  END IF;

  -- ① Validación de PROXIMIDAD AL EVENTO (nuevo en 351)
  --   El cron (350) maneja la expiración automática, pero este guard cubre
  --   la ventana de riesgo en que el grupo abrió ProposeRequestScreen justo
  --   antes de que el cron corriera.
  IF (v_req.event_date::TIMESTAMP
      + COALESCE(v_req.event_time::INTERVAL, '0'::INTERVAL))
     < NOW() + INTERVAL '2 hours' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'too_close_to_event');
  END IF;

  IF v_group.genre <> v_req.genre THEN
    RETURN jsonb_build_object('ok', false, 'error', 'genre_mismatch');
  END IF;

  -- Calcular totales si se envió precio
  v_hours := COALESCE(v_req.hours, 3);
  v_base  := COALESCE(p_price_per_hour, 0) * v_hours;
  v_total := v_base + COALESCE(p_travel_cost, 0);
  v_comm  := v_hours * 150;  -- $150 MXN por hora de comisión

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
    'ok',            true,
    'group_id',      v_group.id,
    'request_id',    p_request_id,
    'total_amount',  v_total,
    'group_earnings', GREATEST(v_total - v_comm, 0)
  );

EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$$;

GRANT EXECUTE ON FUNCTION public.propose_event_request(
  UUID, NUMERIC, NUMERIC, NUMERIC, NUMERIC, NUMERIC, TEXT, JSONB, TEXT, TEXT
) TO authenticated;

SELECT '351_propose_request_proximity_guard.sql ejecutado ✅' AS status;
