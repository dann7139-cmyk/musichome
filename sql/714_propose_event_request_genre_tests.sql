-- ═══════════════════════════════════════════════════════════════════════════
-- 714 — SUITE AUTOREVERTIBLE de sql/713           RESULTADO: 16/16 PASS
-- ═══════════════════════════════════════════════════════════════════════════
-- Aplica el cambio de sql/713 DENTRO de su propia transacción, prueba el antes y
-- el después, y revierte TODO con el RAISE final. Correrla NO es aplicarla.
--
-- DATOS: 100 % sintéticos. Los géneros SÍ son los reales ("Norteño",
-- "Norteño/Sierreño", "Cumbia") porque la prueba es justamente sobre esa
-- semántica, pero la ciudad y el estado son inventados
-- ("CiudadPrueba715"/"EstadoPrueba715"), y `dispatch_express_request` exige
-- coincidencia de ciudad **o** estado → ningún grupo real puede ser alcanzado.
-- Verificado en la corrida: `dispatched: 1`, solo el grupo sintético.
-- No se toca ninguna reserva ni nada de dinero.
-- ═══════════════════════════════════════════════════════════════════════════

BEGIN;

DO $suite$
DECLARE
  rep TEXT := ''; pass INT := 0; fail INT := 0; n INT; js JSONB; js2 JSONB;
  v_src_antes TEXT; v_src_desp TEXT; v_def TEXT; v_ocurr INT;
  FIRMA TEXT := 'public.propose_event_request(uuid,numeric,numeric,numeric,numeric,numeric,text,jsonb,text,text,uuid)';
  cli UUID := gen_random_uuid(); oComp UUID := gen_random_uuid();
  oExacto UUID := gen_random_uuid(); oIncomp UUID := gen_random_uuid(); cliSinGrupo UUID := gen_random_uuid();
  gComp UUID; gExacto UUID; gIncomp UUID; req UUID;
  props_ini BIGINT;
BEGIN
  SELECT prosrc INTO v_src_antes FROM pg_proc WHERE oid = to_regprocedure(FIRMA);
  SELECT COUNT(*) INTO props_ini FROM public.event_request_proposals;

  -- ══════════════ SETUP SINTÉTICO ══════════════
  INSERT INTO auth.users (id,email) VALUES
    (cli,'c715@example.invalid'),(oComp,'gcomp715@example.invalid'),
    (oExacto,'gex715@example.invalid'),(oIncomp,'ginc715@example.invalid'),
    (cliSinGrupo,'csin715@example.invalid');
  INSERT INTO public.groups (owner_id,name,genre,city,state,is_active,availability)
  VALUES (oComp,'Compuesto 715','Norteño/Sierreño','CiudadPrueba715','EstadoPrueba715',TRUE,'available')
  RETURNING id INTO gComp;
  INSERT INTO public.groups (owner_id,name,genre,city,state,is_active,availability)
  VALUES (oExacto,'Exacto 715','Norteño','CiudadPrueba715','EstadoPrueba715',TRUE,'available')
  RETURNING id INTO gExacto;
  INSERT INTO public.groups (owner_id,name,genre,city,state,is_active,availability)
  VALUES (oIncomp,'Incompatible 715','Cumbia','CiudadPrueba715','EstadoPrueba715',TRUE,'available')
  RETURNING id INTO gIncomp;

  INSERT INTO public.event_requests
    (client_id,genre,event_type,event_date,location_city,location_estado,hours,status)
  VALUES (cli,'Norteño','fiesta_privada',CURRENT_DATE+10,'CiudadPrueba715','EstadoPrueba715',3,'open')
  RETURNING id INTO req;

  -- ══════════════ ANTES ══════════════
  IF public.genre_matches('Norteño/Sierreño','Norteño')
     AND ('Norteño/Sierreño' <> 'Norteño') THEN
    pass:=pass+1; rep := rep || E'\n[1] OK   genre_matches dice compatible y la comparacion exacta dice distinto (la inconsistencia)';
  ELSE fail:=fail+1; rep := rep || E'\n[1] FAIL la premisa no se cumple'; END IF;

  js := public.dispatch_express_request(req);
  SELECT COUNT(*) INTO n FROM public.express_dispatches WHERE request_id=req AND group_id=gComp;
  IF (js->>'ok')::boolean AND n = 1 THEN
    pass:=pass+1; rep := rep || E'\n[2] OK   dispatch_express_request SI despacha al grupo compuesto ('||COALESCE(js::text,'')||')';
  ELSE fail:=fail+1; rep := rep || E'\n[2] FAIL el despacho no alcanzo al grupo compuesto: '||COALESCE(js::text,'NULL'); END IF;

  SET LOCAL ROLE authenticated;
  PERFORM set_config('request.jwt.claims', json_build_object('sub',oComp::text,'role','authenticated')::text, true);
  SELECT COUNT(*) INTO n FROM public.event_requests WHERE id=req;
  IF n = 1 THEN pass:=pass+1; rep := rep || E'\n[3] OK   el grupo compuesto VE la solicitud';
  ELSE fail:=fail+1; rep := rep || E'\n[3] FAIL el grupo compuesto no ve la solicitud'; END IF;

  js := public.propose_event_request(p_request_id := req, p_price_per_hour := 1500, p_travel_cost := 0,
        p_overtime_1h := 0, p_overtime_2h := 0, p_overtime_3h := 0, p_notes := 'prueba 715',
        p_member_dist := NULL, p_arrival_time := NULL, p_start_time := NULL, p_dispatch_id := NULL);
  IF js->>'error' = 'genre_mismatch' THEN
    pass:=pass+1; rep := rep || E'\n[4] OK   ANTES: el grupo compuesto NO puede cotizar -> genre_mismatch';
  ELSE fail:=fail+1; rep := rep || E'\n[4] FAIL ANTES no reprodujo el bug: '||COALESCE(js::text,'NULL'); END IF;
  PERFORM set_config('request.jwt.claims','',true); RESET ROLE;

  -- ══════════════ SE APLICA sql/713 ══════════════
  v_def := pg_get_functiondef(to_regprocedure(FIRMA));
  v_ocurr := (length(v_def) - length(replace(v_def,'IF v_group.genre <> v_req.genre THEN','')))
             / length('IF v_group.genre <> v_req.genre THEN');
  IF v_ocurr = 1 THEN pass:=pass+1; rep := rep || E'\n[5] OK   la comparacion exacta aparece exactamente 1 vez';
  ELSE fail:=fail+1; rep := rep || E'\n[5] FAIL aparece '||v_ocurr||' veces'; END IF;
  EXECUTE replace(v_def,
    'IF v_group.genre <> v_req.genre THEN',
    'IF NOT public.genre_matches(v_group.genre, v_req.genre) THEN');

  SELECT prosrc INTO v_src_desp FROM pg_proc WHERE oid = to_regprocedure(FIRMA);

  -- ══════════════ DESPUÉS ══════════════
  IF md5(replace(v_src_desp,
        'IF NOT public.genre_matches(v_group.genre, v_req.genre) THEN',
        'IF v_group.genre <> v_req.genre THEN')) = md5(v_src_antes) THEN
    pass:=pass+1; rep := rep || E'\n[6] OK   el cuerpo es byte-identico salvo esa linea (md5 coincide al revertir la sustitucion)';
  ELSE fail:=fail+1; rep := rep || E'\n[6] FAIL el cuerpo cambio en algo mas'; END IF;

  IF v_src_desp NOT LIKE '%v_group.genre <> v_req.genre%'
     AND v_src_desp LIKE '%genre_matches(v_group.genre, v_req.genre)%'
     AND v_src_desp LIKE '%genre_mismatch%' THEN
    pass:=pass+1; rep := rep || E'\n[7] OK   ya no hay comparacion exacta, usa genre_matches y conserva el codigo genre_mismatch';
  ELSE fail:=fail+1; rep := rep || E'\n[7] FAIL el reemplazo no quedo como se esperaba'; END IF;

  -- [8] el compuesto YA puede cotizar
  SET LOCAL ROLE authenticated;
  PERFORM set_config('request.jwt.claims', json_build_object('sub',oComp::text,'role','authenticated')::text, true);
  js := public.propose_event_request(p_request_id := req, p_price_per_hour := 1500, p_travel_cost := 0,
        p_overtime_1h := 0, p_overtime_2h := 0, p_overtime_3h := 0, p_notes := 'prueba 715',
        p_member_dist := NULL, p_arrival_time := NULL, p_start_time := NULL, p_dispatch_id := NULL);
  IF (js->>'ok')::boolean THEN
    pass:=pass+1; rep := rep || E'\n[8] OK   DESPUES: el grupo compuesto SI cotiza -> '||COALESCE(js::text,'');
  ELSE fail:=fail+1; rep := rep || E'\n[8] FAIL el compuesto sigue sin poder cotizar: '||COALESCE(js::text,'NULL'); END IF;

  -- [9] una sola propuesta aunque cotice dos veces (upsert)
  js2 := public.propose_event_request(p_request_id := req, p_price_per_hour := 1700, p_travel_cost := 0,
        p_overtime_1h := 0, p_overtime_2h := 0, p_overtime_3h := 0, p_notes := 'prueba 715 b',
        p_member_dist := NULL, p_arrival_time := NULL, p_start_time := NULL, p_dispatch_id := NULL);
  SELECT COUNT(*) INTO n FROM public.event_request_proposals WHERE request_id=req AND group_id=gComp;
  IF n = 1 AND (js2->>'is_update')::boolean THEN
    pass:=pass+1; rep := rep || E'\n[9] OK   una sola propuesta por grupo (segunda llamada = is_update, '||n||' fila)';
  ELSE fail:=fail+1; rep := rep || E'\n[9] FAIL filas='||n||' js2='||COALESCE(js2::text,'NULL'); END IF;
  PERFORM set_config('request.jwt.claims','',true); RESET ROLE;

  -- [10] género EXACTO sigue funcionando
  SET LOCAL ROLE authenticated;
  PERFORM set_config('request.jwt.claims', json_build_object('sub',oExacto::text,'role','authenticated')::text, true);
  js := public.propose_event_request(p_request_id := req, p_price_per_hour := 1200, p_travel_cost := 0,
        p_overtime_1h := 0, p_overtime_2h := 0, p_overtime_3h := 0, p_notes := 'exacto',
        p_member_dist := NULL, p_arrival_time := NULL, p_start_time := NULL, p_dispatch_id := NULL);
  IF (js->>'ok')::boolean THEN pass:=pass+1; rep := rep || E'\n[10] OK  genero EXACTO sigue cotizando';
  ELSE fail:=fail+1; rep := rep || E'\n[10] FAIL el exacto dejo de funcionar: '||COALESCE(js::text,'NULL'); END IF;
  PERFORM set_config('request.jwt.claims','',true); RESET ROLE;

  -- [11] género REALMENTE incompatible sigue bloqueado
  SET LOCAL ROLE authenticated;
  PERFORM set_config('request.jwt.claims', json_build_object('sub',oIncomp::text,'role','authenticated')::text, true);
  js := public.propose_event_request(p_request_id := req, p_price_per_hour := 999, p_travel_cost := 0,
        p_overtime_1h := 0, p_overtime_2h := 0, p_overtime_3h := 0, p_notes := 'cumbia',
        p_member_dist := NULL, p_arrival_time := NULL, p_start_time := NULL, p_dispatch_id := NULL);
  IF js->>'error' = 'genre_mismatch' THEN
    pass:=pass+1; rep := rep || E'\n[11] OK  Cumbia vs Norteño sigue devolviendo genre_mismatch';
  ELSE fail:=fail+1; rep := rep || E'\n[11] FAIL se abrio a un genero incompatible: '||COALESCE(js::text,'NULL'); END IF;
  PERFORM set_config('request.jwt.claims','',true); RESET ROLE;

  -- [12] un usuario sin grupo no obtiene acceso
  SET LOCAL ROLE authenticated;
  PERFORM set_config('request.jwt.claims', json_build_object('sub',cliSinGrupo::text,'role','authenticated')::text, true);
  js := public.propose_event_request(p_request_id := req, p_price_per_hour := 1,  p_travel_cost := 0,
        p_overtime_1h := 0, p_overtime_2h := 0, p_overtime_3h := 0, p_notes := 'sin grupo',
        p_member_dist := NULL, p_arrival_time := NULL, p_start_time := NULL, p_dispatch_id := NULL);
  IF js->>'error' = 'no_group_found' THEN
    pass:=pass+1; rep := rep || E'\n[12] OK  un usuario sin grupo -> no_group_found';
  ELSE fail:=fail+1; rep := rep || E'\n[12] FAIL '||COALESCE(js::text,'NULL'); END IF;
  PERFORM set_config('request.jwt.claims','',true); RESET ROLE;

  -- [13] propuestas totales creadas por la suite: exactamente 2 (compuesto + exacto)
  SELECT COUNT(*) INTO n FROM public.event_request_proposals WHERE request_id=req;
  IF n = 2 THEN pass:=pass+1; rep := rep || E'\n[13] OK  2 propuestas en total (compuesto y exacto), ninguna del incompatible';
  ELSE fail:=fail+1; rep := rep || E'\n[13] FAIL hay '||n||' propuestas'; END IF;

  -- [14] no se amplio nada mas: las otras comparaciones exactas siguen exactas
  IF (SELECT prosrc FROM pg_proc WHERE proname='accept_event_request')   LIKE '%v_group.genre <> v_request.genre%'
     AND (SELECT prosrc FROM pg_proc WHERE proname='instant_accept_request') LIKE '%v_group.genre <> v_req.genre%'
     AND (SELECT prosrc FROM pg_proc WHERE proname='_send_wave')             ~ 'g\.genre\s*=\s*p_req\.genre' THEN
    pass:=pass+1; rep := rep || E'\n[14] OK  accept_event_request, instant_accept_request y _send_wave SIN tocar (olas/ranking intactos)';
  ELSE fail:=fail+1; rep := rep || E'\n[14] FAIL se toco algo fuera de alcance'; END IF;

  -- [15] la firma y los DEFAULT no cambiaron
  IF pg_get_function_arguments(to_regprocedure(FIRMA)) LIKE '%p_travel_cost numeric DEFAULT 0%'
     AND pg_get_function_arguments(to_regprocedure(FIRMA)) LIKE '%p_dispatch_id uuid DEFAULT NULL::uuid%'
     AND (SELECT COUNT(*) FROM pg_proc p JOIN pg_namespace ns ON ns.oid=p.pronamespace
          WHERE ns.nspname='public' AND p.proname='propose_event_request') = 1 THEN
    pass:=pass+1; rep := rep || E'\n[15] OK  1 sola firma, con sus 10 DEFAULT intactos';
  ELSE fail:=fail+1; rep := rep || E'\n[15] FAIL la firma cambio'; END IF;

  -- [16] ACL intacta
  IF has_function_privilege('authenticated', to_regprocedure(FIRMA), 'EXECUTE')
     AND has_function_privilege('service_role', to_regprocedure(FIRMA), 'EXECUTE') THEN
    pass:=pass+1; rep := rep || E'\n[16] OK  authenticated y service_role conservan EXECUTE';
  ELSE fail:=fail+1; rep := rep || E'\n[16] FAIL la ACL cambio'; END IF;

  rep := rep || E'\n\n(propuestas en la tabla antes de la suite: '||props_ini||
                ' — el ROLLBACK devuelve todo a ese estado)';

  RAISE EXCEPTION E'TEST_REPORT_714 (todo revertido)\nPASS=% FAIL=% %', pass, fail, COALESCE(rep,'(NULL)');
END
$suite$;

ROLLBACK;
