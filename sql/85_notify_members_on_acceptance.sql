-- ════════════════════════════════════════════════════════════════════
-- 85_notify_members_on_acceptance.sql
-- Cuando el cliente acepta la propuesta express, se notifica a todos
-- los integrantes aceptados del grupo:
--   "🎉 ¡Toca confirmada! El cliente aceptó para el [fecha]."
-- Completa el ciclo: 84 notifica al proponer, 85 al confirmar.
-- ════════════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION public.client_accept_proposal(p_request_id UUID)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_req      RECORD;
  v_group    RECORD;
  v_res_id   UUID;
  v_total    NUMERIC;
  v_comm     NUMERIC;
  v_earnings NUMERIC;
  v_address  TEXT;
  v_member   RECORD;
BEGIN
  -- Bloquear la fila (evita race condition)
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

  -- Traer datos del grupo que propuso
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

  -- ── Crear reserva en 'pending' ─────────────────────────────────
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
    v_req.event_time::TIME,
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

  -- Marcar la solicitud como aceptada y enlazar la reserva creada
  UPDATE public.event_requests
  SET
    status                  = 'accepted',
    accepted_by_group_id    = v_group.id,
    accepted_reservation_id = v_res_id
  WHERE id = p_request_id;

  -- ── Notificar al dueño del grupo ───────────────────────────────
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

  -- ── Notificar a los integrantes del grupo ──────────────────────
  -- Todos los miembros aceptados (excepto el dueño, ya notificado)
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
      '¡El cliente aceptó! Evento el ' ||
      TO_CHAR(v_req.event_date, 'DD/MM/YYYY') ||
      CASE WHEN v_req.event_time IS NOT NULL
        THEN ' a las ' || LEFT(v_req.event_time::TEXT, 5)
        ELSE ''
      END ||
      ' en ' || COALESCE(v_req.location_city, 'tu ciudad') || '.',
      jsonb_build_object(
        'request_id',     p_request_id,
        'reservation_id', v_res_id,
        'group_id',       v_group.id,
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

SELECT '85_notify_members_on_acceptance: integrantes notificados al aceptar el cliente ✅' AS status;
