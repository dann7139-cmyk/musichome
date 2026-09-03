-- ============================================================
-- sql/599_referral_client_discount.sql
-- ✅ APLICADO A PRODUCCIÓN 2026-09-02. Probado antes en transacción
-- autoreversible: 4 casos (descuento normal $100 MXN sin tocar al grupo,
-- 2ª cotización del mismo cliente NO vuelve a descontar, create_booking_
-- with_event con grupo US descuenta $5 USD, comisión menor al descuento
-- queda en $0 nunca negativa) — 4/4 PASS, 0 residuo verificado. Un
-- hallazgo falso positivo durante la prueba (no un bug real): al simular
-- el rol 'authenticated' con set_config('role',...) para probar como lo
-- haría la app, mi propia consulta de verificación quedó bloqueada por
-- RLS de referral_events (la función en sí, SECURITY DEFINER, sí veía y
-- actualizaba la fila bien) — solucionado con RESET role antes de leer.
-- ACL verificada tras aplicar: apply_referral_client_discount (interna)
-- solo postgres/service_role, ni anon ni authenticated. Smoke test vía
-- REST real (curl, anon key) contra client_accept_quote: HTTP 200,
-- {"ok":false,"error":"not_authenticated"} — confirma que PostgREST
-- refrescó su caché de esquema.
--
-- PETICIÓN REAL DEL USUARIO (2026-09-02): "pero la idea es que el cliente
-- gane algo también no?" — eligió, entre 3 opciones presentadas,
-- "Descuento directo en su 1ª reserva". Simétrico con el bono del grupo
-- (sql/597/598): $100 MXN / $5 USD, según la moneda de la reserva.
--
-- DECISIÓN DE DISEÑO (confirmada por el propio marco que dio el usuario:
-- "cuánto gano yo... menos lo que gana el grupo por el código Y el
-- cliente por ponerlo" — el descuento sale de la comisión de Daricefy,
-- el grupo cobra EXACTAMENTE lo mismo que cotizó, sin importar el
-- descuento del cliente):
--   - El grupo SIEMPRE recibe su base_price/group_earnings tal cual —
--     nunca se toca.
--   - El descuento se resta del total_price que paga el cliente, lo cual
--     reduce platform_commission (la ganancia de Daricefy) en esa misma
--     cantidad.
--   - Tope de seguridad: el descuento NUNCA puede dejar la comisión de
--     Daricefy en negativo — si la comisión de esa cotización/reserva es
--     menor al descuento completo, se aplica solo hasta donde alcance
--     (mínimo $0 de comisión, nunca negativa). Verificado contra
--     calculate_final_price() (única fuente real, comisión = 20% del
--     base_price) — hoy NINGUNA reserva real tiene comisión menor a
--     $100 MXN salvo cotizaciones extremadamente baratas.
--
-- ALCANCE: cubre los 2 caminos de creación de reserva ya auditados a
-- fondo (client_accept_quote, create_booking_with_event — el flujo
-- normal de cotización Y la reserva directa). NO cubre todavía
-- client_accept_proposal (Express) ni instant_accept_request — quedan
-- pendientes, reportado explícitamente, no oculto, para no apurar un
-- cambio de dinero en 2 funciones más sin la misma verificación a fondo.
--
-- Investigación previa (verificada contra el código real antes de
-- escribir esto, NO asumida):
--   - `reservations` tiene 30+ triggers; 3 de ellos calculan comisión
--     (calculate_commission_on_reservation/trg_calculate_commission/
--     trigger_calculate_commission, mismo cuerpo — legado duplicado) +
--     trg_set_reservation_financials. TODOS respetan un `base_price`
--     explícito en el INSERT (no lo sobrescriben si ya viene con valor),
--     así que fijar `base_price` explícito en el INSERT es lo que
--     protege al grupo — confirmado leyendo su código, no supuesto.
--   - `calculate_final_price()` (única fuente real): group_earnings =
--     base_price SIEMPRE, comisión = base_price × 20% SIEMPRE — no hay
--     travel_cost sumado encima en la práctica (columna existe pero 0
--     cotizaciones reales la usan hoy).
-- ============================================================

-- ── 1) Prueba en transacción autoreversible ─────────────────────────
BEGIN;

ALTER TABLE public.referral_events
  ADD COLUMN IF NOT EXISTS client_discount_applied  BOOLEAN NOT NULL DEFAULT FALSE,
  ADD COLUMN IF NOT EXISTS client_discount_amount    NUMERIC,
  ADD COLUMN IF NOT EXISTS client_discount_currency  TEXT;

CREATE OR REPLACE FUNCTION public.apply_referral_client_discount(
  p_client_id UUID,
  p_total     NUMERIC,
  p_base      NUMERIC,
  p_currency  TEXT
) RETURNS NUMERIC
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_ref_id   UUID;
  v_ccy      TEXT;
  v_discount NUMERIC;
  v_headroom NUMERIC;
BEGIN
  IF p_client_id IS NULL OR p_total IS NULL THEN
    RETURN p_total;
  END IF;

  SELECT id INTO v_ref_id
  FROM public.referral_events
  WHERE client_id = p_client_id AND client_discount_applied = FALSE
  FOR UPDATE SKIP LOCKED
  LIMIT 1;

  IF NOT FOUND THEN
    RETURN p_total;
  END IF;

  v_ccy      := CASE WHEN p_currency = 'USD' THEN 'USD' ELSE 'MXN' END;
  v_discount := CASE WHEN v_ccy = 'USD' THEN 5 ELSE 100 END;

  -- Nunca deja la comisión de Daricefy en negativo — tope = comisión real
  v_headroom := GREATEST(p_total - COALESCE(p_base, 0), 0);
  v_discount := LEAST(v_discount, v_headroom);

  IF v_discount <= 0 THEN
    RETURN p_total;
  END IF;

  UPDATE public.referral_events
  SET client_discount_applied  = TRUE,
      client_discount_amount   = v_discount,
      client_discount_currency = v_ccy
  WHERE id = v_ref_id;

  RETURN p_total - v_discount;

EXCEPTION WHEN OTHERS THEN
  RETURN p_total; -- defensivo: jamás bloquea una reserva por esto
END;
$function$;

REVOKE EXECUTE ON FUNCTION public.apply_referral_client_discount(UUID, NUMERIC, NUMERIC, TEXT) FROM PUBLIC, anon, authenticated;

-- ── client_accept_quote: aplica el descuento, base_price explícito ──
CREATE OR REPLACE FUNCTION public.client_accept_quote(
  p_quote_id   UUID,
  p_event_id   UUID DEFAULT NULL,
  p_msi_months INT  DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_quote RECORD;
  v_address TEXT;
  v_event_id UUID;
  v_event_time TIME;
  v_reservation_id UUID;
  v_currency TEXT;
  v_final_total NUMERIC;
BEGIN
  IF auth.uid() IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_authenticated');
  END IF;

  SELECT * INTO v_quote FROM public.quotes WHERE id = p_quote_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'quote_not_found');
  END IF;
  IF v_quote.client_id <> auth.uid() THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_owner');
  END IF;

  IF v_quote.status = 'accepted' THEN
    SELECT id INTO v_reservation_id FROM public.reservations WHERE quote_id = p_quote_id LIMIT 1;
    IF v_reservation_id IS NOT NULL THEN
      RETURN jsonb_build_object(
        'ok', true, 'reservation_id', v_reservation_id,
        'event_id', v_quote.event_id, 'already_accepted', true
      );
    END IF;
  END IF;

  v_address := NULLIF(TRIM(BOTH ', ' FROM
    CONCAT_WS(', ', v_quote.event_address, v_quote.event_municipio, v_quote.event_estado)
  ), '');
  v_event_time := COALESCE(v_quote.event_time, '20:00')::TIME;

  BEGIN
    v_event_id := public.resolve_shared_event_id(
      auth.uid(), COALESCE(v_quote.event_id, p_event_id), v_quote.event_date, v_event_time, COALESCE(v_address, '')
    );
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM LIKE 'event_group_limit_reached%' THEN
      RETURN jsonb_build_object('ok', false, 'error', 'event_group_limit_reached');
    ELSIF SQLERRM LIKE 'event_not_owned_by_client%' THEN
      RETURN jsonb_build_object('ok', false, 'error', 'event_not_owned_by_client');
    ELSIF SQLERRM LIKE 'event_not_found%' THEN
      RETURN jsonb_build_object('ok', false, 'error', 'event_not_found');
    ELSE
      RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
    END IF;
  END;

  -- sql/599 — descuento de referido (si el cliente tiene uno pendiente),
  -- moneda real de la reserva (grupo → país → moneda), base_price
  -- explícito para que el grupo NUNCA se vea afectado por el descuento.
  SELECT COALESCE(c.currency_code, 'MXN') INTO v_currency
  FROM public.groups g LEFT JOIN public.countries c ON c.id = g.country_id
  WHERE g.id = v_quote.group_id;

  v_final_total := public.apply_referral_client_discount(
    auth.uid(), v_quote.total_amount, v_quote.base_price, v_currency
  );

  BEGIN
    INSERT INTO public.reservations (
      event_id, client_id, group_id, event_date, event_time, address,
      base_price, total_price, status, quote_id, notes, msi_months,
      is_gift, gift_recipient_name, gift_recipient_contact, gift_message
    ) VALUES (
      v_event_id, auth.uid(), v_quote.group_id, v_quote.event_date, v_event_time, v_address,
      v_quote.base_price, v_final_total, 'accepted', v_quote.id, v_quote.comments,
      CASE WHEN COALESCE(p_msi_months, 1) > 1 THEN p_msi_months ELSE NULL END,
      v_quote.is_gift, v_quote.gift_recipient_name, v_quote.gift_recipient_contact, v_quote.gift_message
    ) RETURNING id INTO v_reservation_id;
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM LIKE '%date_blocked%' OR SQLERRM LIKE '%date_taken%' THEN
      RETURN jsonb_build_object('ok', false, 'error', 'date_blocked');
    ELSIF SQLERRM LIKE '%daily_event_limit%' THEN
      RETURN jsonb_build_object('ok', false, 'error', 'daily_event_limit');
    ELSIF SQLERRM LIKE '%time_overlap%' THEN
      RETURN jsonb_build_object('ok', false, 'error', 'time_overlap');
    ELSIF SQLERRM LIKE '%event_group_limit_reached%' THEN
      RETURN jsonb_build_object('ok', false, 'error', 'event_group_limit_reached');
    ELSE
      RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
    END IF;
  END;

  UPDATE public.quotes SET status = 'accepted' WHERE id = p_quote_id;

  RETURN jsonb_build_object('ok', true, 'reservation_id', v_reservation_id, 'event_id', v_event_id);
END;
$function$;

GRANT EXECUTE ON FUNCTION public.client_accept_quote(UUID, UUID, INT) TO authenticated;

-- ── create_booking_with_event: aplica el descuento sobre p_total_price ──
CREATE OR REPLACE FUNCTION public.create_booking_with_event(
  p_client_id UUID,
  p_group_id UUID,
  p_package_id UUID,
  p_event_date DATE,
  p_event_time TIME,
  p_address TEXT,
  p_total_price NUMERIC,
  p_notes TEXT DEFAULT NULL,
  p_break_type TEXT DEFAULT NULL,
  p_base_price NUMERIC DEFAULT NULL,
  p_installment_plan TEXT DEFAULT NULL,
  p_installment_months INT DEFAULT NULL,
  p_installment_monthly_amount NUMERIC DEFAULT NULL,
  p_payment_mode TEXT DEFAULT 'full',
  p_event_id UUID DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_event_id        UUID;
  v_reservation_id  UUID;
  v_flow_version    TEXT;
  v_distinct_groups INT;
  v_currency        TEXT;
  v_final_total     NUMERIC;
BEGIN
  IF auth.uid() IS NULL OR p_client_id <> auth.uid() THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_owner');
  END IF;

  PERFORM pg_advisory_xact_lock(hashtext(p_group_id::text || p_event_date::text));

  IF EXISTS (
    SELECT 1 FROM group_unavailability
    WHERE group_id = p_group_id AND date = p_event_date
  ) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'date_blocked');
  END IF;

  PERFORM pg_advisory_xact_lock(
    hashtext(p_client_id::text || p_event_date::text || lower(trim(p_address)))
  );

  SELECT COUNT(DISTINCT group_id) INTO v_distinct_groups
  FROM public.reservations
  WHERE client_id = p_client_id
    AND event_date = p_event_date
    AND lower(trim(address)) = lower(trim(p_address))
    AND status = ANY (public.estados_que_ocupan())
    AND group_id <> p_group_id;

  IF v_distinct_groups >= 3 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'event_group_limit_reached');
  END IF;

  v_flow_version := CASE
    WHEN p_payment_mode = 'full' THEN 'full_payment_v2'
    ELSE 'legacy'
  END;

  BEGIN
    v_event_id := public.resolve_shared_event_id(p_client_id, p_event_id, p_event_date, p_event_time, p_address);
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM LIKE 'event_group_limit_reached%' THEN
      RETURN jsonb_build_object('ok', false, 'error', 'event_group_limit_reached');
    ELSIF SQLERRM LIKE 'event_not_owned_by_client%' THEN
      RETURN jsonb_build_object('ok', false, 'error', 'event_not_owned_by_client');
    ELSIF SQLERRM LIKE 'event_not_found%' THEN
      RETURN jsonb_build_object('ok', false, 'error', 'event_not_found');
    ELSE
      RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
    END IF;
  END;

  -- sql/599 — descuento de referido, mismo criterio que client_accept_quote
  SELECT COALESCE(c.currency_code, 'MXN') INTO v_currency
  FROM public.groups g LEFT JOIN public.countries c ON c.id = g.country_id
  WHERE g.id = p_group_id;

  v_final_total := public.apply_referral_client_discount(
    p_client_id, p_total_price, p_base_price, v_currency
  );

  INSERT INTO public.reservations (
    event_id, group_id, client_id,
    event_date, event_time, address, notes, break_type,
    total_price, base_price, status,
    payment_mode, flow_version,
    installment_plan, installment_months, installment_monthly_amount
  )
  VALUES (
    v_event_id, p_group_id, p_client_id,
    p_event_date, p_event_time, p_address, p_notes, p_break_type,
    v_final_total, p_base_price, 'pending_payment',
    p_payment_mode, v_flow_version,
    p_installment_plan, p_installment_months, p_installment_monthly_amount
  )
  RETURNING id INTO v_reservation_id;

  RAISE NOTICE '[CREATE_BOOKING] reservation=% mode=% msi=% event=%',
    v_reservation_id, p_payment_mode, COALESCE(p_installment_plan, '1_pago'), v_event_id;

  RETURN jsonb_build_object(
    'reservation_id', v_reservation_id,
    'event_id',       v_event_id
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.create_booking_with_event(
  UUID, UUID, UUID, DATE, TIME, TEXT, NUMERIC, TEXT, TEXT, NUMERIC, TEXT, INT, NUMERIC, TEXT, UUID
) TO authenticated;

-- ═══════════════════════════════════════════════════════════════════
DO $test$
DECLARE
  v_owner      UUID := '929ba9ba-1dfd-4b76-abf1-18168b1ac1ba';
  v_client_mx  UUID := '013ce98d-d8b6-42cf-b466-30e27d937914';
  v_client_us  UUID := '6f924da5-54b1-46cc-a8bd-33e8b0f7f2fa';
  v_client_cheap UUID := '929ba9ba-1dfd-4b76-abf1-18168b1ac1ba';
  v_group_mx   UUID;
  v_group_us   UUID;
  v_group_cheap UUID;
  v_country_mx UUID;
  v_country_us UUID;
  v_quote_id   UUID;
  v_result     jsonb;
  v_res        RECORD;
  v_ref        RECORD;
BEGIN
  SELECT id INTO v_country_mx FROM public.countries WHERE currency_code='MXN' LIMIT 1;
  SELECT id INTO v_country_us FROM public.countries WHERE currency_code='USD' LIMIT 1;

  INSERT INTO public.groups (id, owner_id, name, genre, country_id, referral_code)
    VALUES (gen_random_uuid(), v_owner, 'Test599 Grupo MX', 'Banda', v_country_mx, 'TEST599MX')
    RETURNING id INTO v_group_mx;
  INSERT INTO public.groups (id, owner_id, name, genre, country_id, referral_code)
    VALUES (gen_random_uuid(), v_owner, 'Test599 Grupo US', 'Banda', v_country_us, 'TEST599US')
    RETURNING id INTO v_group_us;
  INSERT INTO public.groups (id, owner_id, name, genre, country_id, referral_code)
    VALUES (gen_random_uuid(), v_owner, 'Test599 Grupo Barato', 'Banda', v_country_mx, 'TEST599CH')
    RETURNING id INTO v_group_cheap;

  -- ── Caso 1: cotización normal MXN, con referido pendiente ──────────
  INSERT INTO public.referral_events (group_id, client_id, referral_code)
    VALUES (v_group_mx, v_client_mx, 'TEST599MX');

  INSERT INTO public.quotes (id, group_id, client_id, event_date, event_time, duration_hours, status,
    event_type, event_address, event_municipio, event_estado, venue_covered, venue_size, needs_sound,
    base_price, commission_amount, total_amount, group_earnings)
    VALUES (gen_random_uuid(), v_group_mx, v_client_mx, CURRENT_DATE + 20, '18:00', 3, 'pending',
      'boda', 'Dir', 'Muni', 'Edo', 'si', 'salon_mediano', 'no_group_brings',
      9000, 1800, 10800, 9000)
    RETURNING id INTO v_quote_id;

  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_client_mx::text, 'role','authenticated')::text, true);
  PERFORM set_config('role','authenticated', true);

  v_result := public.client_accept_quote(v_quote_id, NULL, NULL);
  ASSERT v_result->>'ok' = 'true', 'FAIL caso1 ok: ' || v_result::text;

  SELECT * INTO v_res FROM public.reservations WHERE id = (v_result->>'reservation_id')::uuid;
  ASSERT v_res.total_price = 10700, 'FAIL caso1 total_price (10800-100=10700): ' || v_res.total_price::text;
  ASSERT v_res.base_price = 9000, 'FAIL caso1 base_price (grupo intacto): ' || v_res.base_price::text;
  ASSERT v_res.group_earnings = 9000, 'FAIL caso1 group_earnings (grupo intacto): ' || v_res.group_earnings::text;
  ASSERT v_res.platform_commission = 1700, 'FAIL caso1 comision Daricefy (1800-100=1700): ' || v_res.platform_commission::text;

  SELECT * INTO v_ref FROM public.referral_events WHERE client_id = v_client_mx;
  ASSERT v_ref.client_discount_applied = TRUE, 'FAIL caso1 discount_applied';
  ASSERT v_ref.client_discount_amount = 100, 'FAIL caso1 discount_amount: ' || v_ref.client_discount_amount::text;
  ASSERT v_ref.client_discount_currency = 'MXN', 'FAIL caso1 discount_currency';

  -- ── Caso 2: 2ª cotización del MISMO cliente — YA no debe descontar de nuevo ──
  DECLARE v_quote_id2 UUID; v_res2 RECORD;
  BEGIN
    INSERT INTO public.quotes (id, group_id, client_id, event_date, event_time, duration_hours, status,
      event_type, event_address, event_municipio, event_estado, venue_covered, venue_size, needs_sound,
      base_price, commission_amount, total_amount, group_earnings)
      VALUES (gen_random_uuid(), v_group_mx, v_client_mx, CURRENT_DATE + 21, '18:00', 3, 'pending',
        'boda', 'Dir', 'Muni', 'Edo', 'si', 'salon_mediano', 'no_group_brings',
        5000, 1000, 6000, 5000)
      RETURNING id INTO v_quote_id2;
    v_result := public.client_accept_quote(v_quote_id2, NULL, NULL);
    ASSERT v_result->>'ok' = 'true', 'FAIL caso2 ok: ' || v_result::text;
    SELECT * INTO v_res2 FROM public.reservations WHERE id = (v_result->>'reservation_id')::uuid;
    ASSERT v_res2.total_price = 6000, 'FAIL caso2 NO debe descontar 2 veces: ' || v_res2.total_price::text;
  END;

  -- ── Caso 3: create_booking_with_event, grupo US, cliente con referido ──
  INSERT INTO public.referral_events (group_id, client_id, referral_code)
    VALUES (v_group_mx, v_client_us, 'TEST599MX2');

  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_client_us::text, 'role','authenticated')::text, true);
  PERFORM set_config('role','authenticated', true);

  v_result := public.create_booking_with_event(
    v_client_us, v_group_us, NULL, CURRENT_DATE + 22, '19:00'::time, 'Dir US',
    2400, NULL, NULL, 2000, NULL, NULL, NULL, 'full', NULL
  );
  ASSERT (v_result->>'reservation_id') IS NOT NULL, 'FAIL caso3: ' || v_result::text;
  SELECT * INTO v_res FROM public.reservations WHERE id = (v_result->>'reservation_id')::uuid;
  ASSERT v_res.total_price = 2395, 'FAIL caso3 total (2400-5=2395): ' || v_res.total_price::text;
  ASSERT v_res.base_price = 2000, 'FAIL caso3 base_price intacto: ' || v_res.base_price::text;

  -- ── Caso 4: comisión más chica que el descuento — nunca queda negativa ──
  INSERT INTO public.referral_events (group_id, client_id, referral_code)
    VALUES (v_group_cheap, v_client_cheap, 'TEST599CH2');
  DECLARE v_quote_id3 UUID; v_res3 RECORD;
  BEGIN
    INSERT INTO public.quotes (id, group_id, client_id, event_date, event_time, duration_hours, status,
      event_type, event_address, event_municipio, event_estado, venue_covered, venue_size, needs_sound,
      base_price, commission_amount, total_amount, group_earnings)
      VALUES (gen_random_uuid(), v_group_cheap, v_client_cheap, CURRENT_DATE + 23, '18:00', 3, 'pending',
        'boda', 'Dir', 'Muni', 'Edo', 'si', 'salon_mediano', 'no_group_brings',
        200, 40, 240, 200)  -- comision real = 40, MENOR al descuento de 100
      RETURNING id INTO v_quote_id3;

    PERFORM set_config('request.jwt.claims', json_build_object('sub', v_client_cheap::text, 'role','authenticated')::text, true);
    PERFORM set_config('role','authenticated', true);

    v_result := public.client_accept_quote(v_quote_id3, NULL, NULL);
    ASSERT v_result->>'ok' = 'true', 'FAIL caso4 ok: ' || v_result::text;
    SELECT * INTO v_res3 FROM public.reservations WHERE id = (v_result->>'reservation_id')::uuid;
    -- Descuento debe topar en 40 (la comisión real), no 100 completos
    ASSERT v_res3.total_price = 200, 'FAIL caso4 total_price (240-40=200, TOPADO): ' || v_res3.total_price::text;
    ASSERT v_res3.base_price = 200, 'FAIL caso4 base_price intacto: ' || v_res3.base_price::text;
    ASSERT v_res3.platform_commission = 0, 'FAIL caso4 comision Daricefy nunca negativa: ' || v_res3.platform_commission::text;
  END;

  RAISE EXCEPTION 'ROLLBACK_TEST_OK — 4 casos pasaron: descuento normal, no-doble-uso, US, tope de comisión';
END;
$test$;

ROLLBACK;

-- ── 2) Aplicación real ───────────────────────────────────────────────
BEGIN;

ALTER TABLE public.referral_events
  ADD COLUMN IF NOT EXISTS client_discount_applied  BOOLEAN NOT NULL DEFAULT FALSE,
  ADD COLUMN IF NOT EXISTS client_discount_amount    NUMERIC,
  ADD COLUMN IF NOT EXISTS client_discount_currency  TEXT;

CREATE OR REPLACE FUNCTION public.apply_referral_client_discount(
  p_client_id UUID,
  p_total     NUMERIC,
  p_base      NUMERIC,
  p_currency  TEXT
) RETURNS NUMERIC
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_ref_id   UUID;
  v_ccy      TEXT;
  v_discount NUMERIC;
  v_headroom NUMERIC;
BEGIN
  IF p_client_id IS NULL OR p_total IS NULL THEN
    RETURN p_total;
  END IF;

  SELECT id INTO v_ref_id
  FROM public.referral_events
  WHERE client_id = p_client_id AND client_discount_applied = FALSE
  FOR UPDATE SKIP LOCKED
  LIMIT 1;

  IF NOT FOUND THEN
    RETURN p_total;
  END IF;

  v_ccy      := CASE WHEN p_currency = 'USD' THEN 'USD' ELSE 'MXN' END;
  v_discount := CASE WHEN v_ccy = 'USD' THEN 5 ELSE 100 END;

  v_headroom := GREATEST(p_total - COALESCE(p_base, 0), 0);
  v_discount := LEAST(v_discount, v_headroom);

  IF v_discount <= 0 THEN
    RETURN p_total;
  END IF;

  UPDATE public.referral_events
  SET client_discount_applied  = TRUE,
      client_discount_amount   = v_discount,
      client_discount_currency = v_ccy
  WHERE id = v_ref_id;

  RETURN p_total - v_discount;

EXCEPTION WHEN OTHERS THEN
  RETURN p_total;
END;
$function$;

REVOKE EXECUTE ON FUNCTION public.apply_referral_client_discount(UUID, NUMERIC, NUMERIC, TEXT) FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.client_accept_quote(
  p_quote_id   UUID,
  p_event_id   UUID DEFAULT NULL,
  p_msi_months INT  DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_quote RECORD;
  v_address TEXT;
  v_event_id UUID;
  v_event_time TIME;
  v_reservation_id UUID;
  v_currency TEXT;
  v_final_total NUMERIC;
BEGIN
  IF auth.uid() IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_authenticated');
  END IF;

  SELECT * INTO v_quote FROM public.quotes WHERE id = p_quote_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'quote_not_found');
  END IF;
  IF v_quote.client_id <> auth.uid() THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_owner');
  END IF;

  IF v_quote.status = 'accepted' THEN
    SELECT id INTO v_reservation_id FROM public.reservations WHERE quote_id = p_quote_id LIMIT 1;
    IF v_reservation_id IS NOT NULL THEN
      RETURN jsonb_build_object(
        'ok', true, 'reservation_id', v_reservation_id,
        'event_id', v_quote.event_id, 'already_accepted', true
      );
    END IF;
  END IF;

  v_address := NULLIF(TRIM(BOTH ', ' FROM
    CONCAT_WS(', ', v_quote.event_address, v_quote.event_municipio, v_quote.event_estado)
  ), '');
  v_event_time := COALESCE(v_quote.event_time, '20:00')::TIME;

  BEGIN
    v_event_id := public.resolve_shared_event_id(
      auth.uid(), COALESCE(v_quote.event_id, p_event_id), v_quote.event_date, v_event_time, COALESCE(v_address, '')
    );
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM LIKE 'event_group_limit_reached%' THEN
      RETURN jsonb_build_object('ok', false, 'error', 'event_group_limit_reached');
    ELSIF SQLERRM LIKE 'event_not_owned_by_client%' THEN
      RETURN jsonb_build_object('ok', false, 'error', 'event_not_owned_by_client');
    ELSIF SQLERRM LIKE 'event_not_found%' THEN
      RETURN jsonb_build_object('ok', false, 'error', 'event_not_found');
    ELSE
      RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
    END IF;
  END;

  SELECT COALESCE(c.currency_code, 'MXN') INTO v_currency
  FROM public.groups g LEFT JOIN public.countries c ON c.id = g.country_id
  WHERE g.id = v_quote.group_id;

  v_final_total := public.apply_referral_client_discount(
    auth.uid(), v_quote.total_amount, v_quote.base_price, v_currency
  );

  BEGIN
    INSERT INTO public.reservations (
      event_id, client_id, group_id, event_date, event_time, address,
      base_price, total_price, status, quote_id, notes, msi_months,
      is_gift, gift_recipient_name, gift_recipient_contact, gift_message
    ) VALUES (
      v_event_id, auth.uid(), v_quote.group_id, v_quote.event_date, v_event_time, v_address,
      v_quote.base_price, v_final_total, 'accepted', v_quote.id, v_quote.comments,
      CASE WHEN COALESCE(p_msi_months, 1) > 1 THEN p_msi_months ELSE NULL END,
      v_quote.is_gift, v_quote.gift_recipient_name, v_quote.gift_recipient_contact, v_quote.gift_message
    ) RETURNING id INTO v_reservation_id;
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM LIKE '%date_blocked%' OR SQLERRM LIKE '%date_taken%' THEN
      RETURN jsonb_build_object('ok', false, 'error', 'date_blocked');
    ELSIF SQLERRM LIKE '%daily_event_limit%' THEN
      RETURN jsonb_build_object('ok', false, 'error', 'daily_event_limit');
    ELSIF SQLERRM LIKE '%time_overlap%' THEN
      RETURN jsonb_build_object('ok', false, 'error', 'time_overlap');
    ELSIF SQLERRM LIKE '%event_group_limit_reached%' THEN
      RETURN jsonb_build_object('ok', false, 'error', 'event_group_limit_reached');
    ELSE
      RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
    END IF;
  END;

  UPDATE public.quotes SET status = 'accepted' WHERE id = p_quote_id;

  RETURN jsonb_build_object('ok', true, 'reservation_id', v_reservation_id, 'event_id', v_event_id);
END;
$function$;

GRANT EXECUTE ON FUNCTION public.client_accept_quote(UUID, UUID, INT) TO authenticated;

CREATE OR REPLACE FUNCTION public.create_booking_with_event(
  p_client_id UUID,
  p_group_id UUID,
  p_package_id UUID,
  p_event_date DATE,
  p_event_time TIME,
  p_address TEXT,
  p_total_price NUMERIC,
  p_notes TEXT DEFAULT NULL,
  p_break_type TEXT DEFAULT NULL,
  p_base_price NUMERIC DEFAULT NULL,
  p_installment_plan TEXT DEFAULT NULL,
  p_installment_months INT DEFAULT NULL,
  p_installment_monthly_amount NUMERIC DEFAULT NULL,
  p_payment_mode TEXT DEFAULT 'full',
  p_event_id UUID DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_event_id        UUID;
  v_reservation_id  UUID;
  v_flow_version    TEXT;
  v_distinct_groups INT;
  v_currency        TEXT;
  v_final_total     NUMERIC;
BEGIN
  IF auth.uid() IS NULL OR p_client_id <> auth.uid() THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_owner');
  END IF;

  PERFORM pg_advisory_xact_lock(hashtext(p_group_id::text || p_event_date::text));

  IF EXISTS (
    SELECT 1 FROM group_unavailability
    WHERE group_id = p_group_id AND date = p_event_date
  ) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'date_blocked');
  END IF;

  PERFORM pg_advisory_xact_lock(
    hashtext(p_client_id::text || p_event_date::text || lower(trim(p_address)))
  );

  SELECT COUNT(DISTINCT group_id) INTO v_distinct_groups
  FROM public.reservations
  WHERE client_id = p_client_id
    AND event_date = p_event_date
    AND lower(trim(address)) = lower(trim(p_address))
    AND status = ANY (public.estados_que_ocupan())
    AND group_id <> p_group_id;

  IF v_distinct_groups >= 3 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'event_group_limit_reached');
  END IF;

  v_flow_version := CASE
    WHEN p_payment_mode = 'full' THEN 'full_payment_v2'
    ELSE 'legacy'
  END;

  BEGIN
    v_event_id := public.resolve_shared_event_id(p_client_id, p_event_id, p_event_date, p_event_time, p_address);
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM LIKE 'event_group_limit_reached%' THEN
      RETURN jsonb_build_object('ok', false, 'error', 'event_group_limit_reached');
    ELSIF SQLERRM LIKE 'event_not_owned_by_client%' THEN
      RETURN jsonb_build_object('ok', false, 'error', 'event_not_owned_by_client');
    ELSIF SQLERRM LIKE 'event_not_found%' THEN
      RETURN jsonb_build_object('ok', false, 'error', 'event_not_found');
    ELSE
      RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
    END IF;
  END;

  SELECT COALESCE(c.currency_code, 'MXN') INTO v_currency
  FROM public.groups g LEFT JOIN public.countries c ON c.id = g.country_id
  WHERE g.id = p_group_id;

  v_final_total := public.apply_referral_client_discount(
    p_client_id, p_total_price, p_base_price, v_currency
  );

  INSERT INTO public.reservations (
    event_id, group_id, client_id,
    event_date, event_time, address, notes, break_type,
    total_price, base_price, status,
    payment_mode, flow_version,
    installment_plan, installment_months, installment_monthly_amount
  )
  VALUES (
    v_event_id, p_group_id, p_client_id,
    p_event_date, p_event_time, p_address, p_notes, p_break_type,
    v_final_total, p_base_price, 'pending_payment',
    p_payment_mode, v_flow_version,
    p_installment_plan, p_installment_months, p_installment_monthly_amount
  )
  RETURNING id INTO v_reservation_id;

  RAISE NOTICE '[CREATE_BOOKING] reservation=% mode=% msi=% event=%',
    v_reservation_id, p_payment_mode, COALESCE(p_installment_plan, '1_pago'), v_event_id;

  RETURN jsonb_build_object(
    'reservation_id', v_reservation_id,
    'event_id',       v_event_id
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.create_booking_with_event(
  UUID, UUID, UUID, DATE, TIME, TEXT, NUMERIC, TEXT, TEXT, NUMERIC, TEXT, INT, NUMERIC, TEXT, UUID
) TO authenticated;

COMMIT;

SELECT '599_referral_client_discount — APLICADO A PRODUCCIÓN 2026-09-02' AS status;
