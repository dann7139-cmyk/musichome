-- ============================================================
-- sql/585_shared_event_id.sql — event_id compartido real (Fase 1)
--
-- PROPÓSITO
--   Hoy cada reserva crea su propia fila en `events` (1:1), incluso
--   cuando 2-3 proveedores son para el MISMO evento real del cliente.
--   La única "agrupación" que existe es el candado de sql/556, que
--   compara texto (client_id, event_date, address) — NUNCA se toca esa
--   lógica aquí, sigue siendo la autoridad real del límite de 3.
--
--   Este archivo agrega un mecanismo PARALELO y EXPLÍCITO: el cliente
--   elige agregar una reserva nueva a un evento que ya tiene, y esa
--   reserva reutiliza el mismo events.id — sin depender de que la
--   dirección se escriba idéntica.
--
-- QUÉ NO CAMBIA (verificado antes de escribir esto)
--   - enforce_max_groups_per_event() / trg_enforce_max_groups_per_event:
--     INTACTOS. Siguen siendo el candado real de máximo 3.
--   - Ningún otro trigger de reservations (33 confirmados en vivo) lee
--     ni depende de event_id.
--   - Ninguna política RLS nueva hace falta: events_client_select/
--     insert/update, reservations_client_own, reservations_admin_all,
--     events_admin_all, events_group_select ya cubren exactamente lo
--     que las pantallas nuevas necesitan leer.
--   - Pagos, wallets, cotizaciones: cero cambios.
--
-- ALCANCE DE ESTE ARCHIVO
--   1. FK real reservations.event_id → events.id (hoy no existe;
--      verificado 0 filas huérfanas en producción).
--   2. Helper resolve_shared_event_id() — único punto de verdad para
--      decidir "reusar este event_id" vs "crear uno nuevo". Valida que
--      el event_id pertenece al cliente y no está lleno (defensa en
--      profundidad adicional, aparte del trigger real).
--   3. create_booking_with_event(): un parámetro nuevo opcional
--      p_event_id, con default NULL — el comportamiento por default
--      (sin pasar el parámetro) es IDÉNTICO al de hoy.
--   4. client_accept_proposal(): mismo parámetro nuevo opcional,
--      mismo default = comportamiento idéntico al de hoy.
--   5. Nuevas RPC de solo lectura: client_get_my_events(),
--      admin_get_event_detail(p_event_id).
--
-- ✅ APLICADO A PRODUCCIÓN 2026-08-31 con autorización explícita del
-- usuario. Probado antes en transacción autorevertible (11/11 PASS) y
-- verificado después: firmas únicas, permisos idénticos a los originales,
-- FK + trigger + columna activos, smoke test de las llamadas de la app OK.
-- NO RE-EJECUTAR (re-ejecutarlo es seguro por los DROP IF EXISTS, pero
-- no tiene ningún propósito).
-- ============================================================

BEGIN;

-- ── 1. FK real (0 huérfanos confirmados en producción) ──────────────────
-- Auditoría final (2026-09-02): ADD CONSTRAINT sin guarda NO es idempotente
-- (falla "constraint already exists" en una segunda ejecución accidental).
-- Se agrega DROP...IF EXISTS antes para que una re-ejecución sea segura:
-- falla limpio dentro de la misma transacción (0 cambios) en vez de dejar
-- el archivo en un estado "a medias" que dependa de recordar dónde se quedó.
ALTER TABLE public.reservations
  DROP CONSTRAINT IF EXISTS reservations_event_id_fkey;
ALTER TABLE public.reservations
  ADD CONSTRAINT reservations_event_id_fkey
  FOREIGN KEY (event_id) REFERENCES public.events(id) ON DELETE SET NULL;

-- ── 1b. Segundo trigger, NUEVO e INDEPENDIENTE del de sql/556 ───────────
-- HALLAZGO DE LA FASE 1B: si una fila se inserta directo en `reservations`
-- con event_id ya puesto pero una dirección de texto DISTINTA a la de los
-- otros proveedores del mismo evento (justo el caso que este diseño existe
-- para soportar — direcciones no tienen que ser idénticas), el trigger de
-- sql/556 (que compara texto) NO lo detecta, y el helper
-- resolve_shared_event_id() tampoco protege porque un INSERT directo no
-- pasa por él. Se necesita un candado real a nivel de trigger, aparte,
-- que cuente por event_id. No reemplaza ni modifica trg_enforce_max_groups
-- _per_event (sql/556) — son dos guardias independientes que se
-- complementan (uno por texto, otro por event_id).
CREATE OR REPLACE FUNCTION public.enforce_max_groups_per_shared_event()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $function$
DECLARE
  v_distinct_groups INT;
BEGIN
  IF NEW.event_id IS NULL THEN
    RETURN NEW;
  END IF;
  IF NOT (NEW.status = ANY (public.estados_que_ocupan())) THEN
    RETURN NEW;
  END IF;
  IF TG_OP = 'UPDATE' AND (OLD.status = ANY (public.estados_que_ocupan())) AND OLD.event_id IS NOT DISTINCT FROM NEW.event_id THEN
    RETURN NEW;
  END IF;

  PERFORM pg_advisory_xact_lock(hashtext('shared_event:' || NEW.event_id::text));

  SELECT COUNT(DISTINCT group_id) INTO v_distinct_groups
  FROM public.reservations
  WHERE event_id = NEW.event_id
    AND status = ANY (public.estados_que_ocupan())
    AND group_id <> NEW.group_id
    AND id <> NEW.id;

  IF v_distinct_groups >= 3 THEN
    RAISE EXCEPTION 'event_group_limit_reached: Ya hay 3 proveedores contratados para este evento.';
  END IF;

  RETURN NEW;
END;
$function$;

-- Auditoría final (2026-09-02): mismo motivo que la FK — DROP...IF EXISTS
-- antes de crear, para que una re-ejecución accidental sea segura.
DROP TRIGGER IF EXISTS trg_enforce_max_groups_per_shared_event ON public.reservations;
CREATE TRIGGER trg_enforce_max_groups_per_shared_event
BEFORE INSERT OR UPDATE OF status, event_id ON public.reservations
FOR EACH ROW
EXECUTE FUNCTION public.enforce_max_groups_per_shared_event();

-- ── 2. Único punto de verdad para resolver el event_id a usar ───────────
CREATE OR REPLACE FUNCTION public.resolve_shared_event_id(
  p_client_id  UUID,
  p_event_id   UUID,
  p_event_date DATE,
  p_event_time TIME,
  p_address    TEXT
) RETURNS UUID
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $function$
DECLARE
  v_event RECORD;
  v_new_id UUID;
BEGIN
  IF p_event_id IS NOT NULL THEN
    SELECT * INTO v_event FROM public.events WHERE id = p_event_id;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'event_not_found: %', p_event_id;
    END IF;
    IF v_event.client_id <> p_client_id THEN
      RAISE EXCEPTION 'event_not_owned_by_client';
    END IF;
    -- Defensa en profundidad extra (el candado real sigue siendo el
    -- trigger enforce_max_groups_per_event, sin tocarlo): confirmar que
    -- este evento no está ya lleno antes de intentar sumarle otra fila.
    IF (SELECT COUNT(DISTINCT group_id) FROM public.reservations
        WHERE event_id = p_event_id AND status = ANY (public.estados_que_ocupan())) >= 3 THEN
      RAISE EXCEPTION 'event_group_limit_reached: Ya hay 3 proveedores contratados para este evento.';
    END IF;
    RETURN p_event_id;
  END IF;

  INSERT INTO public.events (client_id, event_date, event_time, address, status)
  VALUES (p_client_id, p_event_date, p_event_time, p_address, 'active')
  RETURNING id INTO v_new_id;
  RETURN v_new_id;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.resolve_shared_event_id(UUID, UUID, DATE, TIME, TEXT) TO authenticated;

-- ── 3. create_booking_with_event(): +1 parámetro opcional, default = comportamiento actual ──
-- HALLAZGO CRÍTICO (prueba sintética 2026-08-31): agregar un parámetro con
-- CREATE OR REPLACE NO reemplaza la función — crea una SEGUNDA función
-- (overload) y deja la vieja de 14 parámetros viva. Con las dos coexistiendo,
-- la llamada RPC actual de la app (sin p_event_id) se vuelve AMBIGUA
-- ("function is not unique") y las reservas se romperían al instante.
-- Por eso PRIMERO se elimina la firma vieja, dentro de esta misma
-- transacción (si algo falla después, el ROLLBACK la restaura intacta).
DROP FUNCTION IF EXISTS public.create_booking_with_event(uuid, uuid, uuid, date, time without time zone, text, numeric, text, text, numeric, text, integer, numeric, text);

CREATE OR REPLACE FUNCTION public.create_booking_with_event(
  p_client_id uuid,
  p_group_id uuid,
  p_package_id uuid,
  p_event_date date,
  p_event_time time without time zone,
  p_address text,
  p_total_price numeric,
  p_notes text DEFAULT NULL::text,
  p_break_type text DEFAULT NULL::text,
  p_base_price numeric DEFAULT NULL::numeric,
  p_installment_plan text DEFAULT NULL::text,
  p_installment_months integer DEFAULT NULL::integer,
  p_installment_monthly_amount numeric DEFAULT NULL::numeric,
  p_payment_mode text DEFAULT 'full'::text,
  p_event_id uuid DEFAULT NULL::uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_event_id        UUID;
  v_reservation_id  UUID;
  v_flow_version    TEXT;
  v_distinct_groups INT;
BEGIN
  PERFORM pg_advisory_xact_lock(hashtext(p_group_id::text || p_event_date::text));

  IF EXISTS (
    SELECT 1 FROM group_unavailability
    WHERE group_id = p_group_id AND date = p_event_date
  ) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'date_blocked');
  END IF;

  -- Límite de 3 grupos por evento (sql/556, SIN TOCAR): mismo pre-check
  -- amistoso de siempre. Se queda idéntico; el trigger real sigue siendo
  -- la autoridad, con o sin este bloque.
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

  -- ÚNICO CAMBIO REAL: en vez de siempre INSERT INTO events, se resuelve
  -- vía el helper — que reutiliza p_event_id si se pasó, o crea uno
  -- nuevo si no (comportamiento idéntico al de hoy cuando p_event_id es NULL).
  -- resolve_shared_event_id() lanza EXCEPTION en sus casos de error (útil
  -- para client_accept_proposal, que ya captura todo con WHEN OTHERS) —
  -- aquí se convierte a un jsonb limpio para no romper el contrato de
  -- esta función (que el frontend ya sabe leer como {ok:false,error:...}).
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
    p_total_price, p_base_price, 'pending_payment',
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

-- El DROP borra los permisos de la función vieja — se replican idénticos
-- (verificados en pg_proc.proacl: anon, authenticated, service_role).
GRANT EXECUTE ON FUNCTION public.create_booking_with_event(uuid, uuid, uuid, date, time without time zone, text, numeric, text, text, numeric, text, integer, numeric, text, uuid) TO anon, authenticated, service_role;

-- ── 4. client_accept_proposal(): mismo patrón, +1 parámetro opcional ────
-- Mismo hallazgo que el punto 3: sin este DROP quedarían dos overloads
-- — client_accept_proposal(uuid) y (uuid, uuid DEFAULT NULL) — y la
-- llamada actual de la app (solo p_request_id) sería ambigua.
DROP FUNCTION IF EXISTS public.client_accept_proposal(uuid);

CREATE OR REPLACE FUNCTION public.client_accept_proposal(
  p_request_id UUID,
  p_event_id   UUID DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $function$
DECLARE
  v_req          RECORD;
  v_group        RECORD;
  v_client_total NUMERIC;
  v_group_price  NUMERIC;
  v_commission   NUMERIC;
  v_res_id       UUID;
  v_hours        INT;
  v_code         TEXT;
  v_resolved_event_id UUID;
BEGIN
  SELECT * INTO v_req FROM public.event_requests WHERE id = p_request_id;
  IF NOT FOUND THEN RETURN jsonb_build_object('ok', false, 'error', 'request_not_found'); END IF;
  IF v_req.client_id <> auth.uid() THEN RETURN jsonb_build_object('ok', false, 'error', 'not_owner'); END IF;

  SELECT id INTO v_res_id FROM public.reservations WHERE event_request_id = p_request_id LIMIT 1;
  IF FOUND THEN
    RETURN jsonb_build_object('ok', true, 'reservation_id', v_res_id, 'already_created', true);
  END IF;

  IF v_req.status <> 'en_negociacion' THEN RETURN jsonb_build_object('ok', false, 'error', 'not_in_negotiation'); END IF;
  IF v_req.negotiating_group_id IS NULL THEN RETURN jsonb_build_object('ok', false, 'error', 'no_group'); END IF;

  SELECT * INTO v_group FROM public.groups WHERE owner_id = v_req.negotiating_group_id LIMIT 1;
  IF NOT FOUND THEN RETURN jsonb_build_object('ok', false, 'error', 'group_not_found'); END IF;

  v_hours := COALESCE(v_req.hours, 1);
  v_client_total := COALESCE(
    (v_req.proposal_data->>'total_amount')::NUMERIC,
    (v_req.proposal_data->>'group_price')::NUMERIC,
    (v_req.proposal_data->>'total')::NUMERIC, 0);
  v_group_price := COALESCE(
    (v_req.proposal_data->>'group_price')::NUMERIC,
    (v_req.proposal_data->>'group_earnings')::NUMERIC,
    ROUND(v_client_total / 1.15), 0);
  v_commission := v_client_total - v_group_price;
  v_code := LPAD(FLOOR(RANDOM() * 10000)::TEXT, 4, '0');

  -- ÚNICO CAMBIO REAL: si el cliente eligió sumar esto a un evento
  -- existente, se resuelve/valida vía el mismo helper que usa
  -- create_booking_with_event — mismo candado de 3, mismo dueño.
  -- Si p_event_id es NULL (default), event_id queda NULL igual que hoy
  -- — comportamiento 100% idéntico al actual.
  IF p_event_id IS NOT NULL THEN
    v_resolved_event_id := public.resolve_shared_event_id(
      v_req.client_id, p_event_id, v_req.event_date,
      COALESCE((v_req.proposal_data->>'start_time'), v_req.event_time::TEXT, '20:00')::TIME,
      COALESCE(v_req.location_address, v_req.location_city, '')
    );
  ELSE
    v_resolved_event_id := NULL;
  END IF;

  INSERT INTO public.reservations (
    group_id, client_id, event_date, event_time, address, total_price, base_price,
    platform_commission, group_earnings, status, hours_count, event_request_id,
    break_type, arrival_code, event_id
  ) VALUES (
    v_group.id, v_req.client_id, v_req.event_date,
    COALESCE((v_req.proposal_data->>'start_time'), v_req.event_time::TEXT, '20:00')::TIME,
    COALESCE(v_req.location_address, v_req.location_city, ''),
    v_client_total, v_group_price, v_commission, v_group_price, 'accepted',
    v_hours, p_request_id, COALESCE(v_req.break_type, 'A'), v_code, v_resolved_event_id
  )
  RETURNING id INTO v_res_id;

  UPDATE public.event_requests
  SET status = 'accepted', accepted_by_group_id = v_group.id, accepted_reservation_id = v_res_id
  WHERE id = p_request_id;

  RETURN jsonb_build_object('ok', true, 'reservation_id', v_res_id, 'arrival_code', v_code, 'event_id', v_resolved_event_id);
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$function$;

-- Mismos permisos que tenía la firma vieja (pg_proc.proacl verificado).
GRANT EXECUTE ON FUNCTION public.client_accept_proposal(UUID, UUID) TO anon, authenticated, service_role;

-- ── 5. Lectura: "Mi evento" (cliente) ────────────────────────────────────
-- v2 (ampliado 2026-09-06) — 'providers' ahora también incluye cotizaciones
-- TODAVÍA SIN responder (pending/quoted), no solo reservas. Hallazgo real
-- del cliente probando: pedir la 1ª cotización a un grupo no dejaba ningún
-- evento "activo" que ofrecer al pedir la 2ª — obligaba a repetir todo el
-- formulario. Una cotización 'accepted' NO se duplica aquí porque para ese
-- punto ya existe su reservations.event_id (misma fila, vía quote_id) —
-- se filtra explícitamente por status para evitar contar dos veces al
-- mismo proveedor.
CREATE OR REPLACE FUNCTION public.client_get_my_events()
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $function$
DECLARE v_result jsonb;
BEGIN
  IF auth.uid() IS NULL THEN RETURN jsonb_build_object('ok', false, 'error', 'not_authenticated'); END IF;

  SELECT jsonb_build_object('ok', true, 'items', COALESCE(jsonb_agg(x.item ORDER BY x.event_date DESC), '[]'::jsonb))
  INTO v_result
  FROM (
    SELECT e.event_date, jsonb_build_object(
      'event_id', e.id, 'event_date', e.event_date, 'event_time', e.event_time, 'address', e.address,
      'providers', (
        SELECT COALESCE(jsonb_agg(x2.item ORDER BY x2.created_at), '[]'::jsonb) FROM (
          SELECT r.created_at, jsonb_build_object(
            'reservation_id', r.id, 'group_id', r.group_id, 'group_name', g.name,
            'status', r.status, 'payment_status', r.payment_status, 'total_price', r.total_price,
            'currency_code', r.currency_code
          ) AS item
          FROM public.reservations r JOIN public.groups g ON g.id = r.group_id
          WHERE r.event_id = e.id
          UNION ALL
          SELECT q.created_at, jsonb_build_object(
            'reservation_id', 'quote-' || q.id, 'group_id', q.group_id, 'group_name', g2.name,
            'status', q.status, 'payment_status', NULL, 'total_price', q.total_amount,
            -- quotes NO tiene currency_code (verificado information_schema 2026-08-31):
            -- se deriva del país del grupo, igual que hace la app al crear la reserva.
            'currency_code', (SELECT c.currency_code FROM public.countries c WHERE c.id = g2.country_id)
          ) AS item
          FROM public.quotes q JOIN public.groups g2 ON g2.id = q.group_id
          WHERE q.event_id = e.id AND q.status IN ('pending', 'quoted')
        ) x2
      )
    ) AS item
    FROM public.events e
    WHERE e.client_id = auth.uid()
  ) x;

  RETURN v_result;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.client_get_my_events() TO authenticated;

-- ── 6. Lectura: detalle de evento (admin) ────────────────────────────────
CREATE OR REPLACE FUNCTION public.admin_get_event_detail(p_event_id UUID)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $function$
DECLARE v_result jsonb;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM profiles WHERE id = auth.uid() AND role = 'admin') THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_admin');
  END IF;

  SELECT jsonb_build_object(
    'ok', true,
    'event', jsonb_build_object('id', e.id, 'event_date', e.event_date, 'event_time', e.event_time, 'address', e.address, 'client_id', e.client_id, 'client_name', p.full_name),
    'providers', (
      SELECT COALESCE(jsonb_agg(jsonb_build_object(
        'reservation_id', r.id, 'group_id', r.group_id, 'group_name', g.name,
        'status', r.status, 'payment_status', r.payment_status, 'total_price', r.total_price,
        'currency_code', r.currency_code,
        'needs_sound', q.needs_sound, 'needs_lighting', q.needs_lighting, 'needs_stage', q.needs_stage, 'needs_led', q.needs_led,
        'has_own_sound', g.has_sound, 'has_own_lighting', g.has_lighting
      ) ORDER BY r.created_at), '[]'::jsonb)
      FROM public.reservations r
      JOIN public.groups g ON g.id = r.group_id
      LEFT JOIN public.quotes q ON q.id = r.quote_id
      WHERE r.event_id = e.id
    )
  ) INTO v_result
  FROM public.events e
  LEFT JOIN public.profiles p ON p.id = e.client_id
  WHERE e.id = p_event_id;

  IF v_result IS NULL THEN RETURN jsonb_build_object('ok', false, 'error', 'not_found'); END IF;
  RETURN v_result;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.admin_get_event_detail(UUID) TO authenticated;

-- ── 7. quotes.event_id — MISMO patrón que reservations.event_id ─────────
-- Sin esto, una cotización personalizada (2do/3er proveedor pedido por
-- cotización en vez de reserva directa) no tiene forma de ligarse al
-- evento compartido, y su needs_sound/needs_lighting/needs_stage/needs_led
-- (YA EXISTEN, sql/33 — no se duplica nada) quedarían sueltos.
ALTER TABLE public.quotes ADD COLUMN IF NOT EXISTS event_id UUID REFERENCES public.events(id) ON DELETE SET NULL;

-- ── 8. Contexto de sonido para pre-llenar al pedir cotización del 2do/3er proveedor ──
CREATE OR REPLACE FUNCTION public.client_get_event_sound_context(p_event_id UUID)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $function$
DECLARE
  v_client_id UUID;
  v_result jsonb;
BEGIN
  IF auth.uid() IS NULL THEN RETURN jsonb_build_object('ok', false, 'error', 'not_authenticated'); END IF;
  SELECT client_id INTO v_client_id FROM public.events WHERE id = p_event_id;
  IF v_client_id IS NULL THEN RETURN jsonb_build_object('ok', false, 'error', 'event_not_found'); END IF;
  IF v_client_id <> auth.uid() THEN RETURN jsonb_build_object('ok', false, 'error', 'event_not_owned_by_client'); END IF;

  SELECT jsonb_build_object(
    'ok', true,
    'has_prior_declarations', COUNT(*) FILTER (WHERE q.needs_sound IS NOT NULL OR q.needs_lighting IS NOT NULL) > 0,
    'suggested_needs_sound', (array_agg(q.needs_sound ORDER BY
      CASE q.needs_sound WHEN 'si_200' THEN 4 WHEN 'si_100' THEN 3 WHEN 'si_50' THEN 2 WHEN 'si' THEN 1 ELSE 0 END DESC NULLS LAST
    ) FILTER (WHERE q.needs_sound IS NOT NULL))[1],
    'suggested_needs_lighting', (array_agg(q.needs_lighting ORDER BY
      CASE q.needs_lighting WHEN 'premium' THEN 3 WHEN 'pro' THEN 2 WHEN 'simple' THEN 1 ELSE 0 END DESC NULLS LAST
    ) FILTER (WHERE q.needs_lighting IS NOT NULL))[1],
    'declared_by', COALESCE(jsonb_agg(DISTINCT g.name) FILTER (
      WHERE q.needs_sound NOT IN ('no','no_group_brings','ya_tengo')
    ), '[]'::jsonb)
  ) INTO v_result
  FROM public.quotes q
  JOIN public.groups g ON g.id = q.group_id
  WHERE q.event_id = p_event_id;

  RETURN COALESCE(v_result, jsonb_build_object('ok', true, 'has_prior_declarations', false));
END;
$function$;

GRANT EXECUTE ON FUNCTION public.client_get_event_sound_context(UUID) TO authenticated;

-- ── 9. admin_get_event_detail(): +resumen de sonido del evento ──────────
-- Reemplaza la versión del punto 6 de este mismo archivo — agrega
-- 'sound_summary' sin quitar nada de lo que ya tenía. La bandera
-- needs_review es EXCLUSIVAMENTE por declaración real (quotes.needs_*),
-- NUNCA por cantidad de proveedores ni tamaño del evento (decisión
-- explícita del usuario, sql/585 v2).
--
-- v3 (ronda de verificación 2026-08-31): cada fila de `providers` ahora
-- también trae `genre` (único dato de "categoría" que existe hoy en
-- `groups` — no hay un campo category/provider_type separado, ver hallazgo
-- de categorías en el reporte) y su PROPIA cotización más reciente de este
-- evento (`quote`: id, status, needs_sound/lighting/stage/led) para que el
-- admin vea, por proveedor, quién declaró qué — no solo el agregado del
-- evento completo.
--
-- v4 (ampliado 2026-09-06): 'providers' ahora también incluye cotizaciones
-- pendientes/cotizadas SIN reserva todavía — antes 'sound_summary' ya las
-- contaba en el agregado, pero no aparecían como fila individual, así que
-- el admin no podía ver "quién" las pidió hasta que alguien aceptara.
CREATE OR REPLACE FUNCTION public.admin_get_event_detail(p_event_id UUID)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $function$
DECLARE v_result jsonb; v_sound jsonb;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM profiles WHERE id = auth.uid() AND role = 'admin') THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_admin');
  END IF;

  SELECT jsonb_build_object(
    'needs_review', COALESCE(bool_or(
      COALESCE(q.needs_sound NOT IN ('no','no_group_brings','ya_tengo'), false) OR
      COALESCE(q.needs_lighting NOT IN ('no'), false) OR
      COALESCE(q.needs_stage NOT IN ('no'), false) OR
      COALESCE(q.needs_led NOT IN ('no'), false)
    ), false),
    'max_needs_sound', (array_agg(q.needs_sound ORDER BY
      CASE q.needs_sound WHEN 'si_200' THEN 4 WHEN 'si_100' THEN 3 WHEN 'si_50' THEN 2 WHEN 'si' THEN 1 ELSE 0 END DESC NULLS LAST
    ) FILTER (WHERE q.needs_sound IS NOT NULL))[1],
    'requested_by', COALESCE(jsonb_agg(DISTINCT g.name) FILTER (
      WHERE q.needs_sound NOT IN ('no','no_group_brings','ya_tengo')
         OR q.needs_lighting NOT IN ('no') OR q.needs_stage NOT IN ('no') OR q.needs_led NOT IN ('no')
    ), '[]'::jsonb)
  ) INTO v_sound
  FROM public.quotes q
  JOIN public.groups g ON g.id = q.group_id
  WHERE q.event_id = p_event_id;

  SELECT jsonb_build_object(
    'ok', true,
    'event', jsonb_build_object('id', e.id, 'event_date', e.event_date, 'address', e.address, 'client_id', e.client_id),
    'sound_summary', COALESCE(v_sound, jsonb_build_object('needs_review', false)),
    'providers', (SELECT COALESCE(jsonb_agg(x3.item ORDER BY x3.created_at), '[]'::jsonb) FROM (
        SELECT r.created_at, jsonb_build_object(
          'reservation_id', r.id, 'group_id', r.group_id, 'group_name', g.name, 'genre', g.genre,
          'status', r.status, 'total_price', r.total_price, 'currency', COALESCE(r.currency_code, 'MXN'),
          'has_own_sound', g.has_sound,
          'quote', (SELECT jsonb_build_object(
              'id', q2.id, 'status', q2.status,
              'needs_sound', q2.needs_sound, 'needs_lighting', q2.needs_lighting,
              'needs_stage', q2.needs_stage, 'needs_led', q2.needs_led
            ) FROM public.quotes q2
            WHERE q2.group_id = r.group_id AND q2.event_id = e.id
            ORDER BY q2.created_at DESC LIMIT 1)
        ) AS item
        FROM public.reservations r JOIN public.groups g ON g.id = r.group_id WHERE r.event_id = e.id
        UNION ALL
        SELECT q3.created_at, jsonb_build_object(
          'reservation_id', 'quote-' || q3.id, 'group_id', q3.group_id, 'group_name', g3.name, 'genre', g3.genre,
          -- quotes NO tiene currency_code: se deriva del país del grupo.
          'status', q3.status, 'total_price', q3.total_amount,
          'currency', COALESCE((SELECT c.currency_code FROM public.countries c WHERE c.id = g3.country_id), 'MXN'),
          'has_own_sound', g3.has_sound,
          'quote', jsonb_build_object(
            'id', q3.id, 'status', q3.status,
            'needs_sound', q3.needs_sound, 'needs_lighting', q3.needs_lighting,
            'needs_stage', q3.needs_stage, 'needs_led', q3.needs_led
          )
        ) AS item
        FROM public.quotes q3 JOIN public.groups g3 ON g3.id = q3.group_id
        WHERE q3.event_id = e.id AND q3.status IN ('pending', 'quoted')
      ) x3)
  ) INTO v_result FROM public.events e WHERE e.id = p_event_id;

  IF v_result IS NULL THEN RETURN jsonb_build_object('ok', false, 'error', 'not_found'); END IF;
  RETURN v_result;
END;
$function$;

COMMIT;

SELECT '585_shared_event_id — APLICADO A PRODUCCIÓN 2026-08-31' AS status;
