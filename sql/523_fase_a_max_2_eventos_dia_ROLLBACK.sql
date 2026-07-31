-- ============================================================
-- sql/523_fase_a_max_2_eventos_dia_ROLLBACK.sql
--
-- Restaura las 4 funciones EXACTAMENTE a como estaban en producción
-- antes de sql/523 (capturadas vía pg_get_functiondef contra
-- sqgzyipqpewzbnfrtdqk el 2026-07-23 y 2026-07-27, antes de aplicar el
-- parche) — es decir, reintroduce el candado legado
-- "date_taken"/"date_taken_legacy"/"group_unavailable" en las 4 capas.
-- Solo correr en caso de reversión deliberada de la Fase A completa.
--
-- NO se toca ninguna tabla, dato, trigger (definición) ni constraint —
-- mismo alcance de bajo riesgo que sql/523.
--
-- ⚠️ NUNCA se corre salvo emergencia deliberada (regla del proyecto para
-- archivos *_ROLLBACK).
-- ============================================================

BEGIN;

CREATE OR REPLACE FUNCTION public.enforce_group_availability()
RETURNS TRIGGER LANGUAGE plpgsql AS $function$
DECLARE
  v_entrando_ocupante BOOLEAN;
BEGIN
  IF NEW.group_id IS NULL OR NEW.event_date IS NULL THEN
    RETURN NEW;
  END IF;

  -- ¿Esta operación mete la fila al mundo "ocupante"?
  v_entrando_ocupante :=
    NEW.status = ANY (public.estados_que_ocupan())
    AND (TG_OP = 'INSERT'
         OR OLD.status IS DISTINCT FROM NEW.status
         OR OLD.event_date IS DISTINCT FROM NEW.event_date
         OR OLD.group_id  IS DISTINCT FROM NEW.group_id);

  IF NOT v_entrando_ocupante THEN
    RETURN NEW;   -- completar, cancelar, pagos, etc. pasan libres
  END IF;

  -- Carril único por grupo (serializa TODO el flujo de agenda)
  PERFORM pg_advisory_xact_lock(hashtext(NEW.group_id::text));

  -- (a) LEGADO intacto: bloqueo manual por día
  IF EXISTS (
    SELECT 1 FROM group_unavailability gu
    WHERE gu.group_id = NEW.group_id AND gu.date = NEW.event_date
  ) THEN
    RAISE EXCEPTION 'date_blocked';
  END IF;

  -- (b) LEGADO intacto: candado por día (lista vieja, se retira en F2)
  IF EXISTS (
    SELECT 1 FROM reservations r
    WHERE r.group_id = NEW.group_id
      AND r.event_date = NEW.event_date
      AND r.id <> NEW.id
      AND r.status IN ('pending','pending_payment','pending_group_confirmation',
                       'confirmed','in_progress')
  ) THEN
    RAISE EXCEPTION 'date_taken';
  END IF;

  -- (c) NUEVO [514]: límite diario de 2 (completed cuenta)
  IF public.count_events_local_day(NEW.group_id, NEW.event_date, NEW.id) >= 2 THEN
    RAISE EXCEPTION 'daily_event_limit';
  END IF;

  -- (d) NUEVO [514]: traslape de rangos (respaldo software del constraint)
  IF NEW.busy_range IS NOT NULL AND EXISTS (
    SELECT 1 FROM reservations r
    WHERE r.group_id = NEW.group_id
      AND r.id <> NEW.id
      AND r.status = ANY (public.estados_que_ocupan())
      AND r.busy_range && NEW.busy_range
  ) THEN
    RAISE EXCEPTION 'time_overlap';
  END IF;

  RETURN NEW;
END;
$function$;

CREATE OR REPLACE FUNCTION public.create_booking_with_event(
  p_client_id                   UUID,
  p_group_id                    UUID,
  p_package_id                  UUID,
  p_event_date                  DATE,
  p_event_time                  TIME,
  p_address                     TEXT,
  p_total_price                 NUMERIC,
  p_notes                       TEXT    DEFAULT NULL,
  p_break_type                  TEXT    DEFAULT NULL,
  p_base_price                  NUMERIC DEFAULT NULL,
  p_installment_plan            TEXT    DEFAULT NULL,
  p_installment_months          INT     DEFAULT NULL,
  p_installment_monthly_amount  NUMERIC DEFAULT NULL,
  p_payment_mode                TEXT    DEFAULT 'full'
)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $function$
DECLARE
  v_event_id       UUID;
  v_reservation_id UUID;
  v_flow_version   TEXT;
BEGIN
  -- [430] CANDADO DE DISPONIBILIDAD (día-nivel), a prueba de carreras:
  -- el lock serializa dos clientes reservando el mismo grupo+fecha a la vez.
  PERFORM pg_advisory_xact_lock(hashtext(p_group_id::text || p_event_date::text));

  IF EXISTS (
    SELECT 1 FROM group_unavailability
    WHERE group_id = p_group_id AND date = p_event_date
  ) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'date_blocked');
  END IF;

  IF EXISTS (
    SELECT 1 FROM reservations
    WHERE group_id   = p_group_id
      AND event_date = p_event_date
      AND status IN ('pending','pending_payment','pending_group_confirmation',
                     'confirmed','in_progress')
  ) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'date_taken');
  END IF;

  -- ── A partir de aquí: definición vigente sin cambios ──
  v_flow_version := CASE
    WHEN p_payment_mode = 'full' THEN 'full_payment_v2'
    ELSE 'legacy'
  END;
  INSERT INTO public.events (client_id, event_date, event_time, address, status)
  VALUES (p_client_id, p_event_date, p_event_time, p_address, 'active')
  RETURNING id INTO v_event_id;
  INSERT INTO public.reservations (
    event_id, group_id, package_id, client_id,
    event_date, event_time, address, notes, break_type,
    total_price, base_price, status,
    payment_mode, flow_version,
    installment_plan, installment_months, installment_monthly_amount
  )
  VALUES (
    v_event_id, p_group_id, p_package_id, p_client_id,
    p_event_date, p_event_time, p_address, p_notes, p_break_type,
    p_total_price, p_base_price, 'pending_payment',
    p_payment_mode, v_flow_version,
    p_installment_plan, p_installment_months, p_installment_monthly_amount
  )
  RETURNING id INTO v_reservation_id;
  RAISE NOTICE '[CREATE_BOOKING] reservation=% mode=% msi=%',
    v_reservation_id, p_payment_mode, COALESCE(p_installment_plan, '1_pago');
  RETURN jsonb_build_object(
    'reservation_id', v_reservation_id,
    'event_id',       v_event_id
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.can_schedule(
  p_group_id   UUID,
  p_event_date DATE,
  p_range      TSTZRANGE,
  p_exclude    UUID DEFAULT NULL
)
RETURNS TEXT LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $function$
BEGIN
  -- (a) Bloqueo manual del día
  IF EXISTS (
    SELECT 1 FROM group_unavailability gu
    WHERE gu.group_id = p_group_id AND gu.date = p_event_date
  ) THEN
    RETURN 'date_blocked';
  END IF;

  -- (b) LEGADO date_taken — intacto hasta F2.5 (mismos estados que sql/434)
  IF EXISTS (
    SELECT 1 FROM reservations r
    WHERE r.group_id = p_group_id
      AND r.event_date = p_event_date
      AND (p_exclude IS NULL OR r.id <> p_exclude)
      AND r.status IN ('pending','pending_payment','pending_group_confirmation',
                       'confirmed','in_progress')
  ) THEN
    RETURN 'date_taken_legacy';
  END IF;

  -- (c) Límite 2 eventos/día local (completed SÍ cuenta)
  IF public.count_events_local_day(p_group_id, p_event_date, p_exclude) >= 2 THEN
    RETURN 'daily_limit';
  END IF;

  -- (d) Traslape duro de rangos ocupantes
  IF p_range IS NOT NULL AND EXISTS (
    SELECT 1 FROM reservations r
    WHERE r.group_id = p_group_id
      AND (p_exclude IS NULL OR r.id <> p_exclude)
      AND r.status = ANY (public.estados_que_ocupan())
      AND r.busy_range IS NOT NULL
      AND r.busy_range && p_range
  ) THEN
    RETURN 'time_overlap';
  END IF;

  RETURN NULL;  -- disponible
END;
$function$;

CREATE OR REPLACE FUNCTION public.client_accept_proposal(p_request_id UUID)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $function$
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
$function$;

COMMIT;

SELECT '523_fase_a_max_2_eventos_dia_ROLLBACK ejecutado — candado legado date_taken restaurado en las 4 capas' AS status;
