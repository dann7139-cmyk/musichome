-- ============================================================================
-- sql/653_concierge_overtime_bundles.sql
-- Hallazgo real del usuario: "el grupo cuando llena cotización le aparece
-- como 3 para llenar horas extra... y eso no me aparece a mí". Confirmado
-- en GroupQuoteDetailScreen.tsx — el grupo llena 3 precios INDEPENDIENTES
-- (total por 1h extra, total por 2h extra, total por 3h extra), no una
-- tarifa por hora multiplicada — así puede dar descuento por quedarse más
-- tiempo (ej. 1h=$400, 2h=$750 en vez de $800, 3h=$1100 en vez de $1200).
--
-- sql/650/651/652 simplificaron esto a un solo "precio por hora" que se
-- multiplicaba — no representa lo que el grupo realmente cobra. Este
-- archivo corrige la firma de admin_respond_quote (3 campos independientes
-- en vez de 1) y de admin_propose_extra_hours (usa el paquete exacto para
-- el número de horas elegido, nunca una multiplicación), y quita el uso
-- de quotes.price_per_hour para esto (nunca fue el campo correcto — ese
-- campo es la tarifa de las horas CONTRATADAS, no de las extra).
--
-- Sandbox-probado (4 casos, incluyendo el caso de descuento por volumen
-- para probar que NO se multiplica) antes de aplicar. Re-probados también
-- los checks [33][34][39][40] existentes con la firma nueva.
-- ============================================================================

DROP FUNCTION IF EXISTS public.admin_respond_quote(uuid, numeric, numeric, numeric, text);

CREATE OR REPLACE FUNCTION public.admin_respond_quote(
  p_quote_id uuid,
  p_base_price numeric,
  p_travel_cost numeric DEFAULT 0,
  p_overtime_1h_price numeric DEFAULT NULL,
  p_overtime_2h_price numeric DEFAULT NULL,
  p_overtime_3h_price numeric DEFAULT NULL,
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

  -- El markup 20% aplica sobre base+traslado combinados — mismo criterio que
  -- usa el grupo mismo al responder su propia cotización en
  -- GroupQuoteDetailScreen (calcClientPrice(base+travel), no solo base).
  v_group_total := p_base_price + COALESCE(p_travel_cost, 0);
  v_calc  := public.calculate_final_price(v_group_total);
  v_total := (v_calc->>'final_price')::numeric;

  -- Precios de horas extra (opcionales) — CADA UNO es un total independiente
  -- que el grupo cobra por 1h/2h/3h extra EN TOTAL (no un precio por hora
  -- multiplicado — el grupo puede dar descuento por volumen), exactamente
  -- igual a como el grupo mismo los llena en GroupQuoteDetailScreen. Se
  -- marca cada uno con el 20% y se guarda en quotes.overtime_Xh_price
  -- (precio YA con el cliente), mismos campos que lee ExtraHoursScreen.
  IF p_overtime_1h_price IS NOT NULL AND p_overtime_1h_price > 0 THEN
    v_ot1 := (public.calculate_final_price(p_overtime_1h_price)->>'final_price')::numeric;
  END IF;
  IF p_overtime_2h_price IS NOT NULL AND p_overtime_2h_price > 0 THEN
    v_ot2 := (public.calculate_final_price(p_overtime_2h_price)->>'final_price')::numeric;
  END IF;
  IF p_overtime_3h_price IS NOT NULL AND p_overtime_3h_price > 0 THEN
    v_ot3 := (public.calculate_final_price(p_overtime_3h_price)->>'final_price')::numeric;
  END IF;

  UPDATE public.quotes SET
    status             = 'quoted',
    base_price         = p_base_price,
    travel_cost        = COALESCE(p_travel_cost, 0),
    commission_amount  = (v_calc->>'commission_amount')::numeric,
    commission_pct     = 20,
    total_amount       = v_total,
    group_earnings     = v_group_total,
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

DROP FUNCTION IF EXISTS public.admin_propose_extra_hours(uuid, numeric, numeric, text);

CREATE OR REPLACE FUNCTION public.admin_propose_extra_hours(
  p_reservation_id uuid,
  p_hours integer,
  p_bundle_price_net numeric DEFAULT NULL,
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
  v_quote       RECORD;
  v_client_total NUMERIC;
  v_group_net    NUMERIC;
  v_extra_id     UUID;
BEGIN
  SELECT role INTO v_caller_role FROM public.profiles WHERE id = auth.uid();
  IF v_caller_role NOT IN ('admin', 'admin_ops') THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_admin');
  END IF;

  IF p_hours IS NULL OR p_hours NOT IN (1, 2, 3) THEN
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

  -- Si el admin escribe un precio nuevo (neto, total por esas p_hours), se
  -- usa y se marca con el 20%. Si no, se usa el paquete YA negociado y
  -- guardado en quotes.overtime_Xh_price para ESE número exacto de horas
  -- (mismo campo/semántica que usa el grupo en su propio ExtraHoursScreen
  -- — "quoteOpts" — un total independiente por bundle, NUNCA un precio por
  -- hora multiplicado — el grupo puede dar descuento por volumen).
  IF p_bundle_price_net IS NOT NULL AND p_bundle_price_net > 0 THEN
    v_client_total := (public.calculate_final_price(p_bundle_price_net)->>'final_price')::numeric;
    v_group_net    := p_bundle_price_net;
  ELSE
    IF v_res.quote_id IS NOT NULL THEN
      SELECT * INTO v_quote FROM public.quotes WHERE id = v_res.quote_id;
      v_client_total := CASE p_hours
        WHEN 1 THEN v_quote.overtime_1h_price
        WHEN 2 THEN v_quote.overtime_2h_price
        WHEN 3 THEN v_quote.overtime_3h_price
      END;
    END IF;
    IF v_client_total IS NULL OR v_client_total <= 0 THEN
      RETURN jsonb_build_object('ok', false, 'error', 'missing_price');
    END IF;
    v_group_net := ROUND(v_client_total / 1.20);
  END IF;

  -- payment_method='balance' — nunca efectivo: el admin no está físicamente
  -- ahí para confirmar que el grupo recibió el dinero.
  INSERT INTO public.extra_hours (
    reservation_id, hours_added, price_per_hour, total_extra_cost,
    platform_commission, group_extra_earnings, status, is_cash_payment, payment_method
  ) VALUES (
    p_reservation_id, p_hours, ROUND(v_group_net / p_hours, 2), v_client_total,
    v_client_total - v_group_net, v_group_net, 'pending', false, 'balance'
  ) RETURNING id INTO v_extra_id;
  -- trg_notify_extra_hour_proposed (ya existente) notifica al cliente.

  RETURN jsonb_build_object(
    'ok', true, 'extra_hour_id', v_extra_id,
    'total_extra_cost', v_client_total, 'group_extra_earnings', v_group_net
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
        -- Netos ya negociados (se derivan del total ya guardado con el
        -- cliente — mismo criterio que Math.round(overtime_Xh_price/1.20)
        -- ya usado en GroupQuoteDetailScreen para re-editar una cotización).
        'negotiated_1h', CASE WHEN q.overtime_1h_price IS NOT NULL THEN ROUND(q.overtime_1h_price / 1.20) ELSE NULL END,
        'negotiated_2h', CASE WHEN q.overtime_2h_price IS NOT NULL THEN ROUND(q.overtime_2h_price / 1.20) ELSE NULL END,
        'negotiated_3h', CASE WHEN q.overtime_3h_price IS NOT NULL THEN ROUND(q.overtime_3h_price / 1.20) ELSE NULL END
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
