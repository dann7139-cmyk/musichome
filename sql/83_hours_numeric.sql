-- ════════════════════════════════════════════════════════════════════
-- 83_hours_numeric.sql
-- Cambia hours / hours_count de INTEGER a NUMERIC para soportar
-- duraciones fraccionarias (ej: 0.25 = 15 min para pruebas).
-- ════════════════════════════════════════════════════════════════════

-- 1. event_requests.hours → NUMERIC, CHECK > 0 (no mínimo de 1)
ALTER TABLE public.event_requests
  ALTER COLUMN hours TYPE NUMERIC USING hours::NUMERIC;

ALTER TABLE public.event_requests
  DROP CONSTRAINT IF EXISTS event_requests_hours_check;

ALTER TABLE public.event_requests
  ADD CONSTRAINT event_requests_hours_check CHECK (hours > 0);

-- 2. reservations.hours_count → NUMERIC
ALTER TABLE public.reservations
  ALTER COLUMN hours_count TYPE NUMERIC USING hours_count::NUMERIC;

-- 3. Actualizar propose_event_request para usar NUMERIC en v_hours
--    (reemplaza la declaración INTEGER que truncaba 0.25 → 0)
CREATE OR REPLACE FUNCTION public.propose_event_request(
  p_request_id     UUID,
  p_price_per_hour NUMERIC  DEFAULT NULL,
  p_travel_cost    NUMERIC  DEFAULT 0,
  p_overtime_1h    NUMERIC  DEFAULT NULL,
  p_overtime_2h    NUMERIC  DEFAULT NULL,
  p_overtime_3h    NUMERIC  DEFAULT NULL,
  p_notes          TEXT     DEFAULT NULL,
  p_member_dist    JSONB    DEFAULT NULL,
  p_arrival_time   TEXT     DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_req   RECORD;
  v_group RECORD;
  v_hours NUMERIC;          -- ← era INTEGER, truncaba 0.25 a 0
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

  IF v_group.genre <> v_req.genre THEN
    RETURN jsonb_build_object('ok', false, 'error', 'genre_mismatch');
  END IF;

  v_hours := COALESCE(v_req.hours, 3);
  v_base  := COALESCE(p_price_per_hour, 0) * v_hours;
  v_total := v_base + COALESCE(p_travel_cost, 0);
  v_comm  := CEIL(v_hours) * 150;   -- comisión por hora completa

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
      'member_dist',       p_member_dist,
      'arrival_time',      p_arrival_time
    )
  WHERE id = p_request_id;

  INSERT INTO public.notifications (user_id, type, title, body, data)
  VALUES (
    v_req.client_id,
    'booking',
    '📋 ¡Recibiste una cotización!',
    '"' || v_group.name || '" quiere tocar en tu evento' ||
    CASE WHEN p_price_per_hour IS NOT NULL
      THEN '. Total: $' || TRUNC(v_total)::TEXT || ' MXN' ||
           CASE WHEN p_arrival_time IS NOT NULL
             THEN '. Llegan a las ' || p_arrival_time || '.'
             ELSE '. Toca para ver la propuesta.'
           END
      ELSE '. Revisa su propuesta y decide si lo contratas.'
    END,
    jsonb_build_object(
      'request_id', p_request_id,
      'group_id',   v_group.id,
      'screen',     'OpenRequest'
    )
  );

  RETURN jsonb_build_object(
    'ok',         true,
    'group_name', v_group.name,
    'group_id',   v_group.id,
    'total',      v_total
  );

EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$$;

GRANT EXECUTE ON FUNCTION public.propose_event_request(UUID, NUMERIC, NUMERIC, NUMERIC, NUMERIC, NUMERIC, TEXT, JSONB, TEXT) TO authenticated;

SELECT '83_hours_numeric: hours/hours_count → NUMERIC, propose actualizado ✅' AS status;
