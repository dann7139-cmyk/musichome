-- ════════════════════════════════════════════════════════════════════
-- 201_express_reservation_auto_accept.sql
--
-- PROBLEMA:
--   client_accept_proposal() crea la reserva en status='pending',
--   lo que requiere que el grupo la confirme antes de pagar.
--   Para solicitudes express el grupo YA envió cotización → quiere ir.
--
-- FIX:
--   Crear la reserva directamente en 'accepted' para que el cliente
--   pueda pagar sin esperar confirmación del grupo.
-- ════════════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION public.client_accept_proposal(p_request_id UUID)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_req     RECORD;
  v_group   RECORD;
  v_comm    NUMERIC;
  v_earnings NUMERIC;
  v_res_id  UUID;
  v_price   NUMERIC;
  v_hours   INT;
BEGIN
  -- Leer solicitud
  SELECT * INTO v_req
  FROM public.event_requests
  WHERE id = p_request_id;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'request_not_found');
  END IF;

  -- Solo el dueño del request puede aceptar
  IF v_req.client_id <> auth.uid() THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_owner');
  END IF;

  IF v_req.status <> 'en_negociacion' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_in_negotiation');
  END IF;

  IF v_req.negotiating_group_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'no_group');
  END IF;

  -- Leer datos del grupo
  SELECT * INTO v_group
  FROM public.groups
  WHERE id = v_req.negotiating_group_id;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'group_not_found');
  END IF;

  -- Precio y horas del proposal_data
  v_price := COALESCE((v_req.proposal_data->>'price')::NUMERIC, v_req.budget_max, 0);
  v_hours := COALESCE(v_req.hours, 1);

  -- Comisión (10%)
  v_comm    := ROUND(v_price * 0.10, 2);
  v_earnings := v_price - v_comm;

  -- Crear reserva directamente en 'accepted'
  -- El grupo ya mandó cotización = confirmó su disponibilidad
  INSERT INTO public.reservations (
    group_id,
    client_id,
    event_date,
    event_time,
    address,
    total_price,
    platform_commission,
    group_earnings,
    status,
    hours_count,
    event_request_id
  ) VALUES (
    v_group.id,
    v_req.client_id,
    v_req.event_date,
    COALESCE((v_req.proposal_data->>'start_time'), v_req.event_time, '20:00'),
    COALESCE(v_req.address, v_req.location_city, ''),
    v_price,
    v_comm,
    v_earnings,
    'accepted',   -- ← directo en accepted, sin esperar confirmación del grupo
    v_hours,
    p_request_id
  )
  RETURNING id INTO v_res_id;

  -- Marcar solicitud como aceptada
  UPDATE public.event_requests
  SET
    status                  = 'accepted',
    accepted_by_group_id    = v_group.id,
    accepted_reservation_id = v_res_id
  WHERE id = p_request_id;

  RETURN jsonb_build_object('ok', true, 'reservation_id', v_res_id);
END;
$$;

GRANT EXECUTE ON FUNCTION public.client_accept_proposal(UUID) TO authenticated;

SELECT '201_express_reservation_auto_accept.sql ejecutado ✅' AS status;
SELECT 'Reserva express ahora se crea en accepted → cliente puede pagar sin confirmación del grupo' AS fix;
