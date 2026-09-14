-- ============================================================================
-- ROLLBACK sql/653_concierge_overtime_bundles.sql
-- Regresa a la versión de "un precio por hora multiplicado" (sql/650-652).
-- ⚠️ NO correr salvo emergencia deliberada — pierde la capacidad de dar
-- descuento por volumen en los paquetes de hora extra ya guardados
-- (las columnas overtime_Xh_price no se tocan, pero nada nuevo podrá
-- volver a escribirlas con esta granularidad).
-- ============================================================================

DROP FUNCTION IF EXISTS public.admin_respond_quote(uuid, numeric, numeric, numeric, numeric, numeric, text);

CREATE OR REPLACE FUNCTION public.admin_respond_quote(
  p_quote_id uuid,
  p_base_price numeric,
  p_travel_cost numeric DEFAULT 0,
  p_overtime_hour_price numeric DEFAULT NULL,
  p_notes text DEFAULT NULL::text
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_caller_role TEXT;
  v_quote       RECORD;
  v_group       RECORD;
  v_calc        JSONB;
  v_group_total NUMERIC;
  v_total       NUMERIC;
  v_ot1         NUMERIC;
  v_ot2         NUMERIC;
  v_ot3         NUMERIC;
  v_member_id   UUID;
BEGIN
  SELECT role INTO v_caller_role FROM public.profiles WHERE id = auth.uid();
  IF v_caller_role NOT IN ('admin', 'admin_ops') THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_admin');
  END IF;

  IF p_base_price IS NULL OR p_base_price <= 0 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_base_price');
  END IF;

  SELECT * INTO v_quote FROM public.quotes WHERE id = p_quote_id FOR UPDATE;
  IF NOT FOUND THEN RETURN jsonb_build_object('ok', false, 'error', 'quote_not_found'); END IF;
  IF v_quote.status <> 'pending' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'quote_not_pending', 'status', v_quote.status);
  END IF;

  SELECT id, owner_id, name, country, concierge_mode INTO v_group
  FROM public.groups WHERE id = v_quote.group_id;
  IF NOT FOUND THEN RETURN jsonb_build_object('ok', false, 'error', 'group_not_found'); END IF;

  IF NOT v_group.concierge_mode THEN
    RETURN jsonb_build_object('ok', false, 'error', 'group_not_in_concierge_mode');
  END IF;

  IF v_caller_role = 'admin_ops'
     AND public.country_code_of(v_group.country) <> public.admin_ops_country() THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_admin');
  END IF;

  v_group_total := p_base_price + COALESCE(p_travel_cost, 0);
  v_calc  := public.calculate_final_price(v_group_total);
  v_total := (v_calc->>'final_price')::numeric;

  IF p_overtime_hour_price IS NOT NULL AND p_overtime_hour_price > 0 THEN
    v_ot1 := (public.calculate_final_price(p_overtime_hour_price * 1)->>'final_price')::numeric;
    v_ot2 := (public.calculate_final_price(p_overtime_hour_price * 2)->>'final_price')::numeric;
    v_ot3 := (public.calculate_final_price(p_overtime_hour_price * 3)->>'final_price')::numeric;
  END IF;

  UPDATE public.quotes SET
    status             = 'quoted',
    base_price         = p_base_price,
    travel_cost        = COALESCE(p_travel_cost, 0),
    commission_amount  = (v_calc->>'commission_amount')::numeric,
    commission_pct     = 20,
    total_amount       = v_total,
    group_earnings     = v_group_total,
    price_per_hour     = CASE WHEN p_overtime_hour_price IS NOT NULL AND p_overtime_hour_price > 0
                               THEN p_overtime_hour_price ELSE price_per_hour END,
    overtime_1h_price  = COALESCE(v_ot1, overtime_1h_price),
    overtime_2h_price  = COALESCE(v_ot2, overtime_2h_price),
    overtime_3h_price  = COALESCE(v_ot3, overtime_3h_price),
    group_notes        = p_notes,
    updated_at         = NOW()
  WHERE id = p_quote_id;

  INSERT INTO public.notifications (user_id, type, title, body, data)
  VALUES (
    v_quote.client_id, 'quote_received',
    '📋 Recibiste una cotización',
    format('%s respondió tu solicitud. Total: $%s.', v_group.name, to_char(v_total, 'FM999,999,990.00')),
    jsonb_build_object('quote_id', p_quote_id)
  );

  FOR v_member_id IN
    SELECT ji.invited_user_id FROM public.job_invitations ji
    WHERE ji.group_id = v_group.id AND ji.invitation_type = 'membership' AND ji.status = 'accepted'
  LOOP
    INSERT INTO public.notifications (user_id, type, title, body, data)
    VALUES (v_member_id, 'quote_sent_to_client', '📋 Se envió una cotización',
      format('Se le envió una cotización de $%s al cliente.', to_char(v_total, 'FM999,999,990.00')),
      jsonb_build_object('quote_id', p_quote_id));
  END LOOP;

  RETURN jsonb_build_object('ok', true, 'total_amount', v_total, 'group_earnings', v_group_total);
END;
$function$;

DROP FUNCTION IF EXISTS public.admin_propose_extra_hours(uuid, integer, numeric, text);

CREATE OR REPLACE FUNCTION public.admin_propose_extra_hours(
  p_reservation_id uuid,
  p_hours numeric,
  p_price_per_hour numeric DEFAULT NULL,
  p_notes text DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_caller_role TEXT;
  v_res         RECORD;
  v_group       RECORD;
  v_hourly      NUMERIC;
  v_group_net   NUMERIC;
  v_calc        JSONB;
  v_extra_id    UUID;
BEGIN
  SELECT role INTO v_caller_role FROM public.profiles WHERE id = auth.uid();
  IF v_caller_role NOT IN ('admin', 'admin_ops') THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_admin');
  END IF;

  IF p_hours IS NULL OR p_hours <= 0 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_hours');
  END IF;

  SELECT * INTO v_res FROM public.reservations WHERE id = p_reservation_id FOR UPDATE;
  IF NOT FOUND THEN RETURN jsonb_build_object('ok', false, 'error', 'reservation_not_found'); END IF;
  IF v_res.status <> 'in_progress' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'event_not_in_progress', 'status', v_res.status);
  END IF;

  SELECT id, name, country, concierge_mode INTO v_group FROM public.groups WHERE id = v_res.group_id;
  IF NOT FOUND THEN RETURN jsonb_build_object('ok', false, 'error', 'group_not_found'); END IF;
  IF NOT v_group.concierge_mode THEN
    RETURN jsonb_build_object('ok', false, 'error', 'group_not_in_concierge_mode');
  END IF;

  IF v_caller_role = 'admin_ops'
     AND public.country_code_of(v_group.country) <> public.admin_ops_country() THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_admin');
  END IF;

  v_hourly := p_price_per_hour;
  IF v_hourly IS NULL AND v_res.quote_id IS NOT NULL THEN
    SELECT q.price_per_hour INTO v_hourly FROM public.quotes q WHERE q.id = v_res.quote_id;
  END IF;
  IF v_hourly IS NULL OR v_hourly <= 0 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'missing_price');
  END IF;

  v_group_net := v_hourly * p_hours;
  v_calc := public.calculate_final_price(v_group_net);

  INSERT INTO public.extra_hours (
    reservation_id, hours_added, price_per_hour, total_extra_cost,
    platform_commission, group_extra_earnings, status, is_cash_payment, payment_method
  ) VALUES (
    p_reservation_id, p_hours, v_hourly, (v_calc->>'final_price')::numeric,
    (v_calc->>'commission_amount')::numeric, v_group_net, 'pending', false, 'balance'
  ) RETURNING id INTO v_extra_id;

  RETURN jsonb_build_object(
    'ok', true, 'extra_hour_id', v_extra_id,
    'total_extra_cost', (v_calc->>'final_price')::numeric, 'group_extra_earnings', v_group_net
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.admin_get_concierge_live_reservations(p_limit integer DEFAULT 50)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_caller_role TEXT;
  v_result      JSONB;
BEGIN
  SELECT role INTO v_caller_role FROM profiles WHERE id = auth.uid();
  IF v_caller_role NOT IN ('admin', 'admin_ops') THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_admin');
  END IF;

  SELECT jsonb_build_object(
    'ok', true,
    'items', COALESCE(jsonb_agg(x.item ORDER BY x.event_started_at ASC NULLS LAST), '[]'::jsonb)
  )
  INTO v_result
  FROM (
    SELECT
      r.event_started_at,
      jsonb_build_object(
        'reservation_id',      r.id,
        'group_id',            g.id,
        'group_name',          g.name,
        'group_phone',         po.phone,
        'client_name',         cp.full_name,
        'client_phone',        cp.phone,
        'event_date',          r.event_date,
        'hours_count',         r.hours_count,
        'event_started_at',    r.event_started_at,
        'address',             r.address,
        'country',             COALESCE(g.country, 'México'),
        'negotiated_hourly',   q.price_per_hour
      ) AS item
    FROM reservations r
    JOIN groups g ON g.id = r.group_id
    LEFT JOIN profiles po ON po.id = g.owner_id
    LEFT JOIN profiles cp ON cp.id = r.client_id
    LEFT JOIN quotes q ON q.id = r.quote_id
    WHERE r.status = 'in_progress'
      AND g.concierge_mode = true
      AND (v_caller_role = 'admin' OR country_code_of(g.country) = admin_ops_country())
    ORDER BY r.event_started_at ASC NULLS LAST
    LIMIT p_limit
  ) x;

  RETURN v_result;
END;
$function$;
