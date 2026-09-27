-- ═══════════════════════════════════════════════════════════════════════════
-- sql/691 — SUITE DE PRUEBAS de sql/690 (client_create_event)
-- ═══════════════════════════════════════════════════════════════════════════
--
-- NO APLICA NADA. Solo prueba. 100% seguro de correr en cualquier momento: todo
-- va dentro de BEGIN...ROLLBACK y termina en RAISE EXCEPTION, así que ni una
-- fila queda en la base real.
--
-- Requiere sql/685, sql/690 aplicados. Mismo patrón que sql/602/687: reusa
-- cuentas reales solo como FK válidas dentro de la transacción revertida.
--
-- CUBRE:
--   [1]  Sin sesión → not_authenticated, sin crear nada.
--   [2]  Camino feliz completo: crea el evento con los 8 campos + fecha/hora/
--        dirección, a nombre de auth.uid(), status 'active'.
--   [3]  Solo lo obligatorio (fecha+hora+dirección): crea con el resto en NULL.
--   [4]  Obligatorios faltantes → missing_event_date / missing_address /
--        missing_event_time, sin crear nada.
--   [5]  Validaciones: tipo, invitados, presupuesto, horas inválidas.
--   [6]  Moneda derivada del país del cliente; y respeta la que manda la app.
--   [7]  Presupuesto vacío NO arrastra moneda.
--   [8]  Trim de espacios en nombre/dirección/municipio/estado.
--   [9]  NO escribe total_price / payment_status / payment_intent_id.
--   [10] Guarda de duplicados: segundo llamado con misma fecha+dirección
--        reutiliza el evento VACÍO (reused=true) y no crea otra fila.
--   [11] Un evento que YA tiene cotización o reserva NUNCA se reutiliza: se
--        crea uno nuevo.
--   [12] No crea reservaciones ni cotizaciones.
--   [13] Hora de fin después de medianoche permitida.
--   [14] Sin overloads de la función.
-- ═══════════════════════════════════════════════════════════════════════════

BEGIN;

DO $suite$
DECLARE
  v_client   UUID := '889e7168-a30a-49c5-a32a-cbeb320d00f8'; -- Lala, real (solo FK)
  v_owner    UUID := '929ba9ba-1dfd-4b76-abf1-18168b1ac1ba'; -- dueño real (solo FK)
  v_mx       UUID;
  v_date     DATE := CURRENT_DATE + 400;
  v_addr     TEXT := 'RT691 Quinta de Pruebas 99';
  v_res      JSONB;
  v_ev       UUID;
  v_row      RECORD;
  v_n        INT;
  v_res_total INT;
  v_quo_total INT;
BEGIN
  SELECT id INTO v_mx FROM public.countries WHERE currency_code='MXN' LIMIT 1;
  SELECT count(*) INTO v_res_total FROM public.reservations;
  SELECT count(*) INTO v_quo_total FROM public.quotes;

  -- ══ [1] Sin sesión ════════════════════════════════════════════════════════
  PERFORM set_config('request.jwt.claims', '', true);
  RESET role;
  v_res := public.client_create_event(v_date, '20:00', v_addr);
  ASSERT v_res->>'error' = 'not_authenticated', '[1] sin sesión: ' || v_res::text;
  ASSERT NOT EXISTS (SELECT 1 FROM public.events WHERE address = v_addr), '[1] creó un evento sin sesión';

  -- Desde aquí, sesión del cliente real
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_client::text, 'role','authenticated')::text, true);
  PERFORM set_config('role','authenticated', true);

  -- ══ [2] Camino feliz completo ═════════════════════════════════════════════
  v_res := public.client_create_event(
    v_date, '20:00', '  ' || v_addr || '  ',
    '  XV de Sofía  ', 'cumpleanos', ' Zapopan ', ' Jalisco ', 180, 45000, NULL, '02:30');
  ASSERT (v_res->>'ok')::boolean, '[2] camino feliz falló: ' || v_res::text;
  ASSERT (v_res->>'reused')::boolean = false, '[2] no debería reutilizar en el primer evento';
  v_ev := (v_res->>'event_id')::UUID;
  ASSERT v_ev IS NOT NULL, '[2] sin event_id';

  SELECT * INTO v_row FROM public.events WHERE id = v_ev;
  ASSERT v_row.client_id      = v_client,        '[2] client_id no salió de auth.uid()';
  ASSERT v_row.status         = 'active',        '[2] status no es active: ' || COALESCE(v_row.status,'NULL');
  ASSERT v_row.event_date     = v_date,          '[2] event_date';
  ASSERT v_row.event_time     = '20:00'::TIME,   '[2] event_time';
  ASSERT v_row.address        = v_addr,          '[8] address no se trimeó: ' || quote_literal(v_row.address);
  ASSERT v_row.name           = 'XV de Sofía',   '[8] name no se trimeó: ' || quote_literal(COALESCE(v_row.name,'NULL'));
  ASSERT v_row.event_type     = 'cumpleanos',    '[2] event_type';
  ASSERT v_row.guest_count    = 180,             '[2] guest_count';
  ASSERT v_row.budget_max     = 45000,           '[2] budget_max';
  ASSERT v_row.end_time       = '02:30'::TIME,   '[13] end_time después de medianoche';
  ASSERT v_row.event_municipio = 'Zapopan',      '[8] municipio no se trimeó';
  ASSERT v_row.event_estado    = 'Jalisco',      '[8] estado no se trimeó';
  ASSERT v_row.budget_currency = 'MXN',          '[6] moneda no se derivó del país: ' || COALESCE(v_row.budget_currency,'NULL');

  -- ══ [9] NO escribe nada financiero ════════════════════════════════════════
  ASSERT COALESCE(v_row.total_price, 0) = 0,         '[9] escribió events.total_price';
  ASSERT v_row.payment_status IS NULL
      OR v_row.payment_status = 'unpaid',             '[9] escribió payment_status: ' || COALESCE(v_row.payment_status,'NULL');
  ASSERT v_row.payment_intent_id IS NULL,             '[9] escribió payment_intent_id';

  -- ══ [10] Guarda de duplicados sobre un evento VACÍO ═══════════════════════
  v_res := public.client_create_event(v_date, '21:00', v_addr, 'Otro nombre', 'boda', 'Zapopan', 'Jalisco', 200, 50000, NULL, NULL);
  ASSERT (v_res->>'ok')::boolean, '[10] segundo llamado falló: ' || v_res::text;
  ASSERT (v_res->>'reused')::boolean = true, '[10] debería haber reutilizado el evento vacío';
  ASSERT (v_res->>'event_id')::UUID = v_ev, '[10] reutilizó otro evento distinto';
  SELECT count(*) INTO v_n FROM public.events WHERE client_id = v_client AND address = v_addr;
  ASSERT v_n = 1, '[10] quedaron ' || v_n::text || ' eventos con la misma dirección (esperado 1)';
  -- y los datos nuevos sí se guardaron sobre la misma fila
  SELECT * INTO v_row FROM public.events WHERE id = v_ev;
  ASSERT v_row.name = 'Otro nombre' AND v_row.event_time = '21:00'::TIME AND v_row.guest_count = 200,
    '[10] al reutilizar no actualizó los datos';
  ASSERT v_row.end_time IS NULL, '[10] al reutilizar no limpió end_time';

  -- ══ [11] Un evento CON cotización nunca se reutiliza ══════════════════════
  DECLARE
    v_g   UUID;
    v_ev2 UUID;
  BEGIN
    -- Los datos de apoyo se insertan SIN el rol authenticated puesto: la RLS de
    -- `groups` no deja que un cliente cree grupos (correcto). Se suelta el rol,
    -- se siembra, y despues se vuelve a impersonar para llamar la RPC.
    RESET role;
    INSERT INTO public.groups (id, owner_id, name, genre, country_id)
    VALUES (gen_random_uuid(), v_owner, 'RT691 Grupo', 'Norteño', v_mx) RETURNING id INTO v_g;
    INSERT INTO public.quotes (id, group_id, client_id, event_type, event_address, event_municipio,
                               event_estado, event_date, event_time, duration_hours, status,
                               venue_covered, venue_size, needs_sound,
                               base_price, total_amount, event_id, num_personas)
    VALUES (gen_random_uuid(), v_g, v_client, 'boda', v_addr, 'Zapopan', 'Jalisco',
            v_date, '21:00', 4, 'quoted', 'si', 'salon_mediano', 'no', 1000, 1200, v_ev, 50);

    PERFORM set_config('request.jwt.claims', json_build_object('sub', v_client::text, 'role','authenticated')::text, true);
    PERFORM set_config('role','authenticated', true);
    v_res := public.client_create_event(v_date, '22:00', v_addr, 'Tercero');
    ASSERT (v_res->>'reused')::boolean = false,
      '[11] reutilizó un evento que YA tiene cotización';
    v_ev2 := (v_res->>'event_id')::UUID;
    ASSERT v_ev2 <> v_ev, '[11] devolvió el mismo evento';
    SELECT count(*) INTO v_n FROM public.events WHERE client_id = v_client AND address = v_addr;
    ASSERT v_n = 2, '[11] esperaba 2 eventos, hay ' || v_n::text;
  END;

  -- ══ [3] Solo lo obligatorio ═══════════════════════════════════════════════
  DECLARE v_ev3 UUID;
  BEGIN
    v_res := public.client_create_event(CURRENT_DATE + 401, '19:00', 'RT691 Solo lo minimo');
    ASSERT (v_res->>'ok')::boolean, '[3] mínimo falló: ' || v_res::text;
    v_ev3 := (v_res->>'event_id')::UUID;
    SELECT * INTO v_row FROM public.events WHERE id = v_ev3;
    ASSERT v_row.name IS NULL AND v_row.event_type IS NULL AND v_row.guest_count IS NULL
       AND v_row.budget_max IS NULL AND v_row.budget_currency IS NULL AND v_row.end_time IS NULL
       AND v_row.event_municipio IS NULL AND v_row.event_estado IS NULL,
      '[3] los opcionales deberían quedar en NULL';
    ASSERT v_row.status = 'active', '[3] status';
  END;

  -- ══ [7] Presupuesto vacío no arrastra moneda ══════════════════════════════
  v_res := public.client_create_event(CURRENT_DATE + 402, '19:00', 'RT691 Sin presupuesto', NULL, NULL, NULL, NULL, 50, NULL, 'USD', NULL);
  ASSERT (v_res->>'ok')::boolean, '[7] falló: ' || v_res::text;
  ASSERT (v_res->>'budget_currency') IS NULL,
    '[7] sin monto no debería guardar moneda, llegó: ' || COALESCE(v_res->>'budget_currency','NULL');

  -- ══ [6b] Respeta la moneda que manda la app ═══════════════════════════════
  v_res := public.client_create_event(CURRENT_DATE + 403, '19:00', 'RT691 En dolares', NULL, NULL, NULL, NULL, NULL, 900, 'usd', NULL);
  ASSERT (v_res->>'budget_currency') = 'USD',
    '[6b] debería respetar y normalizar a USD, llegó: ' || COALESCE(v_res->>'budget_currency','NULL');

  -- ══ [4] Obligatorios faltantes ════════════════════════════════════════════
  SELECT count(*) INTO v_n FROM public.events WHERE client_id = v_client;
  v_res := public.client_create_event(NULL, '20:00', 'RT691 X');
  ASSERT v_res->>'error' = 'missing_event_date', '[4] fecha: ' || v_res::text;
  v_res := public.client_create_event(CURRENT_DATE + 404, '20:00', '   ');
  ASSERT v_res->>'error' = 'missing_address', '[4] dirección: ' || v_res::text;
  v_res := public.client_create_event(CURRENT_DATE + 404, NULL, 'RT691 Y');
  ASSERT v_res->>'error' = 'missing_event_time', '[4] hora: ' || v_res::text;
  ASSERT (SELECT count(*) FROM public.events WHERE client_id = v_client) = v_n,
    '[4] una llamada inválida alcanzó a crear un evento';

  -- ══ [5] Validaciones de contenido ═════════════════════════════════════════
  v_res := public.client_create_event(CURRENT_DATE + 405, '20:00', 'RT691 Z', NULL, 'quinceanera_inventada');
  ASSERT v_res->>'error' = 'invalid_event_type',  '[5] tipo: ' || v_res::text;
  v_res := public.client_create_event(CURRENT_DATE + 405, '20:00', 'RT691 Z', NULL, 'boda', NULL, NULL, 0);
  ASSERT v_res->>'error' = 'invalid_guest_count', '[5] invitados: ' || v_res::text;
  v_res := public.client_create_event(CURRENT_DATE + 405, '20:00', 'RT691 Z', NULL, 'boda', NULL, NULL, 10, -5);
  ASSERT v_res->>'error' = 'invalid_budget',      '[5] presupuesto: ' || v_res::text;
  v_res := public.client_create_event(CURRENT_DATE + 405, 'no soy hora', 'RT691 Z');
  ASSERT v_res->>'error' = 'invalid_event_time',  '[5] hora basura: ' || v_res::text;
  v_res := public.client_create_event(CURRENT_DATE + 405, '20:00', 'RT691 Z', NULL, NULL, NULL, NULL, NULL, NULL, NULL, 'tampoco');
  ASSERT v_res->>'error' = 'invalid_end_time',    '[5] hora fin basura: ' || v_res::text;

  -- ══ [12] No creó reservaciones ni cotizaciones (más allá de la del test) ══
  -- RESET role ANTES de contar: los conteos iniciales se tomaron como
  -- superusuario, y bajo RLS el cliente solo ve SUS propias filas — comparar
  -- conteos tomados con privilegios distintos da un falso positivo.
  RESET role;
  ASSERT (SELECT count(*) FROM public.reservations) = v_res_total,
    '[12] client_create_event creó reservaciones';
  ASSERT (SELECT count(*) FROM public.quotes) = v_quo_total + 1,
    '[12] cambió el número de cotizaciones más allá de la que inserta el propio test';

  -- ══ [14] Sin overloads ════════════════════════════════════════════════════
  SELECT count(*) INTO v_n FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname='public' AND p.proname='client_create_event';
  ASSERT v_n = 1, '[14] client_create_event quedó duplicada (overload): ' || v_n::text;

  RAISE EXCEPTION 'TEST_REPORT sql/691: TODO PASÓ (14/14) — sin sesión rechazada; camino feliz completo con client_id de auth.uid() y status active; solo-obligatorios crea con opcionales en NULL; faltantes y valores inválidos rechazados sin crear nada; moneda derivada del país y respetada/normalizada cuando la manda la app; presupuesto vacío no arrastra moneda; trim en nombre/dirección/municipio/estado; NO escribe total_price/payment_status/payment_intent_id; la guarda de duplicados reutiliza el evento VACÍO y actualiza sus datos; un evento con cotización NUNCA se reutiliza; no crea reservaciones; hora de fin tras medianoche permitida; sin overloads';
END
$suite$;

ROLLBACK;
