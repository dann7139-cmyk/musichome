-- ============================================================
-- sql/523_fase_a_max_2_eventos_dia.sql — Fase A: máximo 2 eventos/día
--
-- PROBLEMA: el candado legado "date_taken" (bloquea CUALQUIER 2ª reserva
-- ocupante el mismo día para un grupo, sin importar si el horario
-- traslapa) estaba duplicado en 4 capas de backend independientes:
--   1. Trigger    enforce_group_availability()
--   2. RPC        create_booking_with_event()  (sql/430)
--   3. Función    can_schedule()  (usada por confirm_reservation_payment_v2,
--                 gate de pagos F2.2, rama D6 — validación preventiva en
--                 casi todo pago confirmado)
--   4. RPC        client_accept_proposal()  (creación de reserva al aceptar
--                 una cotización/propuesta) — encontrada en revisión de
--                 solo lectura del 2026-07-27, buscando lógica EQUIVALENTE
--                 y no solo el texto literal "date_taken": su propio
--                 comentario decía "evita el trigger prevent_double_booking"
--                 (nombre de trigger que ya ni existe con ese nombre hoy) y
--                 usaba una lista de estados excluidos DISTINTA y más
--                 amplia (`status NOT IN ('cancelled','rejected','refunded',
--                 'payment_failed')`) que estados_que_ocupan() — una 3ª
--                 fuente de verdad divergente sobre qué estados "ocupan".
--
-- Las 3 primeras lo tenían marcado en sus propios comentarios como legado a
-- retirar ("se retira en F2" / "intacto hasta F2.5") — nunca se había
-- hecho hasta este archivo. La 4ª (client_accept_proposal) no tenía ni
-- siquiera esa marca, por eso una búsqueda solo por el texto "date_taken"
-- no la habría encontrado.
--
-- NOTA sobre client_accept_proposal(): a diferencia de las otras 3, aquí
-- basta con ELIMINAR su pre-check propio, sin reemplazarlo por nada — su
-- INSERT INTO reservations de todos modos dispara el trigger
-- trg_02_enforce_group_availability (los triggers de Postgres corren sin
-- importar qué función hizo el INSERT), que con este mismo archivo ya
-- aplicado válida correctamente date_blocked/daily_event_limit/time_overlap
-- de forma automática. No se duplica esa lógica aquí.
--
-- ⚠️ DECLARACIÓN DE FUENTE DE VERDAD (leer antes de tocar disponibilidad
-- de nuevo — evitar reintroducir el candado legado):
--
--   A partir de este archivo, la disponibilidad de un grupo para un
--   evento SOLO se decide por estas 3 señales, y NINGUNA OTRA:
--
--     • date_blocked      → bloqueo manual del dueño (group_unavailability)
--     • daily_event_limit → máximo 2 eventos/día por grupo, contando
--                            'completed' (count_events_local_day() /
--                            estados_que_cuentan_limite())
--     • time_overlap      → traslape real de busy_range (rango calculado
--                            por make_busy_range(): evento + buffers de
--                            30 min antes / 45 min después + horas extra
--                            aceptadas/pagadas), respaldado a nivel de
--                            motor por el constraint excl_group_busy_range
--                            (EXCLUDE USING gist sobre group_id+busy_range)
--
--   Lo que NO debe volver a existir: un chequeo tipo "¿ya hay CUALQUIER
--   reserva de este grupo ese event_date?" sin comparar horarios. Eso es
--   exactamente el candado que este archivo retira. Si en el futuro hace
--   falta un límite adicional, debe expresarse en términos de
--   daily_event_limit (cambiar el 2) o de busy_range (cambiar los
--   buffers/duración) — nunca reintroduciendo una comparación de
--   "mismo event_date" a secas.
--
-- QUÉ CAMBIA: 4× CREATE OR REPLACE FUNCTION, mismo nombre y firma que
-- hoy en producción. No se tocan tablas, triggers (definición del
-- trigger en sí), constraints, ni ninguna otra función. No se toca
-- código de frontend (Fase B, fuera de este archivo). No se toca lógica
-- de pagos/webhooks/wallets — can_schedule() se edita como función de
-- disponibilidad compartida, pero confirm_reservation_payment_v2 sigue
-- llamándola exactamente igual, con la misma firma y el mismo contrato
-- de retorno (NULL = disponible, o el código de rechazo). El resto de
-- client_accept_proposal() (idempotencia, cálculo de montos, arrival_code,
-- actualización de event_requests) queda intacto, solo se quita su bloque
-- de pre-check.
--
-- FUERA DE ALCANCE, documentado como deuda técnica aparte (no tocado aquí
-- a petición explícita): create_booking_with_event() referencia una
-- columna reservations.package_id que ya no existe en el esquema (la
-- tabla de packages fue erradicada). Es un hallazgo independiente de este
-- parche, no introducido ni corregido por sql/523.
--
-- Rollback: sql/523_fase_a_max_2_eventos_dia_ROLLBACK.sql — restaura las
-- 4 funciones byte-idénticas a como estaban antes de este archivo
-- (capturadas vía pg_get_functiondef en producción antes de este cambio).
--
-- EN REVISIÓN — no ejecutado.
-- ============================================================

BEGIN;

-- ── 1. Trigger de disponibilidad en reservations ──────────────
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

  -- (a) Bloqueo manual del día — ÚNICA fuente de verdad #1
  IF EXISTS (
    SELECT 1 FROM group_unavailability gu
    WHERE gu.group_id = NEW.group_id AND gu.date = NEW.event_date
  ) THEN
    RAISE EXCEPTION 'date_blocked';
  END IF;

  -- [523] Candado legado "date_taken" (bloqueaba CUALQUIER 2ª reserva el
  -- mismo día, sin comparar horario) REMOVIDO aquí — ver header de
  -- sql/523_fase_a_max_2_eventos_dia.sql. NO reintroducir.

  -- (b) Límite diario de 2 eventos, completed cuenta — ÚNICA fuente de verdad #2
  IF public.count_events_local_day(NEW.group_id, NEW.event_date, NEW.id) >= 2 THEN
    RAISE EXCEPTION 'daily_event_limit';
  END IF;

  -- (c) Traslape real de busy_range (respaldo software del constraint
  --     excl_group_busy_range) — ÚNICA fuente de verdad #3
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

-- ── 2. RPC de creación de reserva (sql/430) ────────────────────
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

  -- Bloqueo manual del día — ÚNICA fuente de verdad #1 (ver sql/523)
  IF EXISTS (
    SELECT 1 FROM group_unavailability
    WHERE group_id = p_group_id AND date = p_event_date
  ) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'date_blocked');
  END IF;

  -- [523] Candado legado "date_taken" (bloqueaba CUALQUIER 2ª reserva el
  -- mismo día, sin comparar horario) REMOVIDO aquí — ver header de
  -- sql/523_fase_a_max_2_eventos_dia.sql. NO reintroducir.
  --
  -- El límite de 2/día (ÚNICA fuente de verdad #2) y el traslape real de
  -- busy_range (ÚNICA fuente de verdad #3) se validan más abajo, en el
  -- INSERT de reservations, vía el trigger trg_02_enforce_group_availability
  -- → enforce_group_availability(). No se duplican aquí para no tener dos
  -- fuentes de la misma verdad divergiendo con el tiempo.

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

-- ── 3. Función compartida de disponibilidad (usada por el gate F2.2) ──
CREATE OR REPLACE FUNCTION public.can_schedule(
  p_group_id   UUID,
  p_event_date DATE,
  p_range      TSTZRANGE,
  p_exclude    UUID DEFAULT NULL
)
RETURNS TEXT LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $function$
BEGIN
  -- (a) Bloqueo manual del día — ÚNICA fuente de verdad #1
  IF EXISTS (
    SELECT 1 FROM group_unavailability gu
    WHERE gu.group_id = p_group_id AND gu.date = p_event_date
  ) THEN
    RETURN 'date_blocked';
  END IF;

  -- [523] Candado legado "date_taken_legacy" (bloqueaba CUALQUIER 2ª
  -- reserva el mismo día, sin comparar horario) REMOVIDO aquí — ver
  -- header de sql/523_fase_a_max_2_eventos_dia.sql. NO reintroducir.
  --
  -- Esta función es llamada por confirm_reservation_payment_v2 (gate de
  -- pagos F2.2) en la validación preventiva de disponibilidad al
  -- confirmar un pago — antes de este cambio, un 2º evento legítimo sin
  -- traslape hubiera bloqueado su pago y disparado un reembolso íntegro
  -- automático (payment_blocked_refund_pending) sin necesidad real.

  -- (b) Límite 2 eventos/día local (completed cuenta) — ÚNICA fuente de verdad #2
  IF public.count_events_local_day(p_group_id, p_event_date, p_exclude) >= 2 THEN
    RETURN 'daily_limit';
  END IF;

  -- (c) Traslape duro de rangos ocupantes — ÚNICA fuente de verdad #3
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

-- ── 4. RPC de aceptación de propuesta/cotización ───────────────
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

  -- [523] Candado legado "group_unavailable" (bloqueaba CUALQUIER 2ª
  -- reserva el mismo día, sin comparar horario, con su propia lista de
  -- estados divergente de estados_que_ocupan()) REMOVIDO aquí — ver
  -- header de sql/523_fase_a_max_2_eventos_dia.sql. NO reintroducir.
  --
  -- El INSERT INTO reservations de abajo dispara el trigger
  -- trg_02_enforce_group_availability → enforce_group_availability(),
  -- que ya valida date_blocked/daily_event_limit/time_overlap
  -- automáticamente. No se duplica esa lógica aquí.

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

-- ── VERIFICACIÓN ──────────────────────────────────────────────────
-- Esperado: las 4 funciones YA NO contienen 'date_taken' ni
-- 'group_unavailable' (el equivalente de client_accept_proposal).
SELECT
  proname,
  (pg_get_functiondef(oid) ILIKE '%date_taken%')          AS todavia_tiene_date_taken,
  (pg_get_functiondef(oid) ILIKE '%group_unavailable%')   AS todavia_tiene_group_unavailable
FROM pg_proc
WHERE pronamespace = 'public'::regnamespace
  AND proname IN ('enforce_group_availability','create_booking_with_event',
                   'can_schedule','client_accept_proposal')
ORDER BY proname;
-- Esperado: las 4 filas con ambas columnas = false.

-- date_blocked/daily_*/time_overlap solo aplican a las 3 funciones que
-- las implementan directamente (client_accept_proposal las hereda del
-- trigger, no las repite en su propio código):
SELECT
  proname,
  (pg_get_functiondef(oid) ILIKE '%date_blocked%')        AS tiene_date_blocked,
  (pg_get_functiondef(oid) ILIKE '%daily_event_limit%'
     OR pg_get_functiondef(oid) ILIKE '%daily_limit%')    AS tiene_daily_limit,
  (pg_get_functiondef(oid) ILIKE '%time_overlap%')        AS tiene_time_overlap
FROM pg_proc
WHERE pronamespace = 'public'::regnamespace
  AND proname IN ('enforce_group_availability','can_schedule')
ORDER BY proname;
-- Esperado: ambas filas con las 3 columnas = true.

SELECT '523_fase_a_max_2_eventos_dia ejecutado ✅ — date_taken legado retirado de las 4 capas' AS status;
