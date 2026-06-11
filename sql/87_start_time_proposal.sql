-- 87_start_time_proposal.sql
-- Agrega "hora de inicio de tocada" a la propuesta del grupo.
-- Útil cuando el grupo necesita tiempo para instalar sonido:
--   arrival_time = hora en que llega el grupo a instalarse
--   start_time   = hora en que comienza la música
--
-- El cliente verá ambas horas en la cotización con mensaje explicativo.
-- Al crear la reserva, event_time usa start_time si se proporcionó,
-- pues es cuando arranca el temporizador del evento.
--
-- Ejecutar DESPUÉS de 86_clean_for_testing.sql / 85_notify_members_on_acceptance.sql
-- ════════════════════════════════════════════════════════════════════

-- ── 1. propose_event_request: agrega p_start_time ────────────────────────────
CREATE OR REPLACE FUNCTION public.propose_event_request(
  p_request_id     UUID,
  p_price_per_hour NUMERIC  DEFAULT NULL,
  p_travel_cost    NUMERIC  DEFAULT 0,
  p_overtime_1h    NUMERIC  DEFAULT NULL,
  p_overtime_2h    NUMERIC  DEFAULT NULL,
  p_overtime_3h    NUMERIC  DEFAULT NULL,
  p_notes          TEXT     DEFAULT NULL,
  p_member_dist    JSONB    DEFAULT NULL,
  p_arrival_time   TEXT     DEFAULT NULL,  -- 'HH:MM' hora de llegada a instalarse
  p_start_time     TEXT     DEFAULT NULL   -- 'HH:MM' hora de inicio de música (nuevo)
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

  IF v_group.genre <> v_req.genre THEN
    RETURN jsonb_build_object('ok', false, 'error', 'genre_mismatch');
  END IF;

  -- Calcular totales
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
      'member_dist',       p_member_dist,
      'arrival_time',      p_arrival_time,
      'start_time',        p_start_time    -- ← nueva clave
    )
  WHERE id = p_request_id;

  -- Notificar al cliente
  INSERT INTO public.notifications (user_id, type, title, body, data)
  VALUES (
    v_req.client_id,
    'booking',
    '📋 ¡Recibiste una cotización!',
    '"' || v_group.name || '" quiere tocar en tu evento' ||
    CASE WHEN p_price_per_hour IS NOT NULL
      THEN '. Total: $' || TRUNC(v_total)::TEXT || ' MXN' ||
           CASE
             WHEN p_start_time  IS NOT NULL THEN '. Tocan a las ' || p_start_time || '.'
             WHEN p_arrival_time IS NOT NULL THEN '. Llegan a las ' || p_arrival_time || '.'
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

GRANT EXECUTE ON FUNCTION public.propose_event_request(UUID, NUMERIC, NUMERIC, NUMERIC, NUMERIC, NUMERIC, TEXT, JSONB, TEXT, TEXT) TO authenticated;


-- ── 2. client_accept_proposal: usa start_time como event_time si existe ───────
--    El temporizador del evento debe arrancar en la hora de inicio de música,
--    no en la de llegada/instalación.
CREATE OR REPLACE FUNCTION public.client_accept_proposal(p_request_id UUID)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_req       RECORD;
  v_group     RECORD;
  v_res_id    UUID;
  v_total     NUMERIC;
  v_comm      NUMERIC;
  v_earnings  NUMERIC;
  v_address   TEXT;
  v_event_time TIME;
  v_member    RECORD;
BEGIN
  -- Bloquear la fila
  SELECT * INTO v_req
  FROM   public.event_requests
  WHERE  id        = p_request_id
    AND  client_id = auth.uid()
  FOR UPDATE;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_found');
  END IF;

  IF v_req.status <> 'en_negociacion' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_in_negotiation');
  END IF;

  SELECT * INTO v_group
  FROM   public.groups
  WHERE  owner_id = v_req.negotiating_group_id
  LIMIT  1;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'group_not_found');
  END IF;

  -- Montos del proposal_data
  v_total    := GREATEST(COALESCE((v_req.proposal_data->>'total_amount')::NUMERIC,    0), 0);
  v_comm     := GREATEST(COALESCE((v_req.proposal_data->>'commission_amount')::NUMERIC, 0), 0);
  v_earnings := GREATEST(COALESCE((v_req.proposal_data->>'group_earnings')::NUMERIC,   0), 0);

  -- Dirección: usar la completa si existe, si no usar ciudad + estado
  v_address := COALESCE(
    NULLIF(v_req.location_address, ''),
    v_req.location_city || ', ' || v_req.location_estado
  );

  -- event_time: usar start_time de proposal si existe, si no la del request
  v_event_time := CASE
    WHEN v_req.proposal_data->>'start_time' IS NOT NULL
      THEN (v_req.proposal_data->>'start_time')::TIME
    ELSE v_req.event_time::TIME
  END;

  -- Crear reserva en 'pending'
  INSERT INTO public.reservations (
    group_id,
    client_id,
    event_date,
    event_time,
    address,
    notes,
    total_price,
    platform_commission,
    group_earnings,
    status,
    hours_count,
    event_request_id
  )
  VALUES (
    v_group.id,
    v_req.client_id,
    v_req.event_date,
    v_event_time,
    v_address,
    v_req.proposal_data->>'notes',
    v_total,
    v_comm,
    v_earnings,
    'pending',
    v_req.hours,
    p_request_id
  )
  RETURNING id INTO v_res_id;

  -- Marcar la solicitud como aceptada
  UPDATE public.event_requests
  SET
    status                  = 'accepted',
    accepted_by_group_id    = v_group.id,
    accepted_reservation_id = v_res_id
  WHERE id = p_request_id;

  -- Notificar al dueño del grupo
  INSERT INTO public.notifications (user_id, type, title, body, data)
  VALUES (
    v_req.negotiating_group_id,
    'booking',
    '🎉 ¡El cliente aceptó tu propuesta!',
    'El evento del ' || TO_CHAR(v_req.event_date, 'DD/MM/YYYY') ||
    ' en ' || v_req.location_city ||
    ' está listo. Confírmalo para que el cliente pueda pagar.',
    jsonb_build_object(
      'request_id',     p_request_id,
      'reservation_id', v_res_id,
      'screen',         'GroupReservations'
    )
  );

  -- Notificar a integrantes del grupo
  FOR v_member IN
    SELECT ji.invited_user_id
    FROM   public.job_invitations ji
    WHERE  ji.group_id = v_group.id
      AND  ji.status   = 'accepted'
      AND  ji.invited_user_id <> v_req.negotiating_group_id
  LOOP
    INSERT INTO public.notifications (user_id, type, title, body, data)
    VALUES (
      v_member.invited_user_id,
      'booking',
      '🎉 ¡Toca confirmada!',
      'El cliente confirmó el evento del ' || TO_CHAR(v_req.event_date, 'DD/MM/YYYY') ||
      ' en ' || v_req.location_city || '. Ya pueden prepararse.',
      jsonb_build_object(
        'reservation_id', v_res_id,
        'screen',         'MemberEvents'
      )
    );
  END LOOP;

  RETURN jsonb_build_object(
    'ok',             true,
    'group_id',       v_group.id,
    'group_name',     v_group.name,
    'reservation_id', v_res_id
  );

EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$$;

GRANT EXECUTE ON FUNCTION public.client_accept_proposal(UUID) TO authenticated;

SELECT '87_start_time_proposal: start_time en propuesta y event_time de reserva ✅' AS status;
