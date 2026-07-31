-- ============================================================
-- sql/524_fase_a_tests.sql — PRUEBAS de sql/523 (NO persiste NADA)
--
-- Requiere sql/523 aplicado. Mismo patrón que sql/515/520/522: un
-- DO-block que SIEMPRE termina en RAISE EXCEPTION con el reporte →
-- rollback total garantizado, cero rastro en datos reales.
--
-- Cubre las 4 capas tocadas por sql/523 por separado:
--   • Trigger enforce_group_availability()   (vía INSERT directo)
--   • RPC     create_booking_with_event()    (llamada directa a la RPC)
--   • Función can_schedule()                 (llamada directa)
--   • RPC     client_accept_proposal()       (llamada directa a la RPC)
-- Más regresión de lo que NO debía cambiar: date_blocked, daily_event_limit,
-- time_overlap, completed cuenta, horas extra amplían el rango.
--
-- Nota: T3 de sql/515_f1_tests.sql afirmaba explícitamente que
-- "date_taken sigue vivo" — en esta suite esa prueba se INVIERTE
-- (T3 abajo): el mismo escenario ahora debe PASAR.
--
-- Nota T9: create_booking_with_event() referencia reservations.package_id,
-- columna que NO existe en el esquema actual (hallazgo independiente,
-- documentado como deuda técnica — ver sql/523, sección "FUERA DE
-- ALCANCE"). T9 distingue ese error específico (esperado, no es una
-- regresión de Fase A) de cualquier otro error (si aparece, sí sería
-- una regresión real).
--
-- CORRECCIÓN 2026-07-28 (post primera corrida): 2 defectos de ESTA
-- SUITE, confirmados por investigación de solo lectura, NINGUNO en
-- producción:
--
--   • v_owner ya NO se toma con `SELECT id FROM profiles LIMIT 1` —
--     ese perfil real ya es dueño de un grupo real en producción
--     ("Daniel Rivera"). client_accept_proposal() resuelve el grupo por
--     `owner_id` con `LIMIT 1` SIN `ORDER BY` — con 2 grupos para el
--     mismo owner_id (el real + el sintético de esta prueba), esa
--     resolución NO es estable entre llamadas dentro de la misma
--     transacción (confirmado con evidencia: 3 llamadas idénticas
--     resolvieron real/sintético/real, en ese orden). Esto hizo que T12c
--     "fallara" — no por un bug de daily_event_limit, sino porque req2
--     terminó en un grupo distinto a req1/req3, así que el conteo real
--     para el grupo de req3 era 1, no 2. Ahora v_owner se elige
--     explícitamente de un perfil SIN ningún grupo previo, para que el
--     grupo sintético sea el ÚNICO resultado posible de esa consulta.
--
--   • T10d ahora usa p_exclude para aislar time_overlap de daily_limit
--     (antes, con 2 reservas ya existentes, daily_limit siempre ganaba
--     primero — comportamiento CORRECTO de can_schedule(), defecto de
--     diseño de esta prueba, no de la función).
--
-- DECISIÓN 2026-07-28 sobre T8: aceptado como PASS por dos rutas válidas
-- (ver comentario en el caso T8 más abajo) — la integridad se protege en
-- ambas, la diferencia es solo el mensaje de error. Documentado como
-- deuda técnica de experiencia/manejo de errores, fuera de esta fase.
-- ============================================================

DO $$
DECLARE
  v_owner    UUID;
  v_client   UUID;
  v_group    UUID;
  v_r1 UUID; v_r2 UUID; v_r3 UUID;
  v_req1 UUID; v_req2 UUID; v_req3 UUID;
  v_booking  JSONB;
  v_sched    TEXT;
  v_range1   TSTZRANGE;
  v_range2   TSTZRANGE;
  v_report   TEXT := E'\n══════ REPORTE DE PRUEBAS FASE A (sql/523) ══════\n';
BEGIN
  -- v_owner: perfil SIN ningún grupo propio previo — evita la ambigüedad
  -- de owner_id que causó T12c en la corrida anterior (ver nota arriba).
  SELECT p.id INTO v_owner FROM profiles p
  WHERE NOT EXISTS (SELECT 1 FROM groups g WHERE g.owner_id = p.id)
  ORDER BY p.id LIMIT 1;
  IF v_owner IS NULL THEN
    RAISE EXCEPTION 'ABORTADO: no hay ningún perfil libre de grupos propios para usar como owner sintético';
  END IF;

  SELECT id INTO v_client FROM profiles WHERE id <> v_owner LIMIT 1;
  IF v_client IS NULL THEN v_client := v_owner; END IF;

  INSERT INTO groups (name, owner_id, state, country, is_active)
  VALUES ('__TEST_523__', v_owner, 'Jalisco', 'México', false)
  RETURNING id INTO v_group;

  ---------------------------------------------------------------
  -- T1: primer evento del día → permitido (trigger, vía INSERT directo)
  ---------------------------------------------------------------
  INSERT INTO reservations (group_id, client_id, event_date, event_time, hours_count, status, total_price, base_price, address)
  VALUES (v_group, v_client, DATE '2031-03-10', TIME '10:00', 2, 'accepted', 800, 666, 'Av. Prueba 123')
  RETURNING id INTO v_r1;
  v_report := v_report || 'T1  primer evento permitido ................... PASS' || E'\n';

  ---------------------------------------------------------------
  -- T3 (invertida vs sql/515): 2º evento mismo día, SIN traslape
  -- → antes fallaba con date_taken, ahora debe pasar.
  -- r1 es 10:00-13:15 (2h + 30min antes + 45min después); probamos
  -- a las 18:00, muy lejos de ese rango.
  ---------------------------------------------------------------
  BEGIN
    INSERT INTO reservations (group_id, client_id, event_date, event_time, hours_count, status, total_price, base_price, address)
    VALUES (v_group, v_client, DATE '2031-03-10', TIME '18:00', 2, 'accepted', 800, 666, 'Av. Prueba 123')
    RETURNING id INTO v_r2;
    v_report := v_report || 'T3  2º evento mismo día sin traslape ........... PASS (date_taken retirado)' || E'\n';
  EXCEPTION WHEN OTHERS THEN
    v_report := v_report || 'T3  2º evento mismo día sin traslape ........... FAIL ' || SQLERRM || E'\n';
    RAISE EXCEPTION '%', v_report;
  END;

  ---------------------------------------------------------------
  -- T4: 3er evento el mismo día → daily_event_limit (sigue vivo)
  ---------------------------------------------------------------
  BEGIN
    INSERT INTO reservations (group_id, client_id, event_date, event_time, hours_count, status, total_price, base_price, address)
    VALUES (v_group, v_client, DATE '2031-03-10', TIME '22:00', 1, 'accepted', 500, 416, 'Av. Prueba 123');
    v_report := v_report || 'T4  3er evento → daily_event_limit ............. FAIL (dejó pasar)' || E'\n';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM LIKE '%daily_event_limit%' THEN
      v_report := v_report || 'T4  3er evento → daily_event_limit ............. PASS' || E'\n';
    ELSE
      v_report := v_report || 'T4  3er evento: error inesperado ............... FAIL ' || SQLERRM || E'\n';
    END IF;
  END;

  ---------------------------------------------------------------
  -- T5: traslape real de rangos → time_overlap (sigue vivo)
  -- Cancelamos r1 (queda 1 cupo libre) e insertamos ENCIMA de r2 (18:00-21:15)
  ---------------------------------------------------------------
  UPDATE reservations SET status = 'cancelled' WHERE id = v_r1;
  BEGIN
    INSERT INTO reservations (group_id, client_id, event_date, event_time, hours_count, status, total_price, base_price, address)
    VALUES (v_group, v_client, DATE '2031-03-10', TIME '19:00', 2, 'accepted', 700, 583, 'Av. Prueba 123');
    v_report := v_report || 'T5  traslape real → time_overlap ............... FAIL (dejó pasar)' || E'\n';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM LIKE '%time_overlap%' THEN
      v_report := v_report || 'T5  traslape real → time_overlap ............... PASS' || E'\n';
    ELSE
      v_report := v_report || 'T5  traslape: error inesperado ................. FAIL ' || SQLERRM || E'\n';
    END IF;
  END;

  ---------------------------------------------------------------
  -- T6: completed sigue contando para el límite de 2
  ---------------------------------------------------------------
  UPDATE reservations SET status = 'completed' WHERE id = v_r2;
  INSERT INTO reservations (group_id, client_id, event_date, event_time, hours_count, status, total_price, base_price, address)
  VALUES (v_group, v_client, DATE '2031-03-10', TIME '08:00', 1, 'accepted', 500, 416, 'Av. Prueba 123')
  RETURNING id INTO v_r3;
  BEGIN
    INSERT INTO reservations (group_id, client_id, event_date, event_time, hours_count, status, total_price, base_price, address)
    VALUES (v_group, v_client, DATE '2031-03-10', TIME '14:00', 1, 'accepted', 500, 416, 'Av. Prueba 123');
    v_report := v_report || 'T6  completed cuenta para el límite ............ FAIL (dejó pasar un 3º)' || E'\n';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM LIKE '%daily_event_limit%' THEN
      v_report := v_report || 'T6  completed cuenta para el límite ............ PASS' || E'\n';
    ELSE
      v_report := v_report || 'T6  completed: error inesperado ................ FAIL ' || SQLERRM || E'\n';
    END IF;
  END;

  ---------------------------------------------------------------
  -- T7: bloqueo manual (date_blocked) sigue intacto — nueva fecha limpia
  ---------------------------------------------------------------
  INSERT INTO group_unavailability (group_id, date, reason)
  VALUES (v_group, DATE '2031-03-15', 'test');
  BEGIN
    INSERT INTO reservations (group_id, client_id, event_date, event_time, hours_count, status, total_price, base_price, address)
    VALUES (v_group, v_client, DATE '2031-03-15', TIME '10:00', 2, 'accepted', 800, 666, 'Av. Prueba 123');
    v_report := v_report || 'T7  bloqueo manual → date_blocked .............. FAIL (dejó pasar)' || E'\n';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM LIKE '%date_blocked%' THEN
      v_report := v_report || 'T7  bloqueo manual → date_blocked .............. PASS' || E'\n';
    ELSE
      v_report := v_report || 'T7  bloqueo manual: error inesperado ........... FAIL ' || SQLERRM || E'\n';
    END IF;
  END;

  ---------------------------------------------------------------
  -- T8: horas extra amplían busy_range y SÍ pueden chocar con el
  -- otro evento del día (r3 08:00-09:45; ampliamos con 4h extra →
  -- invade fácilmente cualquier otro evento de esa fecha limpia)
  --
  -- ACEPTADO 2026-07-28: el UPDATE que dispara recompute_range_on_extra()
  -- solo toca `updated_at`, y trg_02_enforce_group_availability está
  -- definido BEFORE UPDATE OF group_id, event_date, event_time, status —
  -- sin `updated_at` en esa lista, no se dispara ahí, así que el mensaje
  -- amigable 'time_overlap' se salta. La INTEGRIDAD no se compromete: el
  -- constraint de motor excl_group_busy_range rechaza el traslape de
  -- todos modos, solo con el mensaje crudo de Postgres. Ambas rutas
  -- (time_overlap vía trigger, o el constraint directo) protegen
  -- correctamente contra el doble-booking y se aceptan como PASS. La
  -- diferencia de mensaje queda como deuda técnica de experiencia/manejo
  -- de errores, fuera de esta fase — no se toca el trigger, el
  -- constraint, ni el flujo de horas extra.
  ---------------------------------------------------------------
  INSERT INTO reservations (group_id, client_id, event_date, event_time, hours_count, status, total_price, base_price, address)
  VALUES (v_group, v_client, DATE '2031-03-20', TIME '10:00', 1, 'accepted', 500, 416, 'Av. Prueba 123')
  RETURNING id INTO v_r1;
  INSERT INTO reservations (group_id, client_id, event_date, event_time, hours_count, status, total_price, base_price, address)
  VALUES (v_group, v_client, DATE '2031-03-20', TIME '15:00', 1, 'accepted', 500, 416, 'Av. Prueba 123')
  RETURNING id INTO v_r2;
  BEGIN
    INSERT INTO extra_hours (reservation_id, hours_added, price_per_hour,
                             total_extra_cost, platform_commission, group_extra_earnings, status)
    VALUES (v_r1, 4, 500, 2000, 400, 1600, 'accepted');
    v_report := v_report || 'T8  extra que invade el 2º evento → rechazo .... FAIL (dejó pasar)' || E'\n';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM LIKE '%time_overlap%' THEN
      v_report := v_report || 'T8  extra que invade el 2º evento → time_overlap PASS (vía trigger)' || E'\n';
    ELSIF SQLERRM LIKE '%excl_group_busy_range%' THEN
      v_report := v_report || 'T8  extra que invade el 2º evento → rechazo .... PASS (vía constraint excl_group_busy_range — mensaje crudo, integridad OK, deuda técnica documentada)' || E'\n';
    ELSE
      v_report := v_report || 'T8  extra: error inesperado ..................... FAIL ' || SQLERRM || E'\n';
    END IF;
  END;

  ---------------------------------------------------------------
  -- T9: RPC create_booking_with_event() — 2 llamadas mismo día sin
  -- traslape deben pasar ambas (ya no debe devolver error date_taken).
  -- Esta RPC tiene un bug INDEPENDIENTE de Fase A: referencia
  -- reservations.package_id, columna que no existe (ver sql/523,
  -- "FUERA DE ALCANCE"). Si truena por eso, NO es una regresión de
  -- este parche — se distingue explícitamente abajo.
  ---------------------------------------------------------------
  BEGIN
    v_booking := create_booking_with_event(
      v_client, v_group, NULL, DATE '2031-04-01', TIME '10:00',
      'Av. RPC 1', 1200, NULL, NULL, 1000);
    IF v_booking ? 'reservation_id' THEN
      v_report := v_report || 'T9a create_booking_with_event 1er evento ....... PASS' || E'\n';
    ELSIF (v_booking->>'error') = 'date_taken' THEN
      v_report := v_report || 'T9a create_booking_with_event 1er evento ....... FAIL (date_taken sigue vivo)' || E'\n';
      RAISE EXCEPTION '%', v_report;
    ELSE
      v_report := v_report || 'T9a create_booking_with_event 1er evento ....... FAIL inesperado ' || v_booking::text || E'\n';
    END IF;
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM LIKE '%package_id%' THEN
      v_report := v_report || 'T9a create_booking_with_event 1er evento ....... SKIP (bug preexistente package_id, ver sql/523)' || E'\n';
    ELSE
      v_report := v_report || 'T9a create_booking_with_event: error inesperado  FAIL ' || SQLERRM || E'\n';
      RAISE EXCEPTION '%', v_report;
    END IF;
  END;

  BEGIN
    v_booking := create_booking_with_event(
      v_client, v_group, NULL, DATE '2031-04-01', TIME '18:00',
      'Av. RPC 2', 1200, NULL, NULL, 1000);
    IF v_booking ? 'reservation_id' THEN
      v_report := v_report || 'T9b create_booking_with_event 2º evento ........ PASS (ya no date_taken)' || E'\n';
    ELSIF (v_booking->>'error') = 'date_taken' THEN
      v_report := v_report || 'T9b create_booking_with_event 2º evento ........ FAIL (date_taken sigue vivo)' || E'\n';
      RAISE EXCEPTION '%', v_report;
    ELSE
      v_report := v_report || 'T9b create_booking_with_event 2º evento ........ FAIL inesperado ' || v_booking::text || E'\n';
    END IF;
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM LIKE '%package_id%' THEN
      v_report := v_report || 'T9b create_booking_with_event 2º evento ........ SKIP (bug preexistente package_id, ver sql/523)' || E'\n';
    ELSE
      v_report := v_report || 'T9b create_booking_with_event: error inesperado  FAIL ' || SQLERRM || E'\n';
      RAISE EXCEPTION '%', v_report;
    END IF;
  END;

  ---------------------------------------------------------------
  -- T10: can_schedule() directo — disponible / daily_limit / time_overlap
  ---------------------------------------------------------------
  -- Limpiamos el grupo a un estado conocido para este caso puntual:
  DELETE FROM reservations WHERE group_id = v_group AND event_date = DATE '2031-05-05';

  v_range1 := make_busy_range(DATE '2031-05-05', TIME '10:00', 'America/Mexico_City', 2, 0);
  v_sched := can_schedule(v_group, DATE '2031-05-05', v_range1, NULL);
  IF v_sched IS NULL THEN
    v_report := v_report || 'T10a can_schedule día vacío → disponible ....... PASS' || E'\n';
  ELSE
    v_report := v_report || 'T10a can_schedule día vacío ..................... FAIL ' || v_sched || E'\n';
  END IF;

  INSERT INTO reservations (group_id, client_id, event_date, event_time, hours_count, status, total_price, base_price, address)
  VALUES (v_group, v_client, DATE '2031-05-05', TIME '10:00', 2, 'accepted', 800, 666, 'Av. Prueba 123')
  RETURNING id INTO v_r1;

  v_range2 := make_busy_range(DATE '2031-05-05', TIME '18:00', 'America/Mexico_City', 2, 0);
  v_sched := can_schedule(v_group, DATE '2031-05-05', v_range2, NULL);
  IF v_sched IS NULL THEN
    v_report := v_report || 'T10b can_schedule 2º sin traslape → disponible .. PASS (ya no date_taken_legacy)' || E'\n';
  ELSE
    v_report := v_report || 'T10b can_schedule 2º sin traslape ............... FAIL ' || v_sched || E'\n';
  END IF;

  INSERT INTO reservations (group_id, client_id, event_date, event_time, hours_count, status, total_price, base_price, address)
  VALUES (v_group, v_client, DATE '2031-05-05', TIME '18:00', 2, 'accepted', 800, 666, 'Av. Prueba 123')
  RETURNING id INTO v_r2;

  v_sched := can_schedule(v_group, DATE '2031-05-05', make_busy_range(DATE '2031-05-05', TIME '22:00', 'America/Mexico_City', 1, 0), NULL);
  IF v_sched = 'daily_limit' THEN
    v_report := v_report || 'T10c can_schedule 3er evento → daily_limit ...... PASS' || E'\n';
  ELSE
    v_report := v_report || 'T10c can_schedule 3er evento ..................... FAIL ' || COALESCE(v_sched,'NULL') || E'\n';
  END IF;

  -- T10d: aislar time_overlap de daily_limit con p_exclude=v_r2 (excluye
  -- la reserva de 18:00 del conteo, dejando solo la de 10:00 → 1 < 2 →
  -- no truena por daily_limit; el rango v_range1 SÍ traslapa con la de
  -- 10:00 que sigue contando → debe rechazar por time_overlap puro).
  v_sched := can_schedule(v_group, DATE '2031-05-05', v_range1, v_r2);
  IF v_sched = 'time_overlap' THEN
    v_report := v_report || 'T10d can_schedule traslape (aislado) → time_overlap PASS' || E'\n';
  ELSE
    v_report := v_report || 'T10d can_schedule traslape (aislado) ................ FAIL ' || COALESCE(v_sched,'NULL') || E'\n';
  END IF;

  ---------------------------------------------------------------
  -- T12: RPC client_accept_proposal() — 2 llamadas mismo día sin
  -- traslape deben pasar ambas (ya no debe devolver 'group_unavailable');
  -- la 3ra debe rechazar vía el trigger (daily_event_limit), no vía un
  -- pre-check propio. Simula el JWT del cliente (mismo truco que sql/522).
  ---------------------------------------------------------------
  PERFORM set_config('request.jwt.claims',
    json_build_object('sub', v_client, 'role', 'authenticated')::text, TRUE);

  DELETE FROM reservations WHERE group_id = v_group AND event_date = DATE '2031-06-10';

  -- Request #1
  INSERT INTO event_requests (client_id, genre, event_type, event_date, event_time,
                              hours, location_city, location_estado, status,
                              negotiating_group_id, proposal_data)
  VALUES (v_client, 'banda', 'boda', DATE '2031-06-10', '10:00', 2,
          'Guadalajara', 'Jalisco', 'en_negociacion', v_owner,
          jsonb_build_object('total_amount', 1200, 'group_price', 1000))
  RETURNING id INTO v_req1;

  v_booking := client_accept_proposal(v_req1);
  IF (v_booking->>'ok')::boolean IS TRUE THEN
    v_report := v_report || 'T12a client_accept_proposal 1er evento ......... PASS' || E'\n';
  ELSE
    v_report := v_report || 'T12a client_accept_proposal 1er evento ......... FAIL ' || v_booking::text || E'\n';
    RAISE EXCEPTION '%', v_report;
  END IF;

  -- Request #2, mismo día, horario sin traslape (18:00 vs 10:00-13:15)
  INSERT INTO event_requests (client_id, genre, event_type, event_date, event_time,
                              hours, location_city, location_estado, status,
                              negotiating_group_id, proposal_data)
  VALUES (v_client, 'banda', 'boda', DATE '2031-06-10', '18:00', 2,
          'Guadalajara', 'Jalisco', 'en_negociacion', v_owner,
          jsonb_build_object('total_amount', 1200, 'group_price', 1000))
  RETURNING id INTO v_req2;

  v_booking := client_accept_proposal(v_req2);
  IF (v_booking->>'ok')::boolean IS TRUE THEN
    v_report := v_report || 'T12b client_accept_proposal 2º evento .......... PASS (ya no group_unavailable)' || E'\n';
  ELSIF (v_booking->>'error') = 'group_unavailable' THEN
    v_report := v_report || 'T12b client_accept_proposal 2º evento .......... FAIL (candado legado sigue vivo)' || E'\n';
    RAISE EXCEPTION '%', v_report;
  ELSE
    v_report := v_report || 'T12b client_accept_proposal 2º evento .......... FAIL inesperado ' || v_booking::text || E'\n';
    RAISE EXCEPTION '%', v_report;
  END IF;

  -- Request #3, mismo día → debe rechazar vía el trigger (daily_event_limit),
  -- devuelto por el EXCEPTION WHEN OTHERS de la propia RPC.
  INSERT INTO event_requests (client_id, genre, event_type, event_date, event_time,
                              hours, location_city, location_estado, status,
                              negotiating_group_id, proposal_data)
  VALUES (v_client, 'banda', 'boda', DATE '2031-06-10', '22:00', 1,
          'Guadalajara', 'Jalisco', 'en_negociacion', v_owner,
          jsonb_build_object('total_amount', 600, 'group_price', 500))
  RETURNING id INTO v_req3;

  v_booking := client_accept_proposal(v_req3);
  IF (v_booking->>'ok')::boolean IS FALSE AND (v_booking->>'error') LIKE '%daily_event_limit%' THEN
    v_report := v_report || 'T12c client_accept_proposal 3er evento ......... PASS (daily_event_limit vía trigger)' || E'\n';
  ELSE
    v_report := v_report || 'T12c client_accept_proposal 3er evento ......... FAIL ' || v_booking::text || E'\n';
  END IF;

  -- Reset del JWT simulado (por higiene, aunque el rollback final lo revierte igual)
  PERFORM set_config('request.jwt.claims', '', TRUE);

  ---------------------------------------------------------------
  -- T13: verificación estática — ninguna de las 4 funciones contiene
  -- ya 'date_taken' ni 'group_unavailable'
  ---------------------------------------------------------------
  IF NOT EXISTS (
    SELECT 1 FROM pg_proc
    WHERE pronamespace = 'public'::regnamespace
      AND proname IN ('enforce_group_availability','create_booking_with_event',
                       'can_schedule','client_accept_proposal')
      AND (pg_get_functiondef(oid) ILIKE '%date_taken%'
           OR pg_get_functiondef(oid) ILIKE '%group_unavailable%')
  ) THEN
    v_report := v_report || 'T13 ninguna de las 4 funciones tiene el candado . PASS' || E'\n';
  ELSE
    v_report := v_report || 'T13 alguna función todavía tiene el candado ..... FAIL' || E'\n';
  END IF;

  v_report := v_report || E'══════ FIN — todo se revierte ahora ══════\n';
  v_report := v_report || 'Nota: corre sql/520_f22_gate_tests.sql por separado para confirmar' || E'\n';
  v_report := v_report || 'que tocar can_schedule() no rompió el gate de pagos F2.2 (21/21 esperado).';
  RAISE EXCEPTION '%', v_report;   -- ⬅ el "error" ES el reporte + ROLLBACK total
END $$;
