-- ═══════════════════════════════════════════════════════════════════════════
-- 717 — SUITE AUTOREVERTIBLE de sql/715 + sql/716        RESULTADO: 20/20 PASS
-- ═══════════════════════════════════════════════════════════════════════════
-- Aplica los dos cambios DENTRO de su propia transacción, prueba el antes y el
-- después, y revierte TODO con el RAISE final. Correrla NO es aplicarlos.
--
-- DATOS: 100 % sintéticos y con una **familia de géneros inventada**
-- ('GX717', 'GY717', 'GZ717'), a propósito: así `_send_wave` solo puede alcanzar a
-- los grupos de la prueba y **ningún grupo real recibe notificaciones**, ni siquiera
-- dentro de la transacción revertida. Ciudad y estado también inventados.
-- Los 9 grupos no tienen `group_locations`, así que `gl.lat IS NULL` y la distancia
-- nunca puede ser la razón de una exclusión: lo único que varía es el género.
--
-- Los triggers AFTER INSERT de `event_requests` (zona + smart matching) crean
-- notificaciones propias; se limpian antes de medir cada ola, porque el `NOT EXISTS`
-- de `_send_wave` las tomaría como "ya notificado" y ensuciaría el conteo.
-- ═══════════════════════════════════════════════════════════════════════════

BEGIN;

DO $suite$
DECLARE
  rep TEXT := ''; pass INT := 0; fail INT := 0; n INT; js JSONB;
  md5_sw_antes TEXT; md5_gb_antes TEXT; v_src TEXT; v_def TEXT; v_ocurr INT;
  cli UUID := gen_random_uuid();
  o1 UUID := gen_random_uuid(); o2 UUID := gen_random_uuid(); o3 UUID := gen_random_uuid();
  o4 UUID := gen_random_uuid(); o5 UUID := gen_random_uuid(); o6 UUID := gen_random_uuid();
  o7 UUID := gen_random_uuid(); o8 UUID := gen_random_uuid(); o9 UUID := gen_random_uuid();
  g2 UUID; g9 UUID;
  reqA UUID; reqB UUID;
  notif_ini BIGINT;
BEGIN
  SELECT md5(prosrc) INTO md5_sw_antes FROM pg_proc WHERE oid = to_regprocedure('public._send_wave(record, integer, integer, boolean)');
  SELECT md5(prosrc) INTO md5_gb_antes FROM pg_proc WHERE oid = to_regprocedure('public.get_best_matching_groups(uuid, integer, integer, uuid[])');
  SELECT COUNT(*) INTO notif_ini FROM public.notifications;

  -- ══════════ SETUP: 8 compatibles + 1 incompatible ══════════
  INSERT INTO auth.users (id,email) VALUES
    (cli,'c717@example.invalid'),(o1,'g1-717@example.invalid'),(o2,'g2-717@example.invalid'),
    (o3,'g3-717@example.invalid'),(o4,'g4-717@example.invalid'),(o5,'g5-717@example.invalid'),
    (o6,'g6-717@example.invalid'),(o7,'g7-717@example.invalid'),(o8,'g8-717@example.invalid'),
    (o9,'g9-717@example.invalid');

  INSERT INTO public.groups (owner_id,name,genre,city,state,is_active,availability,ranking_score) VALUES
    (o1,'G1 exacto',      'GX717',             'Ciudad717','Estado717',TRUE,'available',90),
    (o2,'G2 compuesto',   'GX717/GY717',       'Ciudad717','Estado717',TRUE,'available',80),
    (o3,'G3 minusculas',  'gx717',             'Ciudad717','Estado717',TRUE,'available',70),
    (o4,'G4 espacios',    ' GX717 / GY717 ',   'Ciudad717','Estado717',TRUE,'available',60),
    (o5,'G5 exacto',      'GX717',             'Ciudad717','Estado717',TRUE,'available',50),
    (o6,'G6 compuesto',   'GY717/GX717',       'Ciudad717','Estado717',TRUE,'available',40),
    (o7,'G7 exacto',      'GX717',             'Ciudad717','Estado717',TRUE,'available',30),
    (o8,'G8 compuesto',   'GX717/GZ717',       'Ciudad717','Estado717',TRUE,'available',20),
    (o9,'G9 INCOMPATIBLE','GZ717',             'Ciudad717','Estado717',TRUE,'available',95);
  SELECT id INTO g2 FROM public.groups WHERE owner_id=o2;
  SELECT id INTO g9 FROM public.groups WHERE owner_id=o9;

  -- ══════════ SEMÁNTICA DE genre_matches (comportamiento actual) ══════════
  IF public.genre_matches('GX717','GX717') THEN pass:=pass+1; rep:=rep||E'\n[1] OK   exacto GX717 <-> GX717 = true';
  ELSE fail:=fail+1; rep:=rep||E'\n[1] FAIL exacto no coincide'; END IF;

  IF public.genre_matches('GX717/GY717','GX717') THEN pass:=pass+1; rep:=rep||E'\n[2] OK   compuesto GX717/GY717 <-> GX717 = true';
  ELSE fail:=fail+1; rep:=rep||E'\n[2] FAIL el compuesto no coincide'; END IF;

  IF public.genre_matches('gx717','GX717') THEN pass:=pass+1; rep:=rep||E'\n[3] OK   minusculas: gx717 <-> GX717 = true (genre_matches hace lower())';
  ELSE fail:=fail+1; rep:=rep||E'\n[3] FAIL las minusculas no coinciden'; END IF;

  IF public.genre_matches(' GX717 / GY717 ','GX717') THEN pass:=pass+1; rep:=rep||E'\n[4] OK   espacios: " GX717 / GY717 " <-> GX717 = true (genre_matches hace trim())';
  ELSE fail:=fail+1; rep:=rep||E'\n[4] FAIL los espacios no coinciden'; END IF;

  IF NOT public.genre_matches('GZ717','GX717') THEN pass:=pass+1; rep:=rep||E'\n[5] OK   incompatible GZ717 <-> GX717 = false';
  ELSE fail:=fail+1; rep:=rep||E'\n[5] FAIL el incompatible coincide'; END IF;

  -- ══════════ ANTES: la ola deja fuera al compuesto ══════════
  INSERT INTO public.event_requests
    (client_id,genre,event_type,event_date,location_city,location_estado,hours,status,event_lat,event_lng,radius_km)
  VALUES (cli,'GX717','fiesta_privada',CURRENT_DATE+10,'Ciudad717','Estado717',3,'open',19.43,-99.13,50)
  RETURNING id INTO reqA;
  DELETE FROM public.notifications WHERE data->>'request_id' = reqA::text;

  js := public.notify_wave_1(reqA, 19.43, -99.13, 50, false);
  SELECT COUNT(*) INTO n FROM public.notifications WHERE data->>'request_id'=reqA::text;
  IF (js->>'notified')::int = 3 AND n = 3 THEN
    pass:=pass+1; rep:=rep||E'\n[6] OK   ANTES la ola 1 notifico 3 (los 3 de genero EXACTO: G1, G5, G7)';
  ELSE fail:=fail+1; rep:=rep||E'\n[6] FAIL ANTES notified='||COALESCE(js->>'notified','?')||' notifs='||n; END IF;

  SELECT COUNT(*) INTO n FROM public.notifications WHERE data->>'request_id'=reqA::text AND user_id IN (o2,o3,o4,o6,o8);
  IF n = 0 THEN pass:=pass+1; rep:=rep||E'\n[7] OK   ANTES: 0 notificaciones para compuestos/minusculas/espacios (excluidos solo por la igualdad exacta)';
  ELSE fail:=fail+1; rep:=rep||E'\n[7] FAIL ANTES ya recibian: '||n; END IF;

  -- ══════════ SE APLICAN sql/715 y sql/716 ══════════
  v_def := pg_get_functiondef(to_regprocedure('public._send_wave(record, integer, integer, boolean)'));
  SELECT COUNT(*) INTO v_ocurr FROM regexp_matches(v_def, 'g\.genre\s*=\s*p_req\.genre', 'g');
  IF v_ocurr = 1 THEN pass:=pass+1; rep:=rep||E'\n[8] OK   _send_wave: 1 sola ocurrencia del filtro exacto';
  ELSE fail:=fail+1; rep:=rep||E'\n[8] FAIL _send_wave: '||v_ocurr||' ocurrencias'; END IF;
  EXECUTE regexp_replace(v_def, 'g\.genre\s*=\s*p_req\.genre', 'public.genre_matches(g.genre, p_req.genre)');

  v_def := pg_get_functiondef(to_regprocedure('public.get_best_matching_groups(uuid, integer, integer, uuid[])'));
  SELECT COUNT(*) INTO v_ocurr FROM regexp_matches(v_def, 'g\.genre\s*=\s*v_req\.genre', 'g');
  IF v_ocurr = 1 THEN pass:=pass+1; rep:=rep||E'\n[9] OK   get_best_matching_groups: 1 sola ocurrencia del filtro exacto';
  ELSE fail:=fail+1; rep:=rep||E'\n[9] FAIL get_best_matching_groups: '||v_ocurr||' ocurrencias'; END IF;
  EXECUTE regexp_replace(v_def, 'g\.genre\s*=\s*v_req\.genre', 'public.genre_matches(g.genre, v_req.genre)');

  -- byte-identico salvo esa condicion
  SELECT prosrc INTO v_src FROM pg_proc WHERE oid = to_regprocedure('public._send_wave(record, integer, integer, boolean)');
  IF md5(replace(v_src,'public.genre_matches(g.genre, p_req.genre)','g.genre     = p_req.genre')) = md5_sw_antes THEN
    pass:=pass+1; rep:=rep||E'\n[10] OK  _send_wave byte-identico salvo esa condicion (md5 ida y vuelta)';
  ELSE fail:=fail+1; rep:=rep||E'\n[10] FAIL _send_wave cambio en algo mas'; END IF;
  SELECT prosrc INTO v_src FROM pg_proc WHERE oid = to_regprocedure('public.get_best_matching_groups(uuid, integer, integer, uuid[])');
  IF md5(replace(v_src,'public.genre_matches(g.genre, v_req.genre)','g.genre     = v_req.genre')) = md5_gb_antes THEN
    pass:=pass+1; rep:=rep||E'\n[11] OK  get_best_matching_groups byte-identico salvo esa condicion';
  ELSE fail:=fail+1; rep:=rep||E'\n[11] FAIL get_best_matching_groups cambio en algo mas'; END IF;

  -- ══════════ DESPUÉS: olas 1, 2 y 3 sobre una solicitud nueva ══════════
  INSERT INTO public.event_requests
    (client_id,genre,event_type,event_date,location_city,location_estado,hours,status,event_lat,event_lng,radius_km)
  VALUES (cli,'GX717','fiesta_privada',CURRENT_DATE+11,'Ciudad717','Estado717',3,'open',19.43,-99.13,50)
  RETURNING id INTO reqB;
  DELETE FROM public.notifications WHERE data->>'request_id' = reqB::text;

  js := public.notify_wave_1(reqB, 19.43, -99.13, 50, false);
  IF (js->>'notified')::int = 3 THEN
    pass:=pass+1; rep:=rep||E'\n[12] OK  DESPUES ola 1: notified = 3 (el top 3 sigue siendo 3)';
  ELSE fail:=fail+1; rep:=rep||E'\n[12] FAIL ola 1 notifico '||COALESCE(js->>'notified','?'); END IF;

  SELECT COUNT(*) INTO n FROM public.notifications WHERE data->>'request_id'=reqB::text AND user_id=o2;
  IF n = 1 THEN pass:=pass+1; rep:=rep||E'\n[13] OK  el grupo COMPUESTO (G2, ranking 80) entra en la ola 1';
  ELSE fail:=fail+1; rep:=rep||E'\n[13] FAIL el compuesto no entro en la ola 1'; END IF;

  SELECT COUNT(*) INTO n FROM public.notifications WHERE data->>'request_id'=reqB::text AND user_id=o9;
  IF n = 0 THEN pass:=pass+1; rep:=rep||E'\n[14] OK  el INCOMPATIBLE (G9, ranking 95, el mas alto) NO recibe notificacion';
  ELSE fail:=fail+1; rep:=rep||E'\n[14] FAIL el incompatible fue notificado'; END IF;

  -- ola 2: se simula el paso del tiempo moviendo wave1_sent_at
  UPDATE public.event_requests SET wave1_sent_at = NOW() - INTERVAL '6 minutes' WHERE id = reqB;
  PERFORM public.process_notification_waves();
  SELECT current_wave INTO n FROM public.event_requests WHERE id = reqB;
  IF n = 2 THEN pass:=pass+1; rep:=rep||E'\n[15] OK  ola 2 corrio: current_wave = 2';
  ELSE fail:=fail+1; rep:=rep||E'\n[15] FAIL current_wave = '||COALESCE(n::text,'NULL'); END IF;
  SELECT COUNT(*) INTO n FROM public.notifications WHERE data->>'request_id'=reqB::text;
  IF n = 5 THEN pass:=pass+1; rep:=rep||E'\n[16] OK  ola 2 con OFFSET 3 + LIMIT 12 sobre los 5 restantes -> 2 mas (total 5), sus reglas intactas';
  ELSE fail:=fail+1; rep:=rep||E'\n[16] FAIL total de notificaciones tras la ola 2 = '||n; END IF;

  -- ola 3
  UPDATE public.event_requests SET wave2_sent_at = NOW() - INTERVAL '11 minutes' WHERE id = reqB;
  PERFORM public.process_notification_waves();
  SELECT current_wave INTO n FROM public.event_requests WHERE id = reqB;
  IF n = 3 THEN pass:=pass+1; rep:=rep||E'\n[17] OK  ola 3 corrio: current_wave = 3';
  ELSE fail:=fail+1; rep:=rep||E'\n[17] FAIL current_wave = '||COALESCE(n::text,'NULL'); END IF;
  SELECT COUNT(*) INTO n FROM public.notifications WHERE data->>'request_id'=reqB::text;
  IF n = 5 THEN pass:=pass+1; rep:=rep||E'\n[18] OK  ola 3 con OFFSET 15 sobre los 3 restantes -> 0 mas (total sigue 5): su regla intacta';
  ELSE fail:=fail+1; rep:=rep||E'\n[18] FAIL total tras la ola 3 = '||n; END IF;

  -- sin duplicados
  SELECT COUNT(*) INTO n FROM (
    SELECT user_id FROM public.notifications WHERE data->>'request_id'=reqB::text
    GROUP BY user_id HAVING COUNT(*) > 1) t;
  IF n = 0 THEN pass:=pass+1; rep:=rep||E'\n[19] OK  0 destinatarios con notificacion duplicada de la misma solicitud';
  ELSE fail:=fail+1; rep:=rep||E'\n[19] FAIL '||n||' destinatarios duplicados'; END IF;

  -- get_best_matching_groups ya incluye al compuesto y conserva el orden por score
  SELECT COUNT(*) INTO n FROM public.get_best_matching_groups(reqB, 100, 0, '{}'::uuid[]) t
  WHERE t.group_id = g2;
  IF n = 1 THEN pass:=pass+1; rep:=rep||E'\n[20] OK  get_best_matching_groups ya devuelve al compuesto; el incompatible: '
    ||(SELECT COUNT(*) FROM public.get_best_matching_groups(reqB, 100, 0, '{}'::uuid[]) t2 WHERE t2.group_id = g9)::text||' (debe ser 0)';
  ELSE fail:=fail+1; rep:=rep||E'\n[20] FAIL get_best_matching_groups no devuelve al compuesto'; END IF;

  rep := rep || E'\n\n(notificaciones en la tabla antes de la suite: '||notif_ini||
                ' — el ROLLBACK devuelve todo a ese estado; ningun grupo REAL fue alcanzado porque los generos de prueba son inventados)';

  RAISE EXCEPTION E'TEST_REPORT_717 (todo revertido)\nPASS=% FAIL=% %', pass, fail, COALESCE(rep,'(NULL)');
END
$suite$;

ROLLBACK;
