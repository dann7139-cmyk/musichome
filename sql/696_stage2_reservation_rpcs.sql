-- ═══════════════════════════════════════════════════════════════════════════
-- 696 — ETAPA 2 (a): RPCs que sustituyen las escrituras directas del cliente y
--       del proveedor sobre `reservations`
-- ═══════════════════════════════════════════════════════════════════════════
-- ADITIVA Y SEGURA DE APLICAR SOLA: solo crea funciones nuevas. No revoca
-- permisos, no toca policies ni RLS, no altera tablas, no cambia ninguna
-- función existente, y no modifica lógica financiera (no calcula precios, no
-- toca comisiones, wallets, payouts ni reembolsos).
--
-- Aplicar ESTA migración antes de `697` es a propósito: el REVOKE de 697 solo
-- puede correr cuando la app publicada ya use estas RPCs.
--
-- ── POR QUÉ NO SE EXTENDIÓ create_booking_with_event ───────────────────────
-- El usuario pidió "extenderla de la forma mínima necesaria". Al revisarla se
-- decidió NO tocarla, por dos razones concretas:
--   1. Añadirle parámetros cambia su firma → en este proyecto eso crea un
--      OVERLOAD (la lección de sql/585, donde un overload rompió reservas). La
--      alternativa sería DROP + CREATE, que obliga a reescribir sus 3 000
--      caracteres de lógica de precio (`v_final_total`), y eso es exactamente
--      lo que esta etapa NO debe tocar.
--   2. El objetivo de seguridad se cumple igual con una RPC aparte y diminuta.
-- Se documenta aquí para que quede explícito que fue una decisión, no un olvido.
--
-- ── LA MONEDA: regla existente, sin ampliar monedas ────────────────────────
-- Hoy `create_booking_with_event` NO escribe `currency_code`: la columna cae a
-- su DEFAULT 'MXN'. La única cosa que pone USD es el UPDATE directo que hace
-- BookingScreen con `currencyForCountry(eventCountry)`, cuya regla real es, en
-- `src/utils/logistics.ts:108`:  country === 'US' ? 'USD' : 'MXN'.
-- Esa MISMA regla se replica aquí literalmente. NO se usa
-- `countries.code → currency_code` porque ahí 'CA' = CAD, y CAD violaría
-- `reservations_currency_code_check` (∈ {MXN, USD}). Es decir: usar la tabla
-- cambiaría el comportamiento e introduciría un fallo nuevo. Se conservan
-- exactamente las monedas soportadas hoy. El hueco de CAD queda REPORTADO,
-- no resuelto: es una decisión aparte.
-- `p_event_country` se acepta solo con los dos valores que el selector de
-- BookingScreen puede producir ('MX' / 'US'); cualquier otro se rechaza en vez
-- de guardarse en silencio.
-- ═══════════════════════════════════════════════════════════════════════════

BEGIN;

-- ═══════════════════════════════════════════════════════════════════════════
-- 1. client_set_booking_location — sustituye el UPDATE directo de
--    BookingScreen.tsx:397 (event_country, event_city, currency_code)
-- ═══════════════════════════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION public.client_set_booking_location(
  p_reservation_id UUID,
  p_event_country  TEXT,
  p_event_city     TEXT DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_uid      UUID;
  v_res      RECORD;
  v_country  TEXT;
  v_city     TEXT;
  v_currency TEXT;
BEGIN
  v_uid := auth.uid();
  IF v_uid IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_authenticated');
  END IF;

  SELECT * INTO v_res FROM public.reservations WHERE id = p_reservation_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_found');
  END IF;
  -- Dueño SIEMPRE por auth.uid(), nunca por parámetro.
  IF v_res.client_id IS DISTINCT FROM v_uid THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_owner');
  END IF;

  -- Solo sobre una reserva RECIÉN creada y sin dinero encima. Así esta RPC no
  -- puede usarse para cambiarle la moneda a algo ya cobrado.
  IF v_res.status <> 'pending_payment' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'wrong_status', 'status', v_res.status);
  END IF;
  IF COALESCE(v_res.payment_status, 'unpaid') NOT IN ('unpaid', 'pending', 'pending_payment') THEN
    RETURN jsonb_build_object('ok', false, 'error', 'already_paid', 'payment_status', v_res.payment_status);
  END IF;

  v_country := NULLIF(UPPER(TRIM(COALESCE(p_event_country, ''))), '');
  v_city    := NULLIF(TRIM(COALESCE(p_event_city, '')), '');

  IF v_country IS NULL OR v_country NOT IN ('MX', 'US') THEN
    RETURN jsonb_build_object('ok', false, 'error', 'unsupported_country', 'country', v_country);
  END IF;

  -- La regla del servidor. El cliente manda el PAÍS (dato de producto, un
  -- selector de dos opciones), nunca la moneda.
  v_currency := CASE WHEN v_country = 'US' THEN 'USD' ELSE 'MXN' END;

  UPDATE public.reservations SET
    event_country = v_country,
    event_city    = v_city,
    currency_code = v_currency
  WHERE id = p_reservation_id;

  RETURN jsonb_build_object('ok', true, 'event_country', v_country,
                            'event_city', v_city, 'currency_code', v_currency);
END;
$function$;

REVOKE EXECUTE ON FUNCTION public.client_set_booking_location(UUID, TEXT, TEXT) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.client_set_booking_location(UUID, TEXT, TEXT) TO authenticated, service_role;
COMMENT ON FUNCTION public.client_set_booking_location(UUID, TEXT, TEXT) IS
  'sql/696 (Etapa 2) — guarda pais/ciudad del evento y DERIVA la moneda en el servidor con la regla existente (US -> USD, resto -> MXN). Sustituye el UPDATE directo de BookingScreen. Solo sobre reserva propia en pending_payment y sin pago. No amplia monedas: CAD sigue fuera a proposito.';

-- ═══════════════════════════════════════════════════════════════════════════
-- 2. client_reschedule_reservation — sustituye el UPDATE directo de
--    ReservationsScreen.tsx:928 (event_date)
-- ═══════════════════════════════════════════════════════════════════════════
-- Reproduce la regla de producto ACTUAL (`canReschedule` de la pantalla):
-- status IN ('confirmed','accepted'), pagado, y más de 24 h para el evento.
-- Cambia SOLO cómo se valida, no qué se permite.
--
-- Dos diferencias respecto a la pantalla, ambas a favor de la corrección y
-- documentadas a propósito:
--   · La disponibilidad se comprueba con `can_schedule()` (la infraestructura
--     real: group_unavailability + límite de 2/día + solape de busy_range con
--     exclusión de la propia reserva) en vez de la comparación de ±2 horas en
--     JS, que contradecía al servidor y de todos modos el trigger rechazaba.
--   · Las 24 h se miden desde el inicio REAL del evento en SU zona
--     (`event_tz`), no desde la medianoche local del teléfono.
--
-- NO persiste "ya se reprogramó una vez": hoy esa regla vive ÚNICAMENTE en
-- estado de React (`hasBeenRescheduled`, que vuelve a false al reabrir la app)
-- y no existe ninguna columna que lo registre. Inventar una columna sería un
-- cambio de producto, así que queda REPORTADO y la UI sigue como está.
--
-- NO introduce aprobación del proveedor (eso es la Fase 4 que el usuario dejó
-- explícitamente fuera). Las notificaciones siguen donde están: en la pantalla.
CREATE OR REPLACE FUNCTION public.client_reschedule_reservation(
  p_reservation_id UUID,
  p_new_date       DATE
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_uid     UUID;
  v_res     RECORD;
  v_tz      TEXT;
  v_inicio  TIMESTAMPTZ;
  v_rango   tstzrange;
  v_extras  INT;
  v_motivo  TEXT;
BEGIN
  v_uid := auth.uid();
  IF v_uid IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_authenticated');
  END IF;
  IF p_new_date IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'missing_date');
  END IF;

  SELECT * INTO v_res FROM public.reservations WHERE id = p_reservation_id FOR UPDATE;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_found');
  END IF;
  IF v_res.client_id IS DISTINCT FROM v_uid THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_owner');
  END IF;

  -- Mismas condiciones que hoy habilitan el botón en la app
  IF v_res.status NOT IN ('confirmed', 'accepted') THEN
    RETURN jsonb_build_object('ok', false, 'error', 'wrong_status', 'status', v_res.status);
  END IF;
  IF COALESCE(v_res.payment_status, '') NOT IN ('paid', 'deposit_paid', 'fully_paid') THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_paid', 'payment_status', v_res.payment_status);
  END IF;

  v_tz := COALESCE(v_res.event_tz, public.tz_for_event(
            (SELECT g.state FROM public.groups g WHERE g.id = v_res.group_id),
            (SELECT g.country FROM public.groups g WHERE g.id = v_res.group_id)));

  v_inicio := (v_res.event_date + COALESCE(v_res.event_time, TIME '00:00')) AT TIME ZONE v_tz;
  IF v_inicio <= NOW() + INTERVAL '24 hours' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'too_late');
  END IF;

  IF p_new_date = v_res.event_date THEN
    RETURN jsonb_build_object('ok', false, 'error', 'same_date');
  END IF;
  -- La fecha nueva también tiene que estar a más de 24 h.
  IF ((p_new_date + COALESCE(v_res.event_time, TIME '00:00')) AT TIME ZONE v_tz)
       <= NOW() + INTERVAL '24 hours' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'new_date_too_soon');
  END IF;

  -- Disponibilidad real del proveedor con la infraestructura existente.
  SELECT COALESCE(SUM(eh.hours_added), 0)::INT INTO v_extras
  FROM public.extra_hours eh
  WHERE eh.reservation_id = v_res.id AND eh.status IN ('accepted', 'paid');

  v_rango := public.make_busy_range(p_new_date, v_res.event_time, v_tz, v_res.hours_count, v_extras);

  PERFORM pg_advisory_xact_lock(hashtext(v_res.group_id::text));
  -- p_exclude = esta reserva: no debe chocar consigo misma.
  v_motivo := public.can_schedule(v_res.group_id, p_new_date, v_rango, v_res.id);
  IF v_motivo IS NOT NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', v_motivo);
  END IF;

  -- Solo la fecha. `busy_range` y `event_tz` los recalcula
  -- trg_01_set_busy_range, y trg_02_enforce_group_availability revalida porque
  -- event_date cambia: no se duplica esa lógica aquí.
  UPDATE public.reservations SET event_date = p_new_date WHERE id = p_reservation_id;

  RETURN jsonb_build_object('ok', true, 'event_date', p_new_date, 'event_tz', v_tz);
END;
$function$;

REVOKE EXECUTE ON FUNCTION public.client_reschedule_reservation(UUID, DATE) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.client_reschedule_reservation(UUID, DATE) TO authenticated, service_role;
COMMENT ON FUNCTION public.client_reschedule_reservation(UUID, DATE) IS
  'sql/696 (Etapa 2) — el cliente mueve la FECHA de su reserva. Reproduce la regla de producto actual (confirmed/accepted + pagada + >24h) y valida disponibilidad con can_schedule() excluyendo la propia reserva. No toca precio, pago ni payout. No introduce aprobacion del proveedor (Fase 4). No persiste "ya reprogramada": hoy eso solo vive en estado de React.';

-- ═══════════════════════════════════════════════════════════════════════════
-- 3-4. group_accept_booking / group_decline_booking — sustituyen los UPDATE
--      directos de ConfirmBookingScreen.tsx:193 y :222
-- ═══════════════════════════════════════════════════════════════════════════
-- SEMÁNTICA INTACTA, a propósito. NO se reutilizan `group_confirm_booking` /
-- `group_reject_booking` porque NO son equivalentes:
--   · las existentes exigen status = 'pending_group_confirmation' y ponen
--     'confirmed';
--   · la pantalla acepta desde 'pending', 'pending_payment' o
--     'pending_group_confirmation' (condición de render en
--     ConfirmBookingScreen.tsx:708) y pone 'accepted' + booking_expiration_at
--     = ahora + 24 h.
-- Forzar la reutilización cambiaría la máquina de estados, y esta tarea es de
-- seguridad, no de rediseño. Los dos estados siguen existiendo y ninguno se
-- elimina. Las notificaciones se quedan en la pantalla (escriben en
-- `notifications`, no en `reservations`).
CREATE OR REPLACE FUNCTION public.group_accept_booking(p_reservation_id UUID)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_uid UUID;
  v_res RECORD;
BEGIN
  v_uid := auth.uid();
  IF v_uid IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_authenticated');
  END IF;

  SELECT r.*, g.owner_id INTO v_res
  FROM public.reservations r JOIN public.groups g ON g.id = r.group_id
  WHERE r.id = p_reservation_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_found');
  END IF;
  IF v_res.owner_id IS DISTINCT FROM v_uid THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_group_owner');
  END IF;

  -- Idempotente: si ya está aceptada, no es un error.
  IF v_res.status = 'accepted' THEN
    RETURN jsonb_build_object('ok', true, 'already', true, 'status', 'accepted');
  END IF;
  IF v_res.status NOT IN ('pending', 'pending_payment', 'pending_group_confirmation') THEN
    RETURN jsonb_build_object('ok', false, 'error', 'wrong_status', 'status', v_res.status);
  END IF;

  UPDATE public.reservations
  SET status = 'accepted', booking_expiration_at = NOW() + INTERVAL '24 hours'
  WHERE id = p_reservation_id;

  RETURN jsonb_build_object('ok', true, 'status', 'accepted',
                            'booking_expiration_at', NOW() + INTERVAL '24 hours');
END;
$function$;

CREATE OR REPLACE FUNCTION public.group_decline_booking(p_reservation_id UUID)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_uid UUID;
  v_res RECORD;
BEGIN
  v_uid := auth.uid();
  IF v_uid IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_authenticated');
  END IF;

  SELECT r.*, g.owner_id INTO v_res
  FROM public.reservations r JOIN public.groups g ON g.id = r.group_id
  WHERE r.id = p_reservation_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_found');
  END IF;
  IF v_res.owner_id IS DISTINCT FROM v_uid THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_group_owner');
  END IF;

  IF v_res.status = 'rejected' THEN
    RETURN jsonb_build_object('ok', true, 'already', true, 'status', 'rejected');
  END IF;
  IF v_res.status NOT IN ('pending', 'pending_payment', 'pending_group_confirmation') THEN
    RETURN jsonb_build_object('ok', false, 'error', 'wrong_status', 'status', v_res.status);
  END IF;

  UPDATE public.reservations SET status = 'rejected' WHERE id = p_reservation_id;

  RETURN jsonb_build_object('ok', true, 'status', 'rejected');
END;
$function$;

REVOKE EXECUTE ON FUNCTION public.group_accept_booking(UUID)  FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION public.group_decline_booking(UUID) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.group_accept_booking(UUID)  TO authenticated, service_role;
GRANT  EXECUTE ON FUNCTION public.group_decline_booking(UUID) TO authenticated, service_role;
COMMENT ON FUNCTION public.group_accept_booking(UUID) IS
  'sql/696 (Etapa 2) — el dueno del grupo acepta la reserva. Reproduce EXACTAMENTE lo que hacia ConfirmBookingScreen: estado origen pending/pending_payment/pending_group_confirmation -> accepted + booking_expiration_at = +24h. No se reutiliza group_confirm_booking porque esa pone confirmed y exige otro estado origen: la semantica no se cambia en una tarea de seguridad.';
COMMENT ON FUNCTION public.group_decline_booking(UUID) IS
  'sql/696 (Etapa 2) — el dueno del grupo rechaza la reserva -> rejected, con el mismo conjunto de estados origen que la pantalla. No se reutiliza group_reject_booking porque exige unicamente pending_group_confirmation.';

NOTIFY pgrst, 'reload schema';

COMMIT;
