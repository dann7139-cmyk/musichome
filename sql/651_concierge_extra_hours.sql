-- ============================================================================
-- sql/651_concierge_extra_hours.sql
-- Hallazgo real hablando con el usuario: el precio de hora extra que el
-- admin captura en admin_respond_quote (sql/650) no servía de nada para
-- un grupo que nunca abre la app — proponer horas extra hoy es una acción
-- 100% del lado del grupo (ExtraHoursScreen, botón en EventTimerScreen).
-- Si el grupo nunca entra, nadie puede proponerle horas extra al cliente.
--
-- Mismo patrón que admin_respond_quote: el admin actúa en nombre del
-- grupo. Solo para grupos en modo conserjería (groups.concierge_mode) y
-- solo mientras el evento está en curso (reservations.status='in_progress'),
-- igual que ya exige el flujo normal del grupo.
--
-- admin_get_concierge_live_reservations — cola de eventos en curso de
-- grupos en conserjería, mismo filtro de país que las demás colas.
--
-- admin_propose_extra_hours — inserta en extra_hours exactamente igual
-- que el grupo lo haría desde ExtraHoursScreen (pago por saldo/plataforma,
-- nunca efectivo — el admin no está físicamente ahí para confirmar
-- efectivo recibido). El trigger existente trg_notify_extra_hour_proposed
-- ya se encarga de notificar al cliente (no hace falta duplicar esa
-- lógica aquí). Si no se manda un precio por hora, usa el que ya se
-- negoció en quotes.price_per_hour (sql/650) — si tampoco hay eso,
-- rechaza con error claro en vez de adivinar.
--
-- Sandbox-probado (6 casos T1-T6) antes de aplicar.
-- ============================================================================

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
        'reservation_id',   r.id,
        'group_id',         g.id,
        'group_name',       g.name,
        'group_phone',      po.phone,
        'client_name',      cp.full_name,
        'client_phone',     cp.phone,
        'event_date',       r.event_date,
        'hours_count',      r.hours_count,
        'event_started_at', r.event_started_at,
        'address',          r.address,
        'country',          COALESCE(g.country, 'México')
      ) AS item
    FROM reservations r
    JOIN groups g ON g.id = r.group_id
    LEFT JOIN profiles po ON po.id = g.owner_id
    LEFT JOIN profiles cp ON cp.id = r.client_id
    WHERE r.status = 'in_progress'
      AND g.concierge_mode = true
      AND (v_caller_role = 'admin' OR country_code_of(g.country) = admin_ops_country())
    ORDER BY r.event_started_at ASC NULLS LAST
    LIMIT p_limit
  ) x;

  RETURN v_result;
END;
$function$;

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

  -- Precio neto por hora: el que mande el admin ahora, o si no, el que ya
  -- se negoció al poner el precio inicial (quotes.price_per_hour, sql/650).
  v_hourly := p_price_per_hour;
  IF v_hourly IS NULL AND v_res.quote_id IS NOT NULL THEN
    SELECT q.price_per_hour INTO v_hourly FROM public.quotes q WHERE q.id = v_res.quote_id;
  END IF;
  IF v_hourly IS NULL OR v_hourly <= 0 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'missing_price');
  END IF;

  v_group_net := v_hourly * p_hours;
  v_calc := public.calculate_final_price(v_group_net);

  -- payment_method='balance' — nunca efectivo: el admin no está físicamente
  -- ahí para confirmar que el grupo recibió el dinero.
  INSERT INTO public.extra_hours (
    reservation_id, hours_added, price_per_hour, total_extra_cost,
    platform_commission, group_extra_earnings, status, is_cash_payment, payment_method
  ) VALUES (
    p_reservation_id, p_hours, v_hourly, (v_calc->>'final_price')::numeric,
    (v_calc->>'commission_amount')::numeric, v_group_net, 'pending', false, 'balance'
  ) RETURNING id INTO v_extra_id;
  -- trg_notify_extra_hour_proposed (ya existente) notifica al cliente.

  RETURN jsonb_build_object(
    'ok', true, 'extra_hour_id', v_extra_id,
    'total_extra_cost', (v_calc->>'final_price')::numeric, 'group_extra_earnings', v_group_net
  );
END;
$function$;
