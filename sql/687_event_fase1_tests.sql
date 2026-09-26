-- ═══════════════════════════════════════════════════════════════════════════
-- sql/687 — SUITE DE PRUEBAS de sql/685 + sql/686 (Fase 1 de "Mi Evento")
-- ═══════════════════════════════════════════════════════════════════════════
--
-- NO APLICA NADA. Solo prueba. 100% seguro de correr en cualquier momento:
-- todo pasa dentro de BEGIN...ROLLBACK y termina con un RAISE EXCEPTION que
-- garantiza la reversión — no deja ni una fila en la base real.
--
-- Requiere sql/685 y sql/686 YA aplicados. Correr esto DESPUÉS de aplicarlos,
-- y otra vez cada vez que se toque alguna de estas piezas:
--   · public.events (columnas de Fase 1)
--   · client_update_event_details()
--   · client_get_my_events()
--   · max_providers_per_event()
--   · enforce_max_groups_per_event() / enforce_max_groups_per_shared_event()
--   · resolve_shared_event_id() / create_booking_with_event()
--
-- Mismo patrón que sql/602: reusa cuentas reales existentes solo como FK
-- válidas dentro de la transacción que se revierte — nunca les manda nada.
--
-- CUBRE:
--   [1]  Las 8 columnas nuevas existen, son nullable y no tienen DEFAULT; y
--        events.updated_at existe (sin ella, TODO UPDATE sobre events fallaba
--        con 42703 — bug preexistente que sql/685 corrige).
--   [2]  Un evento existente con los 8 campos VACÍOS sigue abriendo en
--        client_get_my_events() y conserva todas las llaves de antes.
--   [3]  client_get_my_events() ya manda los campos nuevos + provider_limit.
--   [4]  max_providers_per_event() = 20 y las 4 capas lo leen (ninguna tiene
--        el 3 hardcodeado).
--   [5]  client_update_event_details(): guardado normal completo.
--   [6]  Vacía campos cuando se manda NULL (reemplazo completo).
--   [7]  Rechaza evento ajeno / inexistente / sin sesión.
--   [8]  Rechaza tipo, invitados, presupuesto y hora inválidos con error limpio.
--   [9]  NUNCA toca status / total_price / payment_status / payment_intent_id /
--        event_date / event_time / address.
--   [10] Moneda del presupuesto se deriva del país del cliente (MXN).
--   [11] end_time puede ser menor que event_time (evento que cruza medianoche).
--   [12] 20 proveedores DISTINTOS caben en el mismo evento; el 21 se rechaza.
--   [13] Dos proveedores de la MISMA categoría caben en el mismo evento.
--   [14] Cada reserva sigue siendo independiente (grupo, precio y estado
--        propios; nada se une ni se reparte).
--   [15] Contratación normal de UN solo proveedor sigue funcionando igual
--        (create_booking_with_event sin p_event_id).
--   [16] create_booking_with_event CON p_event_id reutiliza el evento.
--   [17] resolve_shared_event_id: evento ajeno y evento inexistente siguen
--        rechazados.
--   [18] Aceptar una cotización sigue creando/reutilizando event_id
--        (client_accept_quote), y una cotización legacy sin event_id sigue
--        creando el suyo [18b].
-- ═══════════════════════════════════════════════════════════════════════════

BEGIN;

DO $suite$
DECLARE
  v_client      UUID := '889e7168-a30a-49c5-a32a-cbeb320d00f8'; -- Lala, real (solo como FK)
  v_owner       UUID := '929ba9ba-1dfd-4b76-abf1-18168b1ac1ba'; -- dueño real (solo como FK)
  v_country_mx  UUID;
  v_date        DATE := CURRENT_DATE + 210;  -- fecha propia y lejana, para no
                                             -- chocar con nada real ni con
                                             -- enforce_max_groups_per_event
  v_addr        TEXT := 'RT687 Salón de Pruebas 123, Zapopan';
  v_event       UUID;
  v_res         JSONB;
  v_row         RECORD;
BEGIN
  SELECT id INTO v_country_mx FROM public.countries WHERE currency_code = 'MXN' LIMIT 1;

  -- ══ [1] Columnas nuevas: existen, nullable, sin DEFAULT ═══════════════════
  DECLARE
    v_col TEXT;
    v_cols TEXT[] := ARRAY['name','event_type','guest_count','budget_max',
                           'budget_currency','end_time','event_municipio','event_estado'];
  BEGIN
    FOREACH v_col IN ARRAY v_cols LOOP
      ASSERT EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = 'public' AND table_name = 'events' AND column_name = v_col
          AND is_nullable = 'YES' AND column_default IS NULL
      ), '[1] Falta la columna events.' || v_col || ' o no es nullable/sin DEFAULT — revisar sql/685';
    END LOOP;

    -- La columna que el trigger set_updated_at_events siempre esperó.
    ASSERT EXISTS (
      SELECT 1 FROM information_schema.columns
      WHERE table_schema = 'public' AND table_name = 'events' AND column_name = 'updated_at'
    ), '[1] Falta events.updated_at — sin ella TODO UPDATE sobre events falla con 42703 (bug preexistente, revisar sql/685)';

    -- Que un UPDATE REAL sobre events pase (el bug en sí) lo prueba [5], que
    -- hace un UPDATE directo a la fila del evento antes de llamar a la RPC.
  END;

  -- ══ [2]+[3] Evento con campos VACÍOS sigue abriendo, con llaves viejas y nuevas ══
  DECLARE
    v_items JSONB;
    v_item  JSONB;
  BEGIN
    INSERT INTO public.events (client_id, event_date, event_time, address, status)
    VALUES (v_client, v_date, '20:00', v_addr, 'active')
    RETURNING id INTO v_event;

    PERFORM set_config('request.jwt.claims', json_build_object('sub', v_client::text, 'role', 'authenticated')::text, true);
    PERFORM set_config('role', 'authenticated', true);
    v_items := public.client_get_my_events();
    RESET role;

    ASSERT (v_items->>'ok')::boolean = true, '[2] client_get_my_events dejó de responder ok: ' || v_items::text;
    SELECT i INTO v_item FROM jsonb_array_elements(v_items->'items') i WHERE (i->>'event_id')::uuid = v_event;
    ASSERT v_item IS NOT NULL, '[2] client_get_my_events ya no devuelve un evento sin datos de Fase 1 — REGRESIÓN GRAVE';

    -- Llaves que la app YA leía antes de sql/685 (no deben desaparecer)
    ASSERT v_item ? 'event_id' AND v_item ? 'event_date' AND v_item ? 'event_time'
       AND v_item ? 'address'  AND v_item ? 'providers',
      '[2] client_get_my_events perdió una llave que la app ya usaba: ' || v_item::text;
    ASSERT jsonb_typeof(v_item->'providers') = 'array', '[2] providers dejó de ser arreglo';

    -- Llaves nuevas: presentes y en NULL (evento sin capturar)
    ASSERT v_item ? 'name' AND v_item ? 'event_type' AND v_item ? 'guest_count'
       AND v_item ? 'budget_max' AND v_item ? 'budget_currency' AND v_item ? 'end_time'
       AND v_item ? 'event_municipio' AND v_item ? 'event_estado' AND v_item ? 'provider_limit',
      '[3] client_get_my_events no manda los campos de Fase 1: ' || v_item::text;
    ASSERT v_item->>'name' IS NULL AND v_item->>'budget_max' IS NULL,
      '[3] un evento sin capturar debería traer los campos nuevos en NULL';
    ASSERT (v_item->>'provider_limit')::int = 20,
      '[3] provider_limit debería ser 20, llegó: ' || COALESCE(v_item->>'provider_limit', 'NULL');
  END;

  -- ══ [4] Fuente de verdad única del límite ════════════════════════════════
  BEGIN
    ASSERT public.max_providers_per_event() = 20,
      '[4] max_providers_per_event() ya no es 20: ' || public.max_providers_per_event()::text;

    -- Ninguna de las 4 capas debe tener el número hardcodeado.
    FOR v_row IN
      SELECT p.proname, p.prosrc FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
      WHERE n.nspname = 'public'
        AND p.proname IN ('enforce_max_groups_per_event','enforce_max_groups_per_shared_event',
                          'resolve_shared_event_id','create_booking_with_event')
    LOOP
      ASSERT v_row.prosrc LIKE '%max_providers_per_event()%',
        '[4] ' || v_row.proname || ' ya no lee max_providers_per_event() — el límite volvió a estar hardcodeado';
      ASSERT v_row.prosrc NOT LIKE '%>= 3%',
        '[4] ' || v_row.proname || ' todavía tiene un ">= 3" literal';
    END LOOP;

    -- Y no deben haberse duplicado por overload (la trampa de sql/585).
    ASSERT (SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
            WHERE n.nspname = 'public' AND p.proname = 'create_booking_with_event') = 1,
      '[4] create_booking_with_event quedó duplicada (overload) — la RPC de la app sería ambigua';
    ASSERT (SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
            WHERE n.nspname = 'public' AND p.proname = 'resolve_shared_event_id') = 1,
      '[4] resolve_shared_event_id quedó duplicada (overload)';
    ASSERT (SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
            WHERE n.nspname = 'public' AND p.proname = 'client_get_my_events') = 1,
      '[4] client_get_my_events quedó duplicada (overload)';
  END;

  -- ══ [5]+[9]+[10] Guardado normal, y lo que NO debe tocar ═════════════════
  DECLARE
    v_before RECORD;
    v_after  RECORD;
  BEGIN
    UPDATE public.events SET total_price = 12345, payment_status = 'unpaid', status = 'active'
    WHERE id = v_event;
    SELECT * INTO v_before FROM public.events WHERE id = v_event;

    PERFORM set_config('request.jwt.claims', json_build_object('sub', v_client::text, 'role', 'authenticated')::text, true);
    PERFORM set_config('role', 'authenticated', true);
    v_res := public.client_update_event_details(
      v_event, '  XV de Sofía  ', 'cumpleanos', 180, 45000, NULL, '02:30', ' Zapopan ', ' Jalisco ');
    RESET role;

    ASSERT (v_res->>'ok')::boolean = true, '[5] client_update_event_details falló en el camino feliz: ' || v_res::text;

    SELECT * INTO v_after FROM public.events WHERE id = v_event;
    ASSERT v_after.name = 'XV de Sofía',            '[5] name no se guardó/trimeó: ' || COALESCE(v_after.name, 'NULL');
    ASSERT v_after.event_type = 'cumpleanos',       '[5] event_type no se guardó';
    ASSERT v_after.guest_count = 180,               '[5] guest_count no se guardó';
    ASSERT v_after.budget_max = 45000,              '[5] budget_max no se guardó';
    ASSERT v_after.end_time = '02:30'::TIME,        '[5] end_time no se guardó';
    ASSERT v_after.event_municipio = 'Zapopan',     '[5] event_municipio no se guardó/trimeó';
    ASSERT v_after.event_estado = 'Jalisco',        '[5] event_estado no se guardó/trimeó';

    -- [10] moneda derivada del país del cliente (profiles.country = 'México')
    ASSERT v_after.budget_currency = 'MXN',
      '[10] la moneda del presupuesto no se derivó del país del cliente: ' || COALESCE(v_after.budget_currency, 'NULL');

    -- [9] nada de lo demás se movió
    ASSERT v_after.status          IS NOT DISTINCT FROM v_before.status,          '[9] la RPC cambió events.status';
    ASSERT v_after.total_price     IS NOT DISTINCT FROM v_before.total_price,     '[9] la RPC cambió events.total_price';
    ASSERT v_after.payment_status  IS NOT DISTINCT FROM v_before.payment_status,  '[9] la RPC cambió events.payment_status';
    ASSERT v_after.payment_intent_id IS NOT DISTINCT FROM v_before.payment_intent_id, '[9] la RPC cambió events.payment_intent_id';
    ASSERT v_after.event_date      IS NOT DISTINCT FROM v_before.event_date,      '[9] la RPC cambió events.event_date';
    ASSERT v_after.event_time      IS NOT DISTINCT FROM v_before.event_time,      '[9] la RPC cambió events.event_time';
    ASSERT v_after.address         IS NOT DISTINCT FROM v_before.address,         '[9] la RPC cambió events.address';
    ASSERT v_after.client_id       IS NOT DISTINCT FROM v_before.client_id,       '[9] la RPC cambió events.client_id';
    -- El trigger set_updated_at_events ya corre sin tronar (antes de sql/685
    -- este mismo UPDATE fallaba con 42703). No se compara "después > antes"
    -- porque NOW() es constante dentro de una transacción: los dos UPDATE de
    -- este bloque escriben exactamente la misma marca de tiempo.
    ASSERT v_after.updated_at IS NOT NULL,
      '[9] events.updated_at quedó NULL — el trigger set_updated_at_events no escribió nada';
  END;

  -- ══ [11] end_time < event_time (evento que cruza medianoche) ══════════════
  BEGIN
    PERFORM set_config('request.jwt.claims', json_build_object('sub', v_client::text, 'role', 'authenticated')::text, true);
    PERFORM set_config('role', 'authenticated', true);
    v_res := public.client_update_event_details(v_event, 'Boda', 'boda', 200, 90000, 'MXN', '03:00', 'Zapopan', 'Jalisco');
    RESET role;
    ASSERT (v_res->>'ok')::boolean = true,
      '[11] un evento que termina después de medianoche debería poder guardarse: ' || v_res::text;
    ASSERT (SELECT end_time FROM public.events WHERE id = v_event) = '03:00'::TIME, '[11] end_time no se guardó';
  END;

  -- ══ [6] Reemplazo completo: NULL vacía el campo ══════════════════════════
  BEGIN
    PERFORM set_config('request.jwt.claims', json_build_object('sub', v_client::text, 'role', 'authenticated')::text, true);
    PERFORM set_config('role', 'authenticated', true);
    v_res := public.client_update_event_details(v_event, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL);
    RESET role;
    ASSERT (v_res->>'ok')::boolean = true, '[6] no se pudo limpiar el formulario: ' || v_res::text;
    SELECT * INTO v_row FROM public.events WHERE id = v_event;
    ASSERT v_row.name IS NULL AND v_row.event_type IS NULL AND v_row.guest_count IS NULL
       AND v_row.budget_max IS NULL AND v_row.budget_currency IS NULL AND v_row.end_time IS NULL
       AND v_row.event_municipio IS NULL AND v_row.event_estado IS NULL,
      '[6] mandar NULL no vació los campos (el cliente no podría borrar un dato)';
    -- Cadena vacía se trata como NULL, no se guarda ''
    PERFORM set_config('request.jwt.claims', json_build_object('sub', v_client::text, 'role', 'authenticated')::text, true);
    PERFORM set_config('role', 'authenticated', true);
    v_res := public.client_update_event_details(v_event, '   ', '', NULL, NULL, NULL, '  ', '', '  ');
    RESET role;
    ASSERT (v_res->>'ok')::boolean = true, '[6] cadenas vacías deberían aceptarse como "sin dato": ' || v_res::text;
    ASSERT (SELECT name IS NULL AND event_type IS NULL AND end_time IS NULL FROM public.events WHERE id = v_event),
      '[6] una cadena vacía se guardó como texto en vez de NULL';
  END;

  -- ══ [7] Dueño / evento inexistente / sin sesión ═══════════════════════════
  BEGIN
    PERFORM set_config('request.jwt.claims', json_build_object('sub', v_owner::text, 'role', 'authenticated')::text, true);
    PERFORM set_config('role', 'authenticated', true);
    v_res := public.client_update_event_details(v_event, 'Robado', NULL, NULL, NULL, NULL, NULL, NULL, NULL);
    RESET role;
    ASSERT v_res->>'error' = 'event_not_owned_by_client',
      '[7] otro usuario pudo editar el evento de un cliente ajeno: ' || v_res::text;
    ASSERT (SELECT name IS NULL FROM public.events WHERE id = v_event), '[7] y además le escribió el nombre';

    PERFORM set_config('request.jwt.claims', json_build_object('sub', v_client::text, 'role', 'authenticated')::text, true);
    PERFORM set_config('role', 'authenticated', true);
    v_res := public.client_update_event_details(gen_random_uuid(), 'X', NULL, NULL, NULL, NULL, NULL, NULL, NULL);
    RESET role;
    ASSERT v_res->>'error' = 'event_not_found', '[7] evento inexistente no dio event_not_found: ' || v_res::text;

    PERFORM set_config('request.jwt.claims', '', true);
    RESET role;
    v_res := public.client_update_event_details(v_event, 'X', NULL, NULL, NULL, NULL, NULL, NULL, NULL);
    ASSERT v_res->>'error' = 'not_authenticated', '[7] sin sesión no dio not_authenticated: ' || v_res::text;
  END;

  -- ══ [8] Validaciones con error limpio ════════════════════════════════════
  BEGIN
    PERFORM set_config('request.jwt.claims', json_build_object('sub', v_client::text, 'role', 'authenticated')::text, true);
    PERFORM set_config('role', 'authenticated', true);

    v_res := public.client_update_event_details(v_event, 'X', 'quinceanera_inventada', NULL, NULL, NULL, NULL, NULL, NULL);
    ASSERT v_res->>'error' = 'invalid_event_type', '[8] tipo inválido no dio invalid_event_type: ' || v_res::text;

    v_res := public.client_update_event_details(v_event, 'X', 'boda', 0, NULL, NULL, NULL, NULL, NULL);
    ASSERT v_res->>'error' = 'invalid_guest_count', '[8] 0 invitados no dio invalid_guest_count: ' || v_res::text;

    v_res := public.client_update_event_details(v_event, 'X', 'boda', 10, -1, NULL, NULL, NULL, NULL);
    ASSERT v_res->>'error' = 'invalid_budget', '[8] presupuesto negativo no dio invalid_budget: ' || v_res::text;

    v_res := public.client_update_event_details(v_event, 'X', 'boda', 10, 100, NULL, 'no soy una hora', NULL, NULL);
    ASSERT v_res->>'error' = 'invalid_end_time', '[8] hora basura no dio invalid_end_time: ' || v_res::text;

    RESET role;
    ASSERT (SELECT name IS NULL FROM public.events WHERE id = v_event),
      '[8] una llamada inválida alcanzó a escribir en la fila';
  END;

  -- ══ [12]+[13]+[14] 20 proveedores caben, el 21 no, misma categoría permitida ══
  DECLARE
    v_g          UUID;
    v_gid        UUID[] := '{}';
    v_i          INT;
    v_blocked    BOOLEAN := false;
    v_distinct   INT;
    v_sum_rows   INT;
  BEGIN
    -- 20 grupos distintos, TODOS del mismo género ("Mariachi") → prueba a la
    -- vez el límite alto y que la misma categoría se repita sin problema.
    FOR v_i IN 1..20 LOOP
      INSERT INTO public.groups (id, owner_id, name, genre, country_id)
      VALUES (gen_random_uuid(), v_owner, 'RT687 Proveedor ' || v_i, 'Mariachi', v_country_mx)
      RETURNING id INTO v_g;
      v_gid := v_gid || v_g;

      INSERT INTO public.reservations (id, client_id, group_id, event_id, event_date, event_time,
                                       address, total_price, base_price, status, hours_count)
      VALUES (gen_random_uuid(), v_client, v_g, v_event, v_date, '20:00',
              v_addr, 1000 * v_i, 900 * v_i, 'confirmed', 3);
    END LOOP;

    SELECT COUNT(DISTINCT group_id) INTO v_distinct
    FROM public.reservations WHERE event_id = v_event AND status = ANY (public.estados_que_ocupan());
    ASSERT v_distinct = 20,
      '[12] no entraron los 20 proveedores al mismo evento, solo ' || v_distinct::text || ' — revisar sql/686';

    -- [13] los 20 son de la MISMA categoría y ninguno fue rechazado por eso
    ASSERT (SELECT count(DISTINCT genre) FROM public.groups WHERE id = ANY (v_gid)) = 1,
      '[13] el escenario de prueba no quedó con una sola categoría';

    -- [14] cada reserva conservó SU grupo, SU precio y SU estado — nada se unió
    SELECT count(*) INTO v_sum_rows FROM public.reservations
    WHERE event_id = v_event AND total_price = 1000 * 7 AND group_id = v_gid[7];
    ASSERT v_sum_rows = 1,
      '[14] la reserva del proveedor 7 perdió su precio o su grupo propio — las reservas dejaron de ser independientes';
    ASSERT (SELECT count(DISTINCT total_price) FROM public.reservations WHERE event_id = v_event) = 20,
      '[14] los precios de las 20 reservas se mezclaron/igualaron';

    -- El 21 debe ser rechazado por el trigger, con el código que la app traduce
    INSERT INTO public.groups (id, owner_id, name, genre, country_id)
    VALUES (gen_random_uuid(), v_owner, 'RT687 Proveedor 21', 'Mariachi', v_country_mx)
    RETURNING id INTO v_g;
    BEGIN
      INSERT INTO public.reservations (id, client_id, group_id, event_id, event_date, event_time,
                                       address, total_price, status, hours_count)
      VALUES (gen_random_uuid(), v_client, v_g, v_event, v_date, '20:00', v_addr, 999, 'confirmed', 3);
    EXCEPTION WHEN OTHERS THEN
      v_blocked := SQLERRM LIKE 'event_group_limit_reached%';
      IF NOT v_blocked THEN
        RAISE EXCEPTION '[12] el proveedor 21 fue rechazado, pero con un error distinto al esperado: %', SQLERRM;
      END IF;
    END;
    ASSERT v_blocked, '[12] el proveedor 21 SÍ entró — el límite de 20 no está actuando';

    -- Y la RPC de pre-chequeo debe dar el mismo veredicto, limpio
    BEGIN
      PERFORM public.resolve_shared_event_id(v_client, v_event, v_date, '20:00', v_addr);
      RAISE EXCEPTION '[12] resolve_shared_event_id dejó pasar un evento ya lleno (20 proveedores)';
    EXCEPTION WHEN OTHERS THEN
      IF SQLERRM NOT LIKE '%event_group_limit_reached%' THEN
        RAISE EXCEPTION '[12] resolve_shared_event_id dio un error inesperado con el evento lleno: %', SQLERRM;
      END IF;
    END;
  END;

  -- ══ [17] resolve_shared_event_id: ajeno e inexistente siguen rechazados ═══
  DECLARE
    v_ev_otro UUID;
  BEGIN
    INSERT INTO public.events (client_id, event_date, event_time, address, status)
    VALUES (v_owner, v_date, '18:00', 'RT687 Otro dueño', 'active') RETURNING id INTO v_ev_otro;

    BEGIN
      PERFORM public.resolve_shared_event_id(v_client, v_ev_otro, v_date, '18:00', 'RT687 Otro dueño');
      RAISE EXCEPTION '[17] resolve_shared_event_id dejó a un cliente colgarse de un evento ajeno';
    EXCEPTION WHEN OTHERS THEN
      IF SQLERRM NOT LIKE '%event_not_owned_by_client%' THEN
        RAISE EXCEPTION '[17] error inesperado con evento ajeno: %', SQLERRM;
      END IF;
    END;

    BEGIN
      PERFORM public.resolve_shared_event_id(v_client, gen_random_uuid(), v_date, '18:00', 'X');
      RAISE EXCEPTION '[17] resolve_shared_event_id aceptó un event_id inexistente';
    EXCEPTION WHEN OTHERS THEN
      IF SQLERRM NOT LIKE '%event_not_found%' THEN
        RAISE EXCEPTION '[17] error inesperado con evento inexistente: %', SQLERRM;
      END IF;
    END;
  END;

  -- ══ [15]+[16] Contratación normal de 1 proveedor, y reutilizando evento ═══
  DECLARE
    v_g15   UUID;
    v_g16   UUID;
    v_date2 DATE := CURRENT_DATE + 211;   -- fecha/dirección propias: este bloque
    v_addr2 TEXT := 'RT687 Jardín Solo 1'; -- no debe tocar el evento lleno de [12]
    v_ev15  UUID;
  BEGIN
    INSERT INTO public.groups (id, owner_id, name, genre, country_id)
    VALUES (gen_random_uuid(), v_owner, 'RT687 Solito', 'Banda', v_country_mx) RETURNING id INTO v_g15;
    INSERT INTO public.groups (id, owner_id, name, genre, country_id)
    VALUES (gen_random_uuid(), v_owner, 'RT687 Segundo', 'DJ', v_country_mx) RETURNING id INTO v_g16;

    PERFORM set_config('request.jwt.claims', json_build_object('sub', v_client::text, 'role', 'authenticated')::text, true);
    PERFORM set_config('role', 'authenticated', true);
    v_res := public.create_booking_with_event(
      v_client, v_g15, NULL, v_date2, '19:00', v_addr2, 5000,
      NULL, NULL, 4500, NULL, NULL, NULL, 'full', NULL);
    RESET role;

    ASSERT v_res ? 'reservation_id' AND v_res ? 'event_id',
      '[15] la contratación normal de un solo proveedor dejó de funcionar: ' || v_res::text;
    v_ev15 := (v_res->>'event_id')::UUID;
    ASSERT v_ev15 IS NOT NULL, '[15] no se creó/resolvió event_id en una contratación normal';
    ASSERT (SELECT status FROM public.reservations WHERE id = (v_res->>'reservation_id')::UUID) = 'pending_payment',
      '[15] la reserva nueva ya no nace en pending_payment — cambió el flujo de pago';
    ASSERT (SELECT client_id FROM public.events WHERE id = v_ev15) = v_client,
      '[15] el evento creado no quedó a nombre del cliente';

    -- [16] segundo proveedor, mandando el event_id del primero → mismo evento
    PERFORM set_config('request.jwt.claims', json_build_object('sub', v_client::text, 'role', 'authenticated')::text, true);
    PERFORM set_config('role', 'authenticated', true);
    v_res := public.create_booking_with_event(
      v_client, v_g16, NULL, v_date2, '19:00', v_addr2, 7000,
      NULL, NULL, 6300, NULL, NULL, NULL, 'full', v_ev15);
    RESET role;

    ASSERT (v_res->>'event_id')::UUID = v_ev15,
      '[16] create_booking_with_event creó un evento nuevo en vez de reutilizar el que se le pasó: ' || v_res::text;
    ASSERT (SELECT COUNT(DISTINCT group_id) FROM public.reservations WHERE event_id = v_ev15) = 2,
      '[16] el evento no quedó con los 2 proveedores';
    -- [14] otra vez: 2 reservas, 2 precios, ningún pago unido
    ASSERT (SELECT count(DISTINCT total_price) FROM public.reservations WHERE event_id = v_ev15) = 2,
      '[14] los 2 proveedores del mismo evento comparten precio — se unieron los cobros';
  END;

  -- ══ [18] Aceptar cotización sigue creando/reutilizando event_id ═══════════
  DECLARE
    v_g18   UUID;
    v_q18   UUID;
    v_date3 DATE := CURRENT_DATE + 212;
    v_ev18  UUID;
  BEGIN
    INSERT INTO public.groups (id, owner_id, name, genre, country_id)
    VALUES (gen_random_uuid(), v_owner, 'RT687 Cotizador', 'Banda', v_country_mx) RETURNING id INTO v_g18;

    INSERT INTO public.events (client_id, event_date, event_time, address, status)
    VALUES (v_client, v_date3, '21:00', 'RT687 Quinta Cotiza', 'active') RETURNING id INTO v_ev18;

    -- venue_covered, venue_size y needs_sound son NOT NULL en quotes (valores
    -- tomados de los CHECK reales de la tabla, no inventados).
    INSERT INTO public.quotes (id, group_id, client_id, event_type, event_address, event_municipio,
                               event_estado, event_date, event_time, duration_hours, status,
                               venue_covered, venue_size, needs_sound,
                               base_price, total_amount, event_id, num_personas)
    VALUES (gen_random_uuid(), v_g18, v_client, 'boda', 'RT687 Quinta Cotiza', 'Zapopan',
            'Jalisco', v_date3, '21:00', 4, 'quoted',
            'si', 'salon_mediano', 'no',
            10000, 12000, v_ev18, 120)
    RETURNING id INTO v_q18;

    PERFORM set_config('request.jwt.claims', json_build_object('sub', v_client::text, 'role', 'authenticated')::text, true);
    PERFORM set_config('role', 'authenticated', true);
    v_res := public.client_accept_quote(v_q18, NULL, NULL);
    RESET role;

    ASSERT (v_res->>'ok')::boolean = true, '[18] aceptar una cotización dejó de funcionar: ' || v_res::text;
    ASSERT (v_res->>'event_id')::UUID = v_ev18,
      '[18] al aceptar, la cotización no se quedó en el evento que YA tenía (bug que corrigió sql/593): ' || v_res::text;
    ASSERT (SELECT status FROM public.quotes WHERE id = v_q18) = 'accepted', '[18] la cotización no quedó accepted';
    ASSERT (SELECT event_id FROM public.reservations WHERE quote_id = v_q18) = v_ev18,
      '[18] la reserva creada no quedó ligada al evento';
  END;

  -- ══ [18b] Cotización legacy SIN event_id sigue creando su propio evento ═══
  DECLARE
    v_g19   UUID;
    v_q19   UUID;
    v_res19 JSONB;
  BEGIN
    INSERT INTO public.groups (id, owner_id, name, genre, country_id)
    VALUES (gen_random_uuid(), v_owner, 'RT687 Cotizador Legacy', 'DJ', v_country_mx) RETURNING id INTO v_g19;

    INSERT INTO public.quotes (id, group_id, client_id, event_type, event_address, event_municipio,
                               event_estado, event_date, event_time, duration_hours, status,
                               venue_covered, venue_size, needs_sound,
                               base_price, total_amount, event_id, num_personas)
    VALUES (gen_random_uuid(), v_g19, v_client, 'boda', 'RT687 Quinta Legacy', 'Zapopan',
            'Jalisco', CURRENT_DATE + 213, '21:00', 4, 'quoted', 'si', 'salon_mediano', 'no',
            8000, 9600, NULL, 90)
    RETURNING id INTO v_q19;

    PERFORM set_config('request.jwt.claims', json_build_object('sub', v_client::text, 'role', 'authenticated')::text, true);
    PERFORM set_config('role', 'authenticated', true);
    v_res19 := public.client_accept_quote(v_q19, NULL, NULL);
    RESET role;

    ASSERT (v_res19->>'ok')::boolean = true, '[18b] aceptar una cotización legacy (sin event_id) falló: ' || v_res19::text;
    ASSERT (v_res19->>'event_id') IS NOT NULL,
      '[18b] una cotización legacy debería crear su propio evento nuevo: ' || v_res19::text;
  END;

  RAISE EXCEPTION 'TEST_REPORT sql/687: TODO PASÓ (19/19) — columnas nuevas nullable sin default; eventos viejos con campos vacíos siguen abriendo y client_get_my_events conserva todas sus llaves anteriores; campos de Fase 1 + provider_limit=20 viajan a la app; max_providers_per_event() es la única fuente de verdad y las 4 capas la leen sin overloads; guardado/limpieza/trim correctos; moneda derivada del país; evento que cruza medianoche permitido; dueño ajeno, evento inexistente y sin sesión rechazados sin escribir; tipo/invitados/presupuesto/hora inválidos con error limpio; la RPC nunca toca status/total_price/payment_status/payment_intent_id/fecha/hora/dirección; 20 proveedores de la MISMA categoría caben en un evento y el 21 se rechaza con event_group_limit_reached (trigger y pre-chequeo); cada reserva conserva grupo/precio propios; contratación de un solo proveedor intacta (nace en pending_payment); p_event_id reutiliza el evento; aceptar cotización sigue respetando el event_id que ya tenía';
END;
$suite$;

ROLLBACK;
