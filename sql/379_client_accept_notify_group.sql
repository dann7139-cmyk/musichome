-- ════════════════════════════════════════════════════════════════════
-- sql/379_client_accept_notify_group.sql
--
-- PROBLEMA: client_accept_proposal no notifica al grupo cuando el cliente
--   acepta la propuesta. El grupo queda atrapado en la pantalla de "éxito"
--   de IncomingExpressScreen sin saber que hay un evento confirmado en
--   GroupEventsScreen.
--
-- FIX: Agregar INSERT a notifications para el owner del grupo justo
--   después de crear la reserva. El mensaje los dirige a "GroupEvents".
--
-- ÚNICO CAMBIO respecto a sql/378: una línea INSERT en notifications.
-- NO TOCA: pagos, wallets, Stripe, auth, webhooks, express RPCs críticas.
-- ════════════════════════════════════════════════════════════════════

BEGIN;

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
BEGIN
  SELECT * INTO v_req
  FROM public.event_requests
  WHERE id = p_request_id;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'request_not_found');
  END IF;

  IF v_req.client_id <> auth.uid() THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_owner');
  END IF;

  IF v_req.status <> 'en_negociacion' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_in_negotiation');
  END IF;

  IF v_req.negotiating_group_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'no_group');
  END IF;

  SELECT * INTO v_group
  FROM public.groups
  WHERE owner_id = v_req.negotiating_group_id
  LIMIT 1;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'group_not_found');
  END IF;

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
    break_type
  ) VALUES (
    v_group.id,
    v_req.client_id,
    v_req.event_date,
    COALESCE(
      (v_req.proposal_data->>'start_time')::TIME,
      v_req.event_time::TIME,
      '20:00'::TIME
    ),
    COALESCE(v_req.location_address, v_req.location_city, ''),
    v_client_total,
    v_group_price,
    v_commission,
    v_group_price,
    'accepted',
    v_hours,
    p_request_id,
    COALESCE(v_req.break_type, 'A')
  )
  RETURNING id INTO v_res_id;

  UPDATE public.event_requests
  SET
    status                  = 'accepted',
    accepted_by_group_id    = v_group.id,
    accepted_reservation_id = v_res_id
  WHERE id = p_request_id;

  -- Notificar al grupo que el cliente aceptó y está procesando el pago
  INSERT INTO public.notifications (user_id, type, title, body, data)
  VALUES (
    v_group.owner_id,
    'booking',
    '🎉 ¡Tu propuesta fue aceptada!',
    'El cliente confirmó. Revisa tus eventos — el pago está siendo procesado.',
    jsonb_build_object(
      'reservation_id', v_res_id,
      'screen',         'GroupEvents'
    )
  );

  RETURN jsonb_build_object('ok', true, 'reservation_id', v_res_id);

EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$$;

GRANT EXECUTE ON FUNCTION public.client_accept_proposal(UUID) TO authenticated;

COMMIT;

-- Verificación: la función debe tener la notificación al grupo
SELECT position('¡Tu propuesta fue aceptada!' IN pg_get_functiondef(oid)) > 0 AS notifica_al_grupo
FROM pg_proc
WHERE proname      = 'client_accept_proposal'
  AND pronamespace = 'public'::regnamespace;
