-- ═══════════════════════════════════════════════════════════════════════════
-- 709 — SUITE AUTOREVERTIBLE de sql/708 (notify_wave_1 sin anon)
-- ═══════════════════════════════════════════════════════════════════════════
-- Aplica los REVOKE de sql/708 DENTRO de su propia transacción, prueba, y
-- REVIERTE TODO con el RAISE final. No deja nada aplicado. No crea filas.
-- Correrla NO es aplicar la migración.
--
-- Las llamadas de prueba usan un UUID aleatorio inexistente a propósito: eso
-- alcanza para distinguir "no tengo permiso" (42501) de "sí ejecuté"
-- (`request_not_found`), y garantiza **cero** escrituras y cero notificaciones.
-- ═══════════════════════════════════════════════════════════════════════════

BEGIN;

DO $suite$
DECLARE
  r           TEXT := '';
  pass        INT  := 0;
  fail        INT  := 0;
  v_sig       TEXT := 'public.notify_wave_1(uuid, double precision, double precision, double precision, boolean)';
  v_oid       OID;
  v_cnt       BIGINT;
  v_txt       TEXT;
  v_state     TEXT;
  v_json      JSONB;
  v_rows_ini  BIGINT;
  v_rows_fin  BIGINT;
  v_notif_ini BIGINT;
  v_notif_fin BIGINT;
  v_md5       TEXT;
BEGIN
  v_oid := to_regprocedure(v_sig);
  SELECT COUNT(*) INTO v_rows_ini  FROM public.event_requests;
  SELECT COUNT(*) INTO v_notif_ini FROM public.notifications;

  -- ── [1] ESTADO INICIAL: anon SÍ puede hoy ────────────────────────────────
  IF has_function_privilege('anon', v_oid, 'EXECUTE') THEN
    pass := pass + 1; r := r || E'\n[1] OK   anon TIENE EXECUTE antes del revoke (confirma el hallazgo)';
  ELSE
    fail := fail + 1; r := r || E'\n[1] FAIL anon ya no tenia EXECUTE: el estado inicial no es el auditado';
  END IF;

  -- ── [2] ESTADO INICIAL: PUBLIC lo tiene (por eso no basta revocar anon) ──
  SELECT proacl::text INTO v_txt FROM pg_proc WHERE oid = v_oid;
  IF position('{=X/postgres' in v_txt) = 1 THEN
    pass := pass + 1; r := r || E'\n[2] OK   PUBLIC tiene EXECUTE antes del revoke (=X/postgres al inicio del ACL)';
  ELSE
    fail := fail + 1; r := r || E'\n[2] FAIL PUBLIC no aparece con EXECUTE — acl=' || v_txt;
  END IF;

  -- ── [3] UNA SOLA FIRMA (sql/704 ya limpio el overload) ──────────────────
  SELECT COUNT(*) INTO v_cnt
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public' AND p.proname = 'notify_wave_1';
  IF v_cnt = 1 THEN
    pass := pass + 1; r := r || E'\n[3] OK   existe 1 sola firma de notify_wave_1';
  ELSE
    fail := fail + 1; r := r || E'\n[3] FAIL hay ' || v_cnt || ' firmas de notify_wave_1';
  END IF;

  -- ── [4] CUERPO INTACTO (el md5 que audito sql/708) ──────────────────────
  SELECT md5(prosrc) INTO v_md5 FROM pg_proc WHERE oid = v_oid;
  IF v_md5 = 'cff1e818611c0d77fde4f4a8efe16837' THEN
    pass := pass + 1; r := r || E'\n[4] OK   cuerpo de notify_wave_1 sin cambios (md5 ' || left(v_md5, 8) || ')';
  ELSE
    fail := fail + 1; r := r || E'\n[4] FAIL md5 del cuerpo distinto: ' || v_md5;
  END IF;

  -- ── [5] EL TOP 3 SIGUE SIENDO TOP 3 (no hay cambio de producto) ─────────
  SELECT prosrc INTO v_txt FROM pg_proc WHERE oid = v_oid;
  IF v_txt LIKE '%_send_wave(v_req, 0, 3, v_urgent)%' THEN
    pass := pass + 1; r := r || E'\n[5] OK   sigue llamando _send_wave(v_req, 0, 3, ...) — top 3 sin tocar';
  ELSE
    fail := fail + 1; r := r || E'\n[5] FAIL no se encontro la llamada al top 3';
  END IF;

  -- ── [6] NADIE MAS LA INVOCA (funciones + crons) ─────────────────────────
  SELECT (SELECT COUNT(*) FROM pg_proc p
          WHERE p.prosrc ILIKE '%notify_wave_1%' AND p.proname <> 'notify_wave_1')
       + (SELECT COUNT(*) FROM cron.job WHERE command ILIKE '%notify_wave_1%')
    INTO v_cnt;
  IF v_cnt = 0 THEN
    pass := pass + 1; r := r || E'\n[6] OK   0 funciones y 0 crons invocan notify_wave_1';
  ELSE
    fail := fail + 1; r := r || E'\n[6] FAIL hay ' || v_cnt || ' invocadores internos';
  END IF;

  -- ══════════════ SE APLICAN LOS REVOKE DE sql/708 (en esta tx) ═══════════
  EXECUTE 'REVOKE EXECUTE ON FUNCTION ' || v_sig || ' FROM PUBLIC';
  EXECUTE 'REVOKE EXECUTE ON FUNCTION ' || v_sig || ' FROM anon';
  EXECUTE 'GRANT  EXECUTE ON FUNCTION ' || v_sig || ' TO authenticated, service_role';

  -- ── [7] anon YA NO tiene EXECUTE efectivo ───────────────────────────────
  IF NOT has_function_privilege('anon', v_oid, 'EXECUTE') THEN
    pass := pass + 1; r := r || E'\n[7] OK   anon SIN EXECUTE efectivo despues del revoke';
  ELSE
    fail := fail + 1; r := r || E'\n[7] FAIL anon conserva EXECUTE efectivo';
  END IF;

  -- ── [8] PUBLIC tampoco (ya no hay =X/postgres al inicio del ACL) ────────
  SELECT proacl::text INTO v_txt FROM pg_proc WHERE oid = v_oid;
  IF position('{=X/postgres' in v_txt) = 0 THEN
    pass := pass + 1; r := r || E'\n[8] OK   PUBLIC sin EXECUTE — acl=' || v_txt;
  ELSE
    fail := fail + 1; r := r || E'\n[8] FAIL PUBLIC conserva EXECUTE — acl=' || v_txt;
  END IF;

  -- ── [9] authenticated SÍ conserva (la app instalada no se rompe) ────────
  IF has_function_privilege('authenticated', v_oid, 'EXECUTE') THEN
    pass := pass + 1; r := r || E'\n[9] OK   authenticated conserva EXECUTE';
  ELSE
    fail := fail + 1; r := r || E'\n[9] FAIL authenticated perdio EXECUTE';
  END IF;

  -- ── [10] service_role y postgres conservan ──────────────────────────────
  IF has_function_privilege('service_role', v_oid, 'EXECUTE')
     AND has_function_privilege('postgres', v_oid, 'EXECUTE') THEN
    pass := pass + 1; r := r || E'\n[10] OK  service_role y postgres conservan EXECUTE';
  ELSE
    fail := fail + 1; r := r || E'\n[10] FAIL service_role/postgres perdieron EXECUTE';
  END IF;

  -- ── [11] PRUEBA FUNCIONAL: anon recibe 42501 ────────────────────────────
  v_state := 'sin_error';
  SET LOCAL ROLE anon;
  BEGIN
    SELECT public.notify_wave_1(gen_random_uuid(), 19.43, -99.13, 50, false) INTO v_json;
  EXCEPTION WHEN insufficient_privilege THEN
    v_state := SQLSTATE;
  END;
  RESET ROLE;
  IF v_state = '42501' THEN
    pass := pass + 1; r := r || E'\n[11] OK  anon llamando la RPC -> 42501 insufficient_privilege';
  ELSE
    fail := fail + 1; r := r || E'\n[11] FAIL anon no fue bloqueado (estado=' || v_state || ', json=' || COALESCE(v_json::text, 'NULL') || ')';
  END IF;

  -- ── [12] PRUEBA FUNCIONAL: authenticated SÍ ejecuta ─────────────────────
  v_json := NULL; v_state := 'sin_error';
  SET LOCAL ROLE authenticated;
  BEGIN
    SELECT public.notify_wave_1(gen_random_uuid(), 19.43, -99.13, 50, false) INTO v_json;
  EXCEPTION WHEN OTHERS THEN
    v_state := SQLSTATE;
  END;
  RESET ROLE;
  IF v_state = 'sin_error' AND v_json->>'error' = 'request_not_found' THEN
    pass := pass + 1; r := r || E'\n[12] OK  authenticated EJECUTA la RPC (respuesta request_not_found, 0 efectos)';
  ELSE
    fail := fail + 1; r := r || E'\n[12] FAIL authenticated no ejecuto (estado=' || v_state || ', json=' || COALESCE(v_json::text, 'NULL') || ')';
  END IF;

  -- ── [13] service_role también ejecuta ───────────────────────────────────
  v_json := NULL; v_state := 'sin_error';
  SET LOCAL ROLE service_role;
  BEGIN
    SELECT public.notify_wave_1(gen_random_uuid(), 19.43, -99.13, 50, false) INTO v_json;
  EXCEPTION WHEN OTHERS THEN
    v_state := SQLSTATE;
  END;
  RESET ROLE;
  IF v_state = 'sin_error' AND v_json->>'error' = 'request_not_found' THEN
    pass := pass + 1; r := r || E'\n[13] OK  service_role EJECUTA la RPC';
  ELSE
    fail := fail + 1; r := r || E'\n[13] FAIL service_role no ejecuto (estado=' || v_state || ', json=' || COALESCE(v_json::text, 'NULL') || ')';
  END IF;

  -- ── [14] CERO EFECTOS: ni filas nuevas ni notificaciones ────────────────
  SELECT COUNT(*) INTO v_rows_fin  FROM public.event_requests;
  SELECT COUNT(*) INTO v_notif_fin FROM public.notifications;
  IF v_rows_fin = v_rows_ini AND v_notif_fin = v_notif_ini THEN
    pass := pass + 1; r := r || E'\n[14] OK  0 event_requests creadas y 0 notificaciones (' || v_rows_fin || '/' || v_notif_fin || ')';
  ELSE
    fail := fail + 1; r := r || E'\n[14] FAIL hubo efectos: event_requests ' || v_rows_ini || '->' || v_rows_fin
                                 || ', notifications ' || v_notif_ini || '->' || v_notif_fin;
  END IF;

  -- ── [15] EL CUERPO SIGUE INTACTO DESPUES DEL REVOKE ─────────────────────
  SELECT md5(prosrc) INTO v_txt FROM pg_proc WHERE oid = v_oid;
  IF v_txt = v_md5 THEN
    pass := pass + 1; r := r || E'\n[15] OK  el revoke no toco el cuerpo (md5 igual)';
  ELSE
    fail := fail + 1; r := r || E'\n[15] FAIL el md5 del cuerpo cambio';
  END IF;

  RAISE EXCEPTION E'TEST_REPORT_709 (todo revertido)\nPASS=% FAIL=% %', pass, fail, r;
END
$suite$;

ROLLBACK;
