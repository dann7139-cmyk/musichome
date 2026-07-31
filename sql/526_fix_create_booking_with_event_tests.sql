-- ============================================================
-- sql/526_fix_create_booking_with_event_tests.sql — PRUEBAS de sql/525
-- (NO persiste NADA)
--
-- Mismo patrón que sql/515/520/524: un DO-block que SIEMPRE termina en
-- RAISE EXCEPTION con el reporte → rollback total garantizado, cero
-- rastro en datos reales.
--
-- Requiere sql/525 aplicado.
-- ============================================================

DO $$
DECLARE
  v_owner    UUID;
  v_client   UUID;
  v_group    UUID;
  v_booking  JSONB;
  v_fake_pkg UUID := gen_random_uuid();
  v_res_id2  UUID;
  v_pkg_col_exists BOOLEAN;
  v_report   TEXT := E'\n══════ REPORTE DE PRUEBAS sql/525 (fix package_id) ══════\n';
BEGIN
  -- v_owner: perfil SIN ningún grupo propio previo — evita la ambigüedad
  -- de owner_id descubierta durante la verificación de Fase B.
  SELECT p.id INTO v_owner FROM profiles p
  WHERE NOT EXISTS (SELECT 1 FROM groups g WHERE g.owner_id = p.id)
  ORDER BY p.id LIMIT 1;
  IF v_owner IS NULL THEN
    RAISE EXCEPTION 'ABORTADO: no hay ningún perfil libre de grupos propios para usar como owner sintético';
  END IF;

  SELECT id INTO v_client FROM profiles WHERE id <> v_owner LIMIT 1;
  IF v_client IS NULL THEN v_client := v_owner; END IF;

  INSERT INTO groups (name, owner_id, state, country, is_active)
  VALUES ('__TEST_525__', v_owner, 'Jalisco', 'México', false)
  RETURNING id INTO v_group;

  ---------------------------------------------------------------
  -- T1: primer evento del día → creado correctamente, con
  -- p_package_id recibiendo un UUID real (prueba de compatibilidad)
  ---------------------------------------------------------------
  v_booking := create_booking_with_event(
    v_client, v_group, v_fake_pkg, DATE '2033-01-10', TIME '10:00',
    'Av. Prueba 1', 1200, NULL, NULL, 1000);
  IF v_booking ? 'reservation_id' THEN
    v_report := v_report || 'T1 primer evento creado correctamente ................ PASS' || E'\n';
  ELSE
    v_report := v_report || 'T1 primer evento ...................................... FAIL ' || v_booking::text || E'\n';
    RAISE EXCEPTION '%', v_report;
  END IF;

  ---------------------------------------------------------------
  -- T2: 2º evento mismo grupo/día, sin traslape → creado correctamente
  -- (r1 es 10:00-13:15; probamos 18:00, lejos de ese rango)
  ---------------------------------------------------------------
  v_booking := create_booking_with_event(
    v_client, v_group, NULL, DATE '2033-01-10', TIME '18:00',
    'Av. Prueba 2', 1200, NULL, NULL, 1000);
  IF v_booking ? 'reservation_id' THEN
    v_report := v_report || 'T2 2º evento mismo día sin traslape ................... PASS' || E'\n';
  ELSE
    v_report := v_report || 'T2 2º evento mismo día ................................ FAIL ' || v_booking::text || E'\n';
    RAISE EXCEPTION '%', v_report;
  END IF;

  ---------------------------------------------------------------
  -- T3: 3er evento mismo día → rechazado con daily_event_limit
  -- (excepción real del trigger, esta RPC no tiene EXCEPTION WHEN OTHERS)
  ---------------------------------------------------------------
  BEGIN
    v_booking := create_booking_with_event(
      v_client, v_group, NULL, DATE '2033-01-10', TIME '22:00',
      'Av. Prueba 3', 500, NULL, NULL, 416);
    v_report := v_report || 'T3 3er evento → daily_event_limit ..................... FAIL (dejó pasar)' || E'\n';
    RAISE EXCEPTION '%', v_report;
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM LIKE '%daily_event_limit%' THEN
      v_report := v_report || 'T3 3er evento → daily_event_limit ..................... PASS' || E'\n';
    ELSE
      v_report := v_report || 'T3 3er evento: error inesperado ....................... FAIL ' || SQLERRM || E'\n';
      RAISE EXCEPTION '%', v_report;
    END IF;
  END;

  ---------------------------------------------------------------
  -- T4: traslape real de horario → rechazado con time_overlap
  -- (fecha limpia; 1er evento 10:00-13:15, 2º intento a las 11:00 traslapa)
  ---------------------------------------------------------------
  v_booking := create_booking_with_event(
    v_client, v_group, NULL, DATE '2033-01-15', TIME '10:00',
    'Av. Prueba 4', 1200, NULL, NULL, 1000);
  IF NOT (v_booking ? 'reservation_id') THEN
    v_report := v_report || 'T4-setup evento base para traslape ..................... FAIL ' || v_booking::text || E'\n';
    RAISE EXCEPTION '%', v_report;
  END IF;

  BEGIN
    v_booking := create_booking_with_event(
      v_client, v_group, NULL, DATE '2033-01-15', TIME '11:00',
      'Av. Prueba 5', 700, NULL, NULL, 583);
    v_report := v_report || 'T4 traslape real → time_overlap ........................ FAIL (dejó pasar)' || E'\n';
    RAISE EXCEPTION '%', v_report;
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM LIKE '%time_overlap%' THEN
      v_report := v_report || 'T4 traslape real → time_overlap ........................ PASS' || E'\n';
    ELSE
      v_report := v_report || 'T4 traslape: error inesperado .......................... FAIL ' || SQLERRM || E'\n';
      RAISE EXCEPTION '%', v_report;
    END IF;
  END;

  ---------------------------------------------------------------
  -- T5: fecha bloqueada manualmente → rechazada con date_blocked
  -- (return controlado ANTES del INSERT, no es excepción)
  ---------------------------------------------------------------
  INSERT INTO group_unavailability (group_id, date, reason)
  VALUES (v_group, DATE '2033-01-20', 'test');

  v_booking := create_booking_with_event(
    v_client, v_group, NULL, DATE '2033-01-20', TIME '10:00',
    'Av. Prueba 6', 1200, NULL, NULL, 1000);
  IF (v_booking->>'error') = 'date_blocked' THEN
    v_report := v_report || 'T5 fecha bloqueada → date_blocked ...................... PASS' || E'\n';
  ELSE
    v_report := v_report || 'T5 fecha bloqueada ...................................... FAIL ' || v_booking::text || E'\n';
    RAISE EXCEPTION '%', v_report;
  END IF;

  ---------------------------------------------------------------
  -- T6: p_package_id sigue siendo aceptado por compatibilidad —
  -- ya lo probamos implícitamente en T1 (UUID real) y T2-T5 (NULL).
  -- Verificación explícita adicional: la firma sigue teniendo el
  -- parámetro en la 3ª posición, tipo uuid, sin default.
  ---------------------------------------------------------------
  IF (SELECT pg_get_function_identity_arguments(oid)
      FROM pg_proc WHERE proname = 'create_booking_with_event' AND pronamespace = 'public'::regnamespace)
     = 'p_client_id uuid, p_group_id uuid, p_package_id uuid, p_event_date date, p_event_time time without time zone, p_address text, p_total_price numeric, p_notes text, p_break_type text, p_base_price numeric, p_installment_plan text, p_installment_months integer, p_installment_monthly_amount numeric, p_payment_mode text'
  THEN
    v_report := v_report || 'T6 firma idéntica, p_package_id conservado ............. PASS' || E'\n';
  ELSE
    v_report := v_report || 'T6 firma cambió (NO debía cambiar) ..................... FAIL' || E'\n';
  END IF;

  ---------------------------------------------------------------
  -- T6b: compatibilidad FUNCIONAL (no solo de firma) — invocar con un
  -- UUID válido en p_package_id, confirmar que la función ejecuta
  -- normalmente, que la reserva se crea correctamente, y que no puede
  -- existir ninguna referencia residual a package_id porque la columna
  -- física no existe en la tabla (verificado contra information_schema,
  -- no solo contra el código fuente de la función).
  ---------------------------------------------------------------
  v_booking := create_booking_with_event(
    v_client, v_group, gen_random_uuid(), DATE '2033-01-25', TIME '10:00',
    'Av. Prueba T6b', 1200, NULL, NULL, 1000);

  IF NOT (v_booking ? 'reservation_id') THEN
    v_report := v_report || 'T6b invocación con p_package_id UUID válido ............ FAIL ' || v_booking::text || E'\n';
    RAISE EXCEPTION '%', v_report;
  END IF;

  SELECT id INTO v_res_id2 FROM reservations WHERE id = (v_booking->>'reservation_id')::uuid;
  IF v_res_id2 IS NULL THEN
    v_report := v_report || 'T6b la reserva no aparece en la tabla tras crearse ..... FAIL' || E'\n';
    RAISE EXCEPTION '%', v_report;
  END IF;

  SELECT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'reservations' AND column_name = 'package_id'
  ) INTO v_pkg_col_exists;

  IF v_res_id2 IS NOT NULL AND NOT v_pkg_col_exists THEN
    v_report := v_report || 'T6b reserva creada, p_package_id ignorado, sin columna real  PASS' || E'\n';
  ELSE
    v_report := v_report || 'T6b reapareció una columna package_id (inesperado) ..... FAIL' || E'\n';
    RAISE EXCEPTION '%', v_report;
  END IF;

  ---------------------------------------------------------------
  -- T7: verificación estática — el cuerpo ya no referencia
  -- reservations.package_id como columna del INSERT, pero sigue
  -- aceptando p_package_id en la firma.
  ---------------------------------------------------------------
  IF (SELECT pg_get_functiondef(oid) NOT ILIKE '%event_id, group_id, package_id, client_id,%'
      FROM pg_proc WHERE proname = 'create_booking_with_event' AND pronamespace = 'public'::regnamespace)
     AND (SELECT pg_get_functiondef(oid) ILIKE '%p_package_id%'
          FROM pg_proc WHERE proname = 'create_booking_with_event' AND pronamespace = 'public'::regnamespace)
  THEN
    v_report := v_report || 'T7 INSERT sin columna package_id, param conservado ..... PASS' || E'\n';
  ELSE
    v_report := v_report || 'T7 verificación estática ................................ FAIL' || E'\n';
  END IF;

  v_report := v_report || E'══════ FIN — todo se revierte ahora (RAISE) ══════';
  RAISE EXCEPTION '%', v_report;
END $$;
