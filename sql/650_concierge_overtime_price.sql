-- ============================================================================
-- sql/650_concierge_overtime_price.sql
-- El admin, al poner el precio de una cotización en modo conserjería
-- (AdminManagedQuotesScreen), no tenía forma de capturar cuánto cobra el
-- grupo por hora extra — a diferencia del grupo respondiendo su propia
-- cotización (GroupQuoteDetailScreen), que sí lo pide. Sin ese dato,
-- ExtraHoursScreen cae en su fallback genérico (net/horas) en vez del
-- precio real que el admin negoció por teléfono.
--
-- admin_respond_quote ahora acepta un precio de hora extra NETO opcional
-- (un solo número — "¿cuánto cobras la hora extra?", como se pregunta
-- por teléfono) y replica los 3 paquetes (1h/2h/3h) que ExtraHoursScreen
-- ya sabe leer de quotes.overtime_1h_price/2h_price/3h_price — mismos
-- campos que usa el grupo cuando responde solo. Sin este dato, sigue
-- funcionando exactamente igual que antes (NULL, fallback de siempre).
--
-- Aplicado en producción vía DROP + CREATE (cambia la firma: se agrega
-- p_overtime_hour_price antes de p_notes) — sandbox-probado antes de
-- aplicar: con precio de hora extra da los 3 paquetes marcados con el
-- markup 20% correcto (500 → 600/1200/1800), sin precio deja todo NULL
-- igual que antes.
-- ============================================================================

DROP FUNCTION IF EXISTS public.admin_respond_quote(uuid, numeric, numeric, text);

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

  -- El markup 20% aplica sobre base+traslado combinados — mismo criterio que
  -- usa el grupo mismo al responder su propia cotización en
  -- GroupQuoteDetailScreen (calcClientPrice(base+travel), no solo base).
  v_group_total := p_base_price + COALESCE(p_travel_cost, 0);
  v_calc  := public.calculate_final_price(v_group_total);
  v_total := (v_calc->>'final_price')::numeric;

  -- Precio de hora extra (opcional) — un solo número neto ("¿cuánto cobras
  -- la hora extra?"), se replican los 3 paquetes 1h/2h/3h con el markup
  -- 20% aplicado, mismos campos que lee ExtraHoursScreen.
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
