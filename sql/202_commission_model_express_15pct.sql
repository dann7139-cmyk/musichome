-- ════════════════════════════════════════════════════════════════════
-- 202_commission_model_express_15pct.sql
--
-- MODELO DE COMISIONES DEFINITIVO:
--   Express:     15% añadido ENCIMA del precio del grupo
--                Cliente paga grupo_price × 1.15
--                Grupo recibe 100% de su precio (no ve comisión)
--
--   Programadas: 10% descontado DEL precio del grupo
--                Cliente paga precio base
--                Grupo recibe precio × 0.90 (ve el desglose)
--
-- CAMBIOS:
--   1. propose_event_request — total_amount = group_price × 1.15
--      group_earnings = group_price (lo que el grupo recibe)
--   2. client_accept_proposal — lee total_amount de proposal_data,
--      crea reserva con total_price = total_amount, group_earnings = group_price
-- ════════════════════════════════════════════════════════════════════


-- ── 1. propose_event_request con fee Express 15% ─────────────────────────────

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
  v_req            RECORD;
  v_group          RECORD;
  v_hours          INTEGER;
  v_base_price     NUMERIC;
  v_base_total     NUMERIC;
  v_multiplier     NUMERIC;
  v_group_total    NUMERIC;  -- lo que el grupo recibe (su precio + surge)
  v_client_total   NUMERIC;  -- lo que el cliente paga (group × 1.15)
  v_express_fee    NUMERIC;  -- fee de plataforma = group × 0.15
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

  -- ── Calcular precio base + multiplier de demanda ───────────────────���──────
  v_hours      := COALESCE(v_req.hours, 3);
  v_base_price := COALESCE(p_price_per_hour, 0) * v_hours;
  v_base_total := v_base_price + COALESCE(p_travel_cost, 0);

  v_multiplier  := COALESCE(v_req.demand_multiplier, 1.000);
  v_group_total := ROUND(v_base_total * v_multiplier);

  -- ── Express: el cliente paga group_total × 1.15 ──────────────────────────
  v_express_fee  := ROUND(v_group_total * 0.15);
  v_client_total := v_group_total + v_express_fee;

  -- ── Actualizar solicitud ──────────────────────────────────────────────────
  UPDATE public.event_requests
  SET
    status               = 'en_negociacion',
    negotiating_group_id = auth.uid(),
    proposal_data        = jsonb_build_object(
      'price_per_hour',    p_price_per_hour,
      'travel_cost',       COALESCE(p_travel_cost, 0),
      'base_price',        v_base_price,
      'base_total',        v_base_total,
      'demand_multiplier', v_multiplier,
      'group_price',       v_group_total,    -- lo que el grupo recibe
      'express_fee',       v_express_fee,    -- fee de plataforma (15%)
      'total_amount',      v_client_total,   -- lo que el cliente paga
      'group_earnings',    v_group_total,
      'overtime_1h_price', p_overtime_1h,
      'overtime_2h_price', p_overtime_2h,
      'overtime_3h_price', p_overtime_3h,
      'notes',             p_notes,
      'member_dist',       p_member_dist,
      'arrival_time',      p_arrival_time,
      'start_time',        p_start_time
    )
  WHERE id = p_request_id;

  -- ── Notificar al cliente ──────────────────────────────────────────────────
  INSERT INTO public.notifications (user_id, type, title, body, data)
  VALUES (
    v_req.client_id,
    'booking',
    '📋 ¡Recibiste una cotización!',
    '"' || v_group.name || '" quiere tocar en tu evento' ||
    CASE WHEN p_price_per_hour IS NOT NULL
      THEN '. Total: $' || TRUNC(v_client_total)::TEXT || ' MXN' ||
           CASE
             WHEN p_start_time   IS NOT NULL THEN '. Tocan a las ' || p_start_time || '.'
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
    'ok',              true,
    'group_name',      v_group.name,
    'group_id',        v_group.id,
    'group_total',     v_group_total,
    'client_total',    v_client_total
  );

EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$$;

GRANT EXECUTE ON FUNCTION public.propose_event_request(UUID, NUMERIC, NUMERIC, NUMERIC, NUMERIC, NUMERIC, TEXT, JSONB, TEXT, TEXT) TO authenticated;


-- ── 2. client_accept_proposal — lee total_amount del proposal_data ────────────

CREATE OR REPLACE FUNCTION public.client_accept_proposal(p_request_id UUID)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_req          RECORD;
  v_group        RECORD;
  v_client_total NUMERIC;  -- total que paga el cliente (group × 1.15)
  v_group_price  NUMERIC;  -- lo que recibe el grupo
  v_commission   NUMERIC;  -- platform_commission = client_total - group_price
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
  WHERE id = v_req.negotiating_group_id;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'group_not_found');
  END IF;

  v_hours := COALESCE(v_req.hours, 1);

  -- Leer precios calculados por propose_event_request (SQL 202)
  v_client_total := COALESCE(
    (v_req.proposal_data->>'total_amount')::NUMERIC,
    (v_req.proposal_data->>'group_price')::NUMERIC,   -- fallback v1
    (v_req.proposal_data->>'total')::NUMERIC,         -- fallback v0
    0
  );
  v_group_price := COALESCE(
    (v_req.proposal_data->>'group_price')::NUMERIC,
    (v_req.proposal_data->>'group_earnings')::NUMERIC,
    -- fallback: estimar group_price = client_total / 1.15
    ROUND(v_client_total / 1.15),
    0
  );
  v_commission := v_client_total - v_group_price;

  -- Crear reserva directamente en 'accepted' (grupo ya confirmó con su propuesta)
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
    event_request_id
  ) VALUES (
    v_group.id,
    v_req.client_id,
    v_req.event_date,
    COALESCE((v_req.proposal_data->>'start_time'), v_req.event_time, '20:00'),
    COALESCE(v_req.location_address, v_req.location_city, ''),
    v_client_total,   -- lo que se cobra al cliente vía Stripe
    v_group_price,    -- base_price = lo que el grupo recibe
    v_commission,     -- 15% del group_price
    v_group_price,    -- group_earnings = group_price (100% de su cotización)
    'accepted',
    v_hours,
    p_request_id
  )
  RETURNING id INTO v_res_id;

  UPDATE public.event_requests
  SET
    status                  = 'accepted',
    accepted_by_group_id    = v_group.id,
    accepted_reservation_id = v_res_id
  WHERE id = p_request_id;

  RETURN jsonb_build_object('ok', true, 'reservation_id', v_res_id);

EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$$;

GRANT EXECUTE ON FUNCTION public.client_accept_proposal(UUID) TO authenticated;


SELECT '202_commission_model_express_15pct.sql ejecutado ✅' AS status;
SELECT 'Express: cliente paga +15%, grupo recibe 100% de su precio' AS model_express;
SELECT 'Programadas: sin cambios, 10% visible descontado del grupo' AS model_programadas;
