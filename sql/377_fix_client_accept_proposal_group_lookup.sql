-- ════════════════════════════════════════════════════════════════════
-- sql/377_fix_client_accept_proposal_group_lookup.sql
--
-- BUG: client_accept_proposal (sql/364) busca el grupo con:
--        WHERE id = v_req.negotiating_group_id
--   pero negotiating_group_id almacena auth.uid() (el user ID del dueño),
--   no el group ID → groups.id ≠ user_id → group_not_found.
--
-- FIX: cambiar a WHERE owner_id = v_req.negotiating_group_id LIMIT 1
--   (igual que sql/87, la versión original que sí funcionaba).
--
-- ÚNICO CAMBIO: línea de SELECT del grupo. Todo lo demás idéntico a 364.
-- NO TOCA: pagos, wallets, Stripe, auth, webhooks.
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

  -- FIX: negotiating_group_id guarda el owner user_id → buscar por owner_id
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
    COALESCE((v_req.proposal_data->>'start_time'), v_req.event_time, '20:00'),
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

  RETURN jsonb_build_object('ok', true, 'reservation_id', v_res_id);

EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$$;

GRANT EXECUTE ON FUNCTION public.client_accept_proposal(UUID) TO authenticated;

COMMIT;

-- Verificación: la función debe buscar por owner_id (no por id)
SELECT position('WHERE owner_id = v_req.negotiating_group_id' IN pg_get_functiondef(oid)) > 0
  AS busca_por_owner_id
FROM pg_proc
WHERE proname      = 'client_accept_proposal'
  AND pronamespace = 'public'::regnamespace;
