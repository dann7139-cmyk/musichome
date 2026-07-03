-- ════════════════════════════════════════════════════════════════════
-- sql/416_fix_client_accept_idempotent.sql
--
-- PROBLEMA:
--   client_accept_proposal hace INSERT sin verificar disponibilidad.
--   Si el grupo ya tiene una reserva para esa fecha (standard booking
--   o prueba previa), el trigger prevent_double_booking lanza excepción
--   → RPC devuelve { ok: false, error: 'El grupo ya tiene una reserva...' }
--   → UI muestra error y bloquea el pago del cliente.
--
-- FIX:
--   1. Idempotencia: si ya existe reserva para este event_request_id,
--      devolverla sin crear otra (handles double-tap / network retry).
--   2. Pre-check de disponibilidad: si el grupo tiene otro evento ese
--      día, devolver error 'group_unavailable' ANTES del INSERT
--      (evita que el trigger se active, error limpio).
-- ════════════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION public.client_accept_proposal(p_request_id UUID)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_req          RECORD;
  v_group        RECORD;
  v_client_total NUMERIC;
  v_group_price  NUMERIC;
  v_commission   NUMERIC;
  v_res_id       UUID;
  v_hours        INT;
  v_code         TEXT;
BEGIN
  -- Leer solicitud
  SELECT * INTO v_req
  FROM   public.event_requests
  WHERE  id = p_request_id;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'request_not_found');
  END IF;

  -- Solo el cliente dueño puede aceptar
  IF v_req.client_id <> auth.uid() THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_owner');
  END IF;

  -- ── 1. Idempotencia: reserva ya creada para esta solicitud ───────────────────
  -- Handles double-tap o network retry donde el INSERT llegó a DB pero
  -- la respuesta nunca llegó al cliente.
  SELECT id INTO v_res_id
  FROM   public.reservations
  WHERE  event_request_id = p_request_id
  LIMIT  1;

  IF FOUND THEN
    RETURN jsonb_build_object('ok', true, 'reservation_id', v_res_id, 'already_created', true);
  END IF;

  -- Debe estar en negociación para continuar
  IF v_req.status <> 'en_negociacion' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_in_negotiation');
  END IF;

  IF v_req.negotiating_group_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'no_group');
  END IF;

  -- FIX: negotiating_group_id = owner user_id → buscar por owner_id
  SELECT * INTO v_group
  FROM   public.groups
  WHERE  owner_id = v_req.negotiating_group_id
  LIMIT  1;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'group_not_found');
  END IF;

  -- ── 2. Pre-check de disponibilidad (evita el trigger prevent_double_booking) ─
  IF EXISTS (
    SELECT 1
    FROM   public.reservations
    WHERE  group_id   = v_group.id
      AND  event_date = v_req.event_date
      AND  status NOT IN ('cancelled', 'rejected', 'refunded', 'payment_failed')
  ) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'group_unavailable');
  END IF;

  -- Calcular montos desde proposal_data
  v_hours := COALESCE(v_req.hours, 1);

  v_client_total := COALESCE(
    (v_req.proposal_data->>'total_amount')::NUMERIC,
    (v_req.proposal_data->>'group_price')::NUMERIC,
    (v_req.proposal_data->>'total')::NUMERIC,
    0
  );
  v_group_price := COALESCE(
    (v_req.proposal_data->>'group_price')::NUMERIC,
    (v_req.proposal_data->>'group_earnings')::NUMERIC,
    ROUND(v_client_total / 1.15),
    0
  );
  v_commission := v_client_total - v_group_price;

  -- Generar arrival_code de 4 dígitos
  v_code := LPAD(FLOOR(RANDOM() * 10000)::TEXT, 4, '0');

  -- Crear reserva
  INSERT INTO public.reservations (
    group_id,
    client_id,
    event_date,
    event_time,
    address,
    total_price,
    base_price,
    platform_commission,
    group_earnings,
    status,
    hours_count,
    event_request_id,
    break_type,
    arrival_code
  ) VALUES (
    v_group.id,
    v_req.client_id,
    v_req.event_date,
    COALESCE((v_req.proposal_data->>'start_time'), v_req.event_time::TEXT, '20:00')::TIME,
    COALESCE(v_req.location_address, v_req.location_city, ''),
    v_client_total,
    v_group_price,
    v_commission,
    v_group_price,
    'accepted',
    v_hours,
    p_request_id,
    COALESCE(v_req.break_type, 'A'),
    v_code
  )
  RETURNING id INTO v_res_id;

  -- Marcar solicitud como aceptada
  UPDATE public.event_requests
  SET
    status                  = 'accepted',
    accepted_by_group_id    = v_group.id,
    accepted_reservation_id = v_res_id
  WHERE id = p_request_id;

  RETURN jsonb_build_object(
    'ok',             true,
    'reservation_id', v_res_id,
    'arrival_code',   v_code
  );

EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$$;

GRANT EXECUTE ON FUNCTION public.client_accept_proposal(UUID) TO authenticated;

SELECT '416_fix_client_accept_idempotent ✅' AS status;
