-- ============================================================
-- sql/515_f1_tests.sql — F1 PASO 3: PRUEBAS (NO persiste NADA)
--
-- Truco: todas las pruebas corren en UN DO-block que al final lanza
-- RAISE EXCEPTION con el reporte → Postgres revierte TODO
-- automáticamente y el editor te muestra el resultado completo.
-- El "error" final ES el reporte — datos de prueba: cero rastro.
--
-- Requiere sql/514 ejecutado.
-- ============================================================

DO $$
DECLARE
  v_owner    UUID;
  v_group    UUID;
  v_r1 UUID; v_r2 UUID; v_r3 UUID;
  v_report   TEXT := E'\n══════ REPORTE DE PRUEBAS F1 ══════\n';
  v_ok       BOOLEAN;
  v_range    TSTZRANGE;
BEGIN
  -- Sujeto de pruebas: grupo sintético con un perfil existente
  SELECT id INTO v_owner FROM profiles LIMIT 1;
  INSERT INTO groups (name, owner_id, state, country, is_active)
  VALUES ('__TEST_F1__', v_owner, 'Jalisco', 'México', false)
  RETURNING id INTO v_group;

  ---------------------------------------------------------------
  -- T1: primer evento del día → permitido
  ---------------------------------------------------------------
  INSERT INTO reservations (group_id, client_id, event_date, event_time, hours_count, status, total_price, base_price, address)
  VALUES (v_group, v_owner, DATE '2030-05-10', TIME '18:00', 3, 'confirmed', 1200, 1000, 'Av. Prueba 123')
  RETURNING id INTO v_r1;
  v_report := v_report || 'T1 primer evento permitido ................ PASS' || E'\n';

  ---------------------------------------------------------------
  -- T2: rango calculado y tz correctos (montaje 30' + 3h + 45')
  ---------------------------------------------------------------
  SELECT busy_range INTO v_range FROM reservations WHERE id = v_r1;
  IF v_range = tstzrange((TIMESTAMP '2030-05-10 18:00' AT TIME ZONE 'America/Mexico_City') - INTERVAL '30 min',
                         (TIMESTAMP '2030-05-10 18:00' AT TIME ZONE 'America/Mexico_City') + INTERVAL '3 hours 45 min', '[)')
     AND (SELECT event_tz FROM reservations WHERE id = v_r1) = 'America/Mexico_City' THEN
    v_report := v_report || 'T2 busy_range + event_tz correctos ......... PASS' || E'\n';
  ELSE
    v_report := v_report || 'T2 busy_range + event_tz ................... FAIL ' || v_range::text || E'\n';
  END IF;

  ---------------------------------------------------------------
  -- T3: LEGADO intacto — segundo evento mismo día HOY debe fallar
  --     con date_taken (el candado por día sigue vivo hasta F2)
  ---------------------------------------------------------------
  BEGIN
    INSERT INTO reservations (group_id, client_id, event_date, event_time, hours_count, status, total_price, base_price, address)
    VALUES (v_group, v_owner, DATE '2030-05-10', TIME '10:00', 2, 'confirmed', 800, 666, 'Av. Prueba 123');
    v_report := v_report || 'T3 legado date_taken sigue vivo ............ FAIL (dejó pasar)' || E'\n';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM LIKE '%date_taken%' THEN
      v_report := v_report || 'T3 legado date_taken sigue vivo ............ PASS' || E'\n';
    ELSE
      v_report := v_report || 'T3 legado: error inesperado ................ FAIL ' || SQLERRM || E'\n';
    END IF;
  END;

  ---------------------------------------------------------------
  -- T4: LÍMITE DIARIO — con el 1º en accepted (que el legado NO ve)
  --     el 2º entra, y el 3º truena con daily_event_limit
  ---------------------------------------------------------------
  UPDATE reservations SET status = 'accepted' WHERE id = v_r1;
  INSERT INTO reservations (group_id, client_id, event_date, event_time, hours_count, status, total_price, base_price, address)
  VALUES (v_group, v_owner, DATE '2030-05-10', TIME '10:00', 2, 'accepted', 800, 666, 'Av. Prueba 123')
  RETURNING id INTO v_r2;
  v_report := v_report || 'T4a segundo evento (sin traslape) entra ..... PASS' || E'\n';

  BEGIN
    INSERT INTO reservations (group_id, client_id, event_date, event_time, hours_count, status, total_price, base_price, address)
    VALUES (v_group, v_owner, DATE '2030-05-10', TIME '13:30', 1, 'accepted', 500, 416, 'Av. Prueba 123');
    v_report := v_report || 'T4b tercer evento con hueco ................ FAIL (dejó pasar)' || E'\n';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM LIKE '%daily_event_limit%' THEN
      v_report := v_report || 'T4b tercer evento → daily_event_limit ...... PASS' || E'\n';
    ELSE
      v_report := v_report || 'T4b tercer evento: error inesperado ........ FAIL ' || SQLERRM || E'\n';
    END IF;
  END;

  ---------------------------------------------------------------
  -- T5: TRASLAPE de rangos (nuevo candado software)
  --     r2 es 10:00-12:00 → intentar 11:00 mismo día... el límite
  --     diario truena primero (correcto); probamos traslape puro
  --     cancelando r1 (queda 1 cupo) e insertando encima de r2
  ---------------------------------------------------------------
  UPDATE reservations SET status = 'cancelled' WHERE id = v_r1;
  BEGIN
    INSERT INTO reservations (group_id, client_id, event_date, event_time, hours_count, status, total_price, base_price, address)
    VALUES (v_group, v_owner, DATE '2030-05-10', TIME '11:00', 2, 'accepted', 700, 583, 'Av. Prueba 123');
    v_report := v_report || 'T5 traslape de rangos ...................... FAIL (dejó pasar)' || E'\n';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM LIKE '%time_overlap%' THEN
      v_report := v_report || 'T5 traslape → time_overlap ................. PASS' || E'\n';
    ELSE
      v_report := v_report || 'T5 traslape: error inesperado .............. FAIL ' || SQLERRM || E'\n';
    END IF;
  END;

  ---------------------------------------------------------------
  -- T6: COMPLETED sigue contando para el límite (decisión cerrada)
  --     r2 completed + r3 accepted = 2 → un nuevo accepted truena
  ---------------------------------------------------------------
  UPDATE reservations SET status = 'completed' WHERE id = v_r2;
  BEGIN
    INSERT INTO reservations (group_id, client_id, event_date, event_time, hours_count, status, total_price, base_price, address)
    VALUES (v_group, v_owner, DATE '2030-05-10', TIME '20:00', 2, 'accepted', 900, 750, 'Av. Prueba 123')
    RETURNING id INTO v_r3;
  EXCEPTION WHEN OTHERS THEN
    v_report := v_report || 'T6-pre r3 no pudo insertarse ............... FAIL ' || SQLERRM || E'\n══ ABORTADO ══';
    RAISE EXCEPTION '%', v_report;
  END;
  BEGIN
    INSERT INTO reservations (group_id, client_id, event_date, event_time, hours_count, status, total_price, base_price, address)
    VALUES (v_group, v_owner, DATE '2030-05-10', TIME '14:00', 1, 'accepted', 500, 416, 'Av. Prueba 123');
    v_report := v_report || 'T6 completed cuenta para el límite ......... FAIL (dejó pasar un 3º)' || E'\n';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM LIKE '%daily_event_limit%' THEN
      v_report := v_report || 'T6 completed cuenta para el límite ......... PASS' || E'\n';
    ELSE
      v_report := v_report || 'T6 completed: error inesperado ............. FAIL ' || SQLERRM || E'\n';
    END IF;
  END;

  ---------------------------------------------------------------
  -- T7: EXPIRADA libera el cupo (r3 → expired, entra una nueva)
  ---------------------------------------------------------------
  UPDATE reservations SET status = 'expired' WHERE id = v_r3;
  BEGIN
    INSERT INTO reservations (group_id, client_id, event_date, event_time, hours_count, status, total_price, base_price, address)
    VALUES (v_group, v_owner, DATE '2030-05-10', TIME '20:00', 2, 'accepted', 900, 750, 'Av. Prueba 123');
    v_report := v_report || 'T7 expirada libera el cupo ................. PASS' || E'\n';
  EXCEPTION WHEN OTHERS THEN
    v_report := v_report || 'T7 expirada libera el cupo ................. FAIL ' || SQLERRM || E'\n';
  END;

  ---------------------------------------------------------------
  -- T8: MEDIANOCHE — evento 23:00 (3h) del día 20: cuenta en el
  --     día 20; su rango invade el día 21 y bloquea las 01:00
  ---------------------------------------------------------------
  INSERT INTO reservations (group_id, client_id, event_date, event_time, hours_count, status, total_price, base_price, address)
  VALUES (v_group, v_owner, DATE '2030-05-20', TIME '23:00', 3, 'accepted', 1200, 1000, 'Av. Prueba 123')
  RETURNING id INTO v_r3;   -- (reusa la var; si fallara, el guard de abajo reporta)
  IF count_events_local_day(v_group, DATE '2030-05-20', NULL) = 1
     AND count_events_local_day(v_group, DATE '2030-05-21', NULL) = 0 THEN
    v_report := v_report || 'T8a cruza medianoche: cuenta en día inicio . PASS' || E'\n';
  ELSE
    v_report := v_report || 'T8a cruza medianoche: conteo ............... FAIL' || E'\n';
  END IF;
  BEGIN
    INSERT INTO reservations (group_id, client_id, event_date, event_time, hours_count, status, total_price, base_price, address)
    VALUES (v_group, v_owner, DATE '2030-05-21', TIME '01:00', 2, 'accepted', 700, 583, 'Av. Prueba 123');
    v_report := v_report || 'T8b madrugada siguiente bloqueada .......... FAIL (dejó pasar)' || E'\n';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM LIKE '%time_overlap%' THEN
      v_report := v_report || 'T8b madrugada siguiente → time_overlap ..... PASS' || E'\n';
    ELSE
      v_report := v_report || 'T8b madrugada: error inesperado ............ FAIL ' || SQLERRM || E'\n';
    END IF;
  END;

  ---------------------------------------------------------------
  -- T9: BLOQUEO MANUAL no puede pisar un día con reserva ocupante
  ---------------------------------------------------------------
  BEGIN
    INSERT INTO group_unavailability (group_id, date, reason)
    VALUES (v_group, DATE '2030-05-20', 'test');
    v_report := v_report || 'T9 bloqueo sobre día con evento ............ FAIL (dejó pasar)' || E'\n';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM LIKE '%block_conflicts_reservations%' THEN
      v_report := v_report || 'T9 bloqueo sobre día con evento → rechazado  PASS' || E'\n';
    ELSE
      v_report := v_report || 'T9 bloqueo: error inesperado ............... FAIL ' || SQLERRM || E'\n';
    END IF;
  END;

  ---------------------------------------------------------------
  -- T10: EXTRA confirmada EXTIENDE el rango (+75 min)
  ---------------------------------------------------------------
  INSERT INTO extra_hours (reservation_id, hours, status, amount)
  VALUES ((SELECT id FROM reservations WHERE group_id = v_group AND event_date = DATE '2030-05-20' LIMIT 1), 1, 'accepted', 500);
  IF (SELECT upper(busy_range) FROM reservations WHERE group_id = v_group AND event_date = DATE '2030-05-20' LIMIT 1)
     = ((TIMESTAMP '2030-05-20 23:00' AT TIME ZONE 'America/Mexico_City') + INTERVAL '3 hours' + INTERVAL '75 min' + INTERVAL '45 min') THEN
    v_report := v_report || 'T10 extra confirmada extiende el rango ..... PASS' || E'\n';
  ELSE
    v_report := v_report || 'T10 extra confirmada extiende el rango ..... FAIL' || E'\n';
  END IF;

  v_report := v_report || E'══════ FIN — todo se revierte ahora ══════';
  RAISE EXCEPTION '%', v_report;   -- ⬅ el "error" ES el reporte + ROLLBACK total
END $$;

-- ============================================================
-- PRUEBA DE CONCURRENCIA (2 clientes simultáneos) — MANUAL
-- Requiere DOS pestañas del SQL editor:
--
-- Pestaña A:                          Pestaña B:
--   BEGIN;
--   INSERT reserva accepted
--     (grupo X, 2030-06-01 18:00);
--                                       BEGIN;
--                                       INSERT reserva accepted
--                                         (grupo X, 2030-06-01 10:00);
--                                       -- ⏳ SE QUEDA ESPERANDO (advisory lock)
--   COMMIT;
--                                       -- ▶ despierta y termina normal (2/2)
--                                       INSERT tercera → daily_event_limit
--                                       ROLLBACK;
--   (limpiar: DELETE de las filas de prueba del grupo X)
--
-- El punto verificable: B se BLOQUEA hasta el COMMIT de A (el lock
-- serializa) y el conteo que ve ya incluye la fila de A.
-- ============================================================
