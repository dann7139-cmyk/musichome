-- ═══════════════════════════════════════════════════════════════════════════
-- 712 — SUITE AUTOREVERTIBLE de sql/710 + sql/711        RESULTADO: 36/36 PASS
-- ═══════════════════════════════════════════════════════════════════════════
-- Aplica las DOS migraciones DENTRO de su propia transacción, prueba, y revierte
-- TODO con el RAISE final. Correrla NO es aplicarlas.
--
-- DATOS: 100 % sintéticos, creados dentro de la transacción. Ningún usuario,
-- grupo, solicitud, reserva o pago real participa. Los géneros de prueba
-- ('GeneroPrueba712', 'OtroPrueba712', 'SinRelacion712') no coinciden con
-- ninguno de los 4 géneros reales (Cumbia, Norteño, Norteño/Sierreño, Sierreño),
-- así que `_send_wave` no puede alcanzar a ningún grupo real.
-- NO se crea ninguna reserva: insertar en `reservations` dispara 34 triggers,
-- varios de dinero (comisión, financials, payouts), y eso está prohibido. Por eso
-- `er_group_reservation_select` se valida de forma estructural (existe, compila, y
-- es la única policy que referencia `reservations`), mientras que la lectura del
-- timer se prueba por su otra vía real, `er_group_accepted_select` → prueba [24].
--
-- DETALLES QUE HICIERON FALTA (medidos, no supuestos):
--  · La firma real de `notify_wave_1` tiene **4 DEFAULT** (`p_event_lat` y
--    `p_event_lng` NULL, `p_radius_km` 50, `p_use_radius_expansion` false).
--    Omitir uno hace fallar el CREATE OR REPLACE con 42P13.
--  · Los triggers AFTER INSERT de `event_requests` (`notify_groups_in_zone` /
--    smart matching) YA crean 1 notificación para el grupo elegible, y
--    `_send_wave` no re-notifica a quien ya tiene una de esa solicitud. Por eso el
--    setup limpia ese ruido antes de medir la ola.
--  · Las cuentas de `notifications` se miden como `postgres`: un `authenticated`
--    no ve las notificaciones de otro usuario.
--  · La prueba [25] documenta una regla VIGENTE que **no** se cambia: por
--    `sql/217`, un proveedor ve todas las solicitudes ABIERTAS, también de otros
--    géneros ("Fuera de la ventana → visible a todos"). Lo que sql/710 corrige ahí
--    es que ese permiso exigía además tener un grupo.
-- ═══════════════════════════════════════════════════════════════════════════

BEGIN;

DO $suite$
DECLARE
  r     TEXT := ''; pass INT := 0; fail INT := 0; n INT; st TEXT;
  js JSONB; js2 JSONB; v_txt TEXT;
  uA UUID := gen_random_uuid(); uB UUID := gen_random_uuid(); uC UUID := gen_random_uuid();
  uD UUID := gen_random_uuid(); uE UUID := gen_random_uuid(); uF UUID := gen_random_uuid();
  uH UUID := gen_random_uuid(); uG UUID := gen_random_uuid(); uGW UUID := gen_random_uuid();
  gSPLIT UUID; gWAVE UUID;
  qA UUID; qB UUID; qC UUID; qD UUID; qE UUID; qF UUID; qH UUID; qNEG UUID; qAW UUID; qDEAD UUID;
  notif_ini BIGINT; notif_1 BIGINT; notif_2 BIGINT;
BEGIN
  INSERT INTO auth.users (id, email) VALUES
    (uA,'a712@example.invalid'),(uB,'b712@example.invalid'),(uC,'c712@example.invalid'),
    (uD,'d712@example.invalid'),(uE,'e712@example.invalid'),(uF,'f712@example.invalid'),
    (uH,'h712@example.invalid'),(uG,'g712@example.invalid'),(uGW,'gw712@example.invalid');
  INSERT INTO public.groups (owner_id,name,genre,is_active,availability)
  VALUES (uG,'GrupoPrueba712 split','GeneroPrueba712/OtroPrueba712',TRUE,'available') RETURNING id INTO gSPLIT;
  INSERT INTO public.groups (owner_id,name,genre,is_active,availability)
  VALUES (uGW,'GrupoPrueba712 wave','GeneroPrueba712',TRUE,'available') RETURNING id INTO gWAVE;

  INSERT INTO public.event_requests (client_id,genre,event_type,event_date,location_city,location_estado,hours,status)
  VALUES (uA,'OtroPrueba712','fiesta_privada',CURRENT_DATE+30,'Ciudad712','Estado712',3,'open') RETURNING id INTO qA;
  INSERT INTO public.event_requests (client_id,genre,event_type,event_date,location_city,location_estado,hours,status)
  VALUES (uA,'GeneroPrueba712','fiesta_privada',CURRENT_DATE+31,'Ciudad712','Estado712',3,'open') RETURNING id INTO qAW;
  INSERT INTO public.event_requests (client_id,genre,event_type,event_date,location_city,location_estado,hours,status)
  VALUES (uB,'GeneroPrueba712','fiesta_privada',CURRENT_DATE+32,'Ciudad712','Estado712',3,'open') RETURNING id INTO qB;
  INSERT INTO public.event_requests (client_id,genre,event_type,event_date,location_city,location_estado,hours,status)
  VALUES (uC,'GeneroPrueba712','fiesta_privada',CURRENT_DATE+33,'Ciudad712','Estado712',3,'open') RETURNING id INTO qC;
  INSERT INTO public.event_requests (client_id,genre,event_type,event_date,location_city,location_estado,hours,status)
  VALUES (uD,'GeneroPrueba712','fiesta_privada',CURRENT_DATE+34,'Ciudad712','Estado712',3,'open') RETURNING id INTO qD;
  INSERT INTO public.event_requests (client_id,genre,event_type,event_date,location_city,location_estado,hours,status)
  VALUES (uE,'OtroPrueba712','fiesta_privada',CURRENT_DATE+35,'Ciudad712','Estado712',3,'open') RETURNING id INTO qE;
  UPDATE public.event_requests SET status='en_negociacion' WHERE id=qE;
  INSERT INTO public.event_requests (client_id,genre,event_type,event_date,location_city,location_estado,hours,status)
  VALUES (uE,'SinRelacion712','fiesta_privada',CURRENT_DATE+39,'Ciudad712','Estado712',3,'open') RETURNING id INTO qDEAD;
  UPDATE public.event_requests SET status='cancelled' WHERE id=qDEAD;
  INSERT INTO public.event_requests (client_id,genre,event_type,event_date,location_city,location_estado,hours,status)
  VALUES (uF,'SinRelacion712','fiesta_privada',CURRENT_DATE+36,'Ciudad712','Estado712',3,'open') RETURNING id INTO qF;
  UPDATE public.event_requests SET status='cancelled' WHERE id=qF;
  INSERT INTO public.express_dispatches (request_id,group_id,status) VALUES (qF,gSPLIT,'taken');
  INSERT INTO public.event_requests (client_id,genre,event_type,event_date,location_city,location_estado,hours,status)
  VALUES (uH,'SinRelacion712','fiesta_privada',CURRENT_DATE+37,'Ciudad712','Estado712',3,'open') RETURNING id INTO qH;
  UPDATE public.event_requests SET status='accepted', accepted_by_group_id=gSPLIT WHERE id=qH;
  INSERT INTO public.event_requests (client_id,genre,event_type,event_date,location_city,location_estado,hours,status)
  VALUES (uB,'SinRelacion712','fiesta_privada',CURRENT_DATE+38,'Ciudad712','Estado712',3,'open') RETURNING id INTO qNEG;

  SELECT COUNT(*) INTO n FROM public.notifications WHERE data->>'request_id' = qAW::text;
  DELETE FROM public.notifications WHERE data->>'request_id' = qAW::text;
  r := r || E'\nsetup: 9 usuarios, 2 grupos, 10 solicitudes; limpiadas '||n||' notificaciones que los triggers del INSERT ya habian creado para la solicitud de prueba de la ola';

  -- ══════════════ ESTADO ANTES: LOS AGUJEROS EXISTEN ══════════════
  SET LOCAL ROLE anon;  SELECT COUNT(*) INTO n FROM public.event_requests;  RESET ROLE;
  IF n > 0 THEN pass:=pass+1; r := r || E'\n[1] OK   ANTES: anon veia '||n||' solicitudes';
  ELSE fail:=fail+1; r := r || E'\n[1] FAIL ANTES: anon ya no veia nada'; END IF;

  SET LOCAL ROLE authenticated;
  PERFORM set_config('request.jwt.claims', json_build_object('sub',uB::text,'role','authenticated')::text, true);
  UPDATE public.event_requests SET genre='B_LA_TOCO' WHERE id=qA;  GET DIAGNOSTICS n = ROW_COUNT;
  PERFORM set_config('request.jwt.claims','',true);  RESET ROLE;
  UPDATE public.event_requests SET genre='OtroPrueba712' WHERE id=qA;
  IF n = 1 THEN pass:=pass+1; r := r || E'\n[2] OK   ANTES: el cliente B modificaba la solicitud de A';
  ELSE fail:=fail+1; r := r || E'\n[2] FAIL ANTES: B no pudo modificar la de A'; END IF;

  SET LOCAL ROLE authenticated;
  PERFORM set_config('request.jwt.claims', json_build_object('sub',uA::text,'role','authenticated')::text, true);
  SELECT COUNT(*) INTO n FROM public.event_requests WHERE id=qB;
  PERFORM set_config('request.jwt.claims','',true);  RESET ROLE;
  IF n = 1 THEN pass:=pass+1; r := r || E'\n[3] OK   ANTES: el cliente A leia la solicitud abierta de B';
  ELSE fail:=fail+1; r := r || E'\n[3] FAIL ANTES: A no leia la de B'; END IF;

  -- ══════════════ SE APLICA sql/710 ══════════════
  DROP POLICY "er_service_all" ON public.event_requests;
  CREATE POLICY "er_service_all" ON public.event_requests FOR ALL TO service_role USING (true) WITH CHECK (true);
  CREATE POLICY "er_group_genre_split_select" ON public.event_requests FOR SELECT TO authenticated
    USING (status = ANY (ARRAY['open'::text,'en_negociacion'::text]) AND expires_at > now()
      AND EXISTS (SELECT 1 FROM public.groups g WHERE g.owner_id = auth.uid()
          AND lower(btrim(event_requests.genre)) = ANY (
                SELECT lower(btrim(x)) FROM unnest(string_to_array(g.genre,'/')) AS x)));
  CREATE POLICY "er_group_dispatched_select" ON public.event_requests FOR SELECT TO authenticated
    USING (EXISTS (SELECT 1 FROM public.express_dispatches ed JOIN public.groups g ON g.id=ed.group_id
                   WHERE ed.request_id = event_requests.id AND g.owner_id = auth.uid()));
  CREATE POLICY "er_group_reservation_select" ON public.event_requests FOR SELECT TO authenticated
    USING (EXISTS (SELECT 1 FROM public.reservations rr JOIN public.groups g ON g.id=rr.group_id
                   WHERE rr.event_request_id = event_requests.id AND g.owner_id = auth.uid()));
  DROP POLICY "groups_see_open_requests" ON public.event_requests;
  CREATE POLICY "groups_see_open_requests" ON public.event_requests FOR SELECT TO authenticated
    USING (status = 'open' AND expires_at > now()
      AND EXISTS (SELECT 1 FROM public.groups g2 WHERE g2.owner_id = auth.uid())
      AND (express_window_until IS NULL OR express_window_until < now()
        OR EXISTS (SELECT 1 FROM public.express_dispatches ed JOIN public.groups g ON g.id=ed.group_id
                   WHERE ed.request_id = event_requests.id AND g.owner_id = auth.uid()
                     AND ed.status <> ALL (ARRAY['ignored'::text,'expired'::text,'taken'::text]))));
  REVOKE SELECT, INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON public.event_requests FROM anon;

  -- ══════════════ SE APLICA sql/711 ══════════════
  EXECUTE $ddl$
    CREATE OR REPLACE FUNCTION public.notify_wave_1(
      p_request_id UUID,
      p_event_lat DOUBLE PRECISION DEFAULT NULL::double precision,
      p_event_lng DOUBLE PRECISION DEFAULT NULL::double precision,
      p_radius_km DOUBLE PRECISION DEFAULT 50,
      p_use_radius_expansion BOOLEAN DEFAULT false)
    RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
    AS $fn$
    DECLARE
      v_req RECORD; v_sent INT; v_urgent BOOLEAN; v_initial_radius DOUBLE PRECISION;
      v_uid UUID; v_role TEXT;
    BEGIN
      v_uid  := auth.uid();
      v_role := COALESCE(auth.role(), '');
      IF v_uid IS NOT NULL THEN
        SELECT * INTO v_req FROM public.event_requests WHERE id = p_request_id AND client_id = v_uid;
      ELSIF v_role = 'service_role' OR v_role = '' THEN
        SELECT * INTO v_req FROM public.event_requests WHERE id = p_request_id;
      ELSE
        RETURN jsonb_build_object('ok', false, 'error', 'unauthorized');
      END IF;
      IF NOT FOUND THEN RETURN jsonb_build_object('ok', false, 'error', 'request_not_found'); END IF;
      IF v_req.current_wave > 0 THEN RETURN jsonb_build_object('ok', false, 'error', 'wave_already_started'); END IF;
      v_initial_radius := CASE WHEN p_use_radius_expansion THEN 5.0 ELSE p_radius_km END;
      v_urgent := (v_req.event_date::TIMESTAMP +
        COALESCE((v_req.event_time)::INTERVAL, INTERVAL '0') - NOW()) < INTERVAL '6 hours';
      UPDATE public.event_requests
      SET event_lat=p_event_lat, event_lng=p_event_lng, radius_km=v_initial_radius,
          use_radius_expansion=p_use_radius_expansion, current_wave=1, wave1_sent_at=NOW()
      WHERE id = p_request_id;
      SELECT * INTO v_req FROM public.event_requests WHERE id = p_request_id;
      v_sent := _send_wave(v_req, 0, 3, v_urgent);
      UPDATE public.event_requests SET notified_count = notified_count + v_sent WHERE id = p_request_id;
      RETURN jsonb_build_object('ok',true,'wave',1,'notified',v_sent,'urgent',v_urgent,
        'initial_radius_km',v_initial_radius,'use_radius_expansion',p_use_radius_expansion);
    EXCEPTION WHEN OTHERS THEN RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
    END;
    $fn$;
  $ddl$;
  EXECUTE 'REVOKE EXECUTE ON FUNCTION public.notify_wave_1(uuid,double precision,double precision,double precision,boolean) FROM PUBLIC';
  EXECUTE 'REVOKE EXECUTE ON FUNCTION public.notify_wave_1(uuid,double precision,double precision,double precision,boolean) FROM anon';
  EXECUTE 'GRANT EXECUTE ON FUNCTION public.notify_wave_1(uuid,double precision,double precision,double precision,boolean) TO authenticated, service_role';

  SELECT COUNT(*) INTO n FROM pg_policy WHERE polrelid='public.event_requests'::regclass;
  IF n = 11 AND NOT EXISTS (SELECT 1 FROM pg_policy
        WHERE polrelid='public.event_requests'::regclass AND polname='er_service_all' AND polroles='{0}')
  THEN pass:=pass+1; r := r || E'\n[4] OK   11 policies y er_service_all ya NO aplica a PUBLIC';
  ELSE fail:=fail+1; r := r || E'\n[4] FAIL policies='||COALESCE(n::text,'NULL'); END IF;

  -- ══════════════ ANON: nada ══════════════
  SET LOCAL ROLE anon;
  st:='sin_error'; BEGIN SELECT COUNT(*) INTO n FROM public.event_requests;
  EXCEPTION WHEN OTHERS THEN st := SQLSTATE; END;
  IF st='42501' THEN pass:=pass+1; r := r || E'\n[5] OK   anon NO puede SELECT (42501)';
  ELSE fail:=fail+1; r := r || E'\n[5] FAIL anon leyo ('||COALESCE(st,'NULL')||')'; END IF;
  st:='sin_error'; BEGIN
    INSERT INTO public.event_requests (client_id,genre,event_type,event_date,location_city,location_estado,hours)
    VALUES (uA,'AnonInventada','otro',CURRENT_DATE+40,'X','Y',2);
  EXCEPTION WHEN OTHERS THEN st := SQLSTATE; END;
  IF st='42501' THEN pass:=pass+1; r := r || E'\n[6] OK   anon NO puede INSERT (42501)';
  ELSE fail:=fail+1; r := r || E'\n[6] FAIL anon: '||COALESCE(st,'NULL'); END IF;
  st:='sin_error'; BEGIN UPDATE public.event_requests SET genre='X' WHERE id=qA;
  EXCEPTION WHEN OTHERS THEN st := SQLSTATE; END;
  IF st='42501' THEN pass:=pass+1; r := r || E'\n[7] OK   anon NO puede UPDATE (42501)';
  ELSE fail:=fail+1; r := r || E'\n[7] FAIL anon: '||COALESCE(st,'NULL'); END IF;
  st:='sin_error'; BEGIN DELETE FROM public.event_requests WHERE id=qA;
  EXCEPTION WHEN OTHERS THEN st := SQLSTATE; END;
  IF st='42501' THEN pass:=pass+1; r := r || E'\n[8] OK   anon NO puede DELETE (42501)';
  ELSE fail:=fail+1; r := r || E'\n[8] FAIL anon: '||COALESCE(st,'NULL'); END IF;
  st:='sin_error'; BEGIN PERFORM public.notify_wave_1(qA,19.0,-99.0,50,false);
  EXCEPTION WHEN OTHERS THEN st := SQLSTATE; END;
  RESET ROLE;
  IF st='42501' THEN pass:=pass+1; r := r || E'\n[9] OK   anon NO puede ejecutar notify_wave_1 (42501)';
  ELSE fail:=fail+1; r := r || E'\n[9] FAIL anon ejecuto la RPC ('||COALESCE(st,'NULL')||')'; END IF;

  -- ══════════════ CLIENTE A ══════════════
  SET LOCAL ROLE authenticated;
  PERFORM set_config('request.jwt.claims', json_build_object('sub',uA::text,'role','authenticated')::text, true);
  SELECT COUNT(*) INTO n FROM public.event_requests WHERE id=qA;
  IF n=1 THEN pass:=pass+1; r := r || E'\n[10] OK  A lee su propia solicitud';
  ELSE fail:=fail+1; r := r || E'\n[10] FAIL A no lee la suya'; END IF;
  UPDATE public.event_requests SET comments='nota de A' WHERE id=qA; GET DIAGNOSTICS n = ROW_COUNT;
  IF n=1 THEN pass:=pass+1; r := r || E'\n[11] OK  A actualiza su propia solicitud';
  ELSE fail:=fail+1; r := r || E'\n[11] FAIL A no pudo actualizar la suya'; END IF;
  SELECT COUNT(*) INTO n FROM public.event_requests WHERE id=qB;
  IF n=0 THEN pass:=pass+1; r := r || E'\n[12] OK  A NO lee la solicitud de B';
  ELSE fail:=fail+1; r := r || E'\n[12] FAIL A lee la de B'; END IF;
  UPDATE public.event_requests SET genre='A_LA_TOCO' WHERE id=qB; GET DIAGNOSTICS n = ROW_COUNT;
  IF n=0 THEN pass:=pass+1; r := r || E'\n[13] OK  A NO modifica la de B (0 filas)';
  ELSE fail:=fail+1; r := r || E'\n[13] FAIL A modifico la de B'; END IF;
  DELETE FROM public.event_requests WHERE id=qB; GET DIAGNOSTICS n = ROW_COUNT;
  IF n=0 THEN pass:=pass+1; r := r || E'\n[14] OK  A NO borra la de B (0 filas)';
  ELSE fail:=fail+1; r := r || E'\n[14] FAIL A borro la de B'; END IF;
  js := public.notify_wave_1(qC,19.0,-99.0,50,false);
  IF js->>'error'='request_not_found' THEN pass:=pass+1; r := r || E'\n[15] OK  A NO puede lanzar la ola de C -> request_not_found';
  ELSE fail:=fail+1; r := r || E'\n[15] FAIL A lanzo la ola ajena: '||COALESCE(js::text,'NULL'); END IF;
  js2 := public.notify_wave_1(gen_random_uuid(),19.0,-99.0,50,false);
  IF js2->>'error'='request_not_found' AND js2::text = js::text THEN
    pass:=pass+1; r := r || E'\n[16] OK  id inventado devuelve lo MISMO que el ajeno -> sin enumeracion';
  ELSE fail:=fail+1; r := r || E'\n[16] FAIL ajeno='||COALESCE(js::text,'NULL')||' inventado='||COALESCE(js2::text,'NULL'); END IF;
  PERFORM set_config('request.jwt.claims','',true);  RESET ROLE;

  -- ══════════════ OLA 1 PROPIA + SIN DUPLICADOS ══════════════
  SELECT COUNT(*) INTO notif_ini FROM public.notifications;
  SET LOCAL ROLE authenticated;
  PERFORM set_config('request.jwt.claims', json_build_object('sub',uA::text,'role','authenticated')::text, true);
  js := public.notify_wave_1(qAW,19.0,-99.0,50,false);
  PERFORM set_config('request.jwt.claims','',true);  RESET ROLE;
  SELECT COUNT(*) INTO notif_1 FROM public.notifications;
  IF (js->>'ok')::boolean AND (js->>'notified')::int = 1 AND (js->>'wave')::int = 1 THEN
    pass:=pass+1; r := r || E'\n[17] OK  A SI lanza su propia ola: '||COALESCE(js::text,'NULL');
  ELSE fail:=fail+1; r := r || E'\n[17] FAIL A no pudo lanzar la suya: '||COALESCE(js::text,'NULL'); END IF;

  SET LOCAL ROLE authenticated;
  PERFORM set_config('request.jwt.claims', json_build_object('sub',uA::text,'role','authenticated')::text, true);
  js2 := public.notify_wave_1(qAW,19.0,-99.0,50,false);
  PERFORM set_config('request.jwt.claims','',true);  RESET ROLE;
  SELECT COUNT(*) INTO notif_2 FROM public.notifications;
  IF js2->>'error'='wave_already_started' AND notif_2 = notif_1 THEN
    pass:=pass+1; r := r || E'\n[18] OK  segunda llamada: wave_already_started y 0 notificaciones nuevas';
  ELSE fail:=fail+1; r := r || E'\n[18] FAIL '||COALESCE(js2::text,'NULL')||' notifs '||notif_1||'->'||notif_2; END IF;
  IF notif_1 = notif_ini + 1 THEN
    pass:=pass+1; r := r || E'\n[19] OK  la ola creo exactamente 1 notificacion ('||notif_ini||' -> '||notif_1||'), para el grupo sintetico';
  ELSE fail:=fail+1; r := r || E'\n[19] FAIL notificaciones '||notif_ini||' -> '||notif_1; END IF;

  SELECT current_wave INTO n FROM public.event_requests WHERE id=qC;
  IF n=0 THEN pass:=pass+1; r := r || E'\n[20] OK  la solicitud de C sigue con current_wave=0 (A no la quemo)';
  ELSE fail:=fail+1; r := r || E'\n[20] FAIL la ajena quedo en current_wave='||COALESCE(n::text,'NULL'); END IF;

  -- ══════════════ PROVEEDOR ══════════════
  SET LOCAL ROLE authenticated;
  PERFORM set_config('request.jwt.claims', json_build_object('sub',uG::text,'role','authenticated')::text, true);
  SELECT COUNT(*) INTO n FROM public.event_requests WHERE id=qA;
  IF n=1 THEN pass:=pass+1; r := r || E'\n[21] OK  proveedor ve la abierta de su genero compuesto';
  ELSE fail:=fail+1; r := r || E'\n[21] FAIL proveedor NO ve la abierta de su genero'; END IF;
  SELECT COUNT(*) INTO n FROM public.event_requests WHERE id=qE;
  IF n=1 THEN pass:=pass+1; r := r || E'\n[22] OK  proveedor ve la en_negociacion de su genero compuesto';
  ELSE fail:=fail+1; r := r || E'\n[22] FAIL proveedor NO ve la en_negociacion'; END IF;
  SELECT COUNT(*) INTO n FROM public.event_requests WHERE id=qF;
  IF n=1 THEN pass:=pass+1; r := r || E'\n[23] OK  proveedor ve la que le despacharon (aun cancelada)';
  ELSE fail:=fail+1; r := r || E'\n[23] FAIL proveedor NO ve su despacho express'; END IF;
  SELECT COUNT(*) INTO n FROM public.event_requests WHERE id=qH;
  IF n=1 THEN pass:=pass+1; r := r || E'\n[24] OK  proveedor ve la que acepto su grupo (lectura del timer)';
  ELSE fail:=fail+1; r := r || E'\n[24] FAIL proveedor NO ve la que acepto'; END IF;
  SELECT COUNT(*) INTO n FROM public.event_requests WHERE id=qNEG;
  IF n=1 THEN pass:=pass+1; r := r || E'\n[25] OK  proveedor sigue viendo las ABIERTAS de otro genero (regla vigente de sql/217, sin cambio)';
  ELSE fail:=fail+1; r := r || E'\n[25] FAIL se perdio la visibilidad de abiertas que tenia sql/217'; END IF;
  SELECT COUNT(*) INTO n FROM public.event_requests WHERE id=qDEAD;
  IF n=0 THEN pass:=pass+1; r := r || E'\n[26] OK  proveedor NO ve una cancelada ajena sin despacho ni reserva';
  ELSE fail:=fail+1; r := r || E'\n[26] FAIL proveedor ve una cancelada que no le toca'; END IF;
  UPDATE public.event_requests SET genre='G_LA_TOCO' WHERE id=qA; GET DIAGNOSTICS n = ROW_COUNT;
  IF n=0 THEN pass:=pass+1; r := r || E'\n[27] OK  proveedor NO puede UPDATE (0 filas)';
  ELSE fail:=fail+1; r := r || E'\n[27] FAIL proveedor modifico una solicitud'; END IF;
  DELETE FROM public.event_requests WHERE id=qA; GET DIAGNOSTICS n = ROW_COUNT;
  IF n=0 THEN pass:=pass+1; r := r || E'\n[28] OK  proveedor NO puede DELETE (0 filas)';
  ELSE fail:=fail+1; r := r || E'\n[28] FAIL proveedor borro una solicitud'; END IF;
  js := public.notify_wave_1(qA,19.0,-99.0,50,false);
  IF js->>'error'='request_not_found' THEN pass:=pass+1; r := r || E'\n[29] OK  proveedor NO puede lanzar la ola de un cliente';
  ELSE fail:=fail+1; r := r || E'\n[29] FAIL proveedor lanzo una ola ajena: '||COALESCE(js::text,'NULL'); END IF;
  PERFORM set_config('request.jwt.claims','',true);  RESET ROLE;

  -- ══════════════ BACKEND ══════════════
  SET LOCAL ROLE service_role;
  PERFORM set_config('request.jwt.claims', json_build_object('role','service_role')::text, true);
  SELECT COUNT(*) INTO n FROM public.event_requests;
  js := public.notify_wave_1(qC,19.0,-99.0,50,false);
  PERFORM set_config('request.jwt.claims','',true);  RESET ROLE;
  IF n >= 10 THEN pass:=pass+1; r := r || E'\n[30] OK  service_role sigue viendo todas ('||COALESCE(n::text,'NULL')||')';
  ELSE fail:=fail+1; r := r || E'\n[30] FAIL service_role solo ve '||COALESCE(n::text,'NULL'); END IF;
  IF (js->>'ok')::boolean THEN pass:=pass+1; r := r || E'\n[31] OK  service_role lanza la ola sin ser dueno';
  ELSE fail:=fail+1; r := r || E'\n[31] FAIL service_role no pudo: '||COALESCE(js::text,'NULL'); END IF;

  js := public.notify_wave_1(qD,19.0,-99.0,50,false);
  IF (js->>'ok')::boolean THEN pass:=pass+1; r := r || E'\n[32] OK  postgres/pg_cron (sin JWT) lanza la ola sin filtro de dueno';
  ELSE fail:=fail+1; r := r || E'\n[32] FAIL postgres no pudo: '||COALESCE(js::text,'NULL'); END IF;

  st:='sin_error'; BEGIN PERFORM public.process_notification_waves();
  EXCEPTION WHEN OTHERS THEN st := SQLSTATE||' '||SQLERRM; END;
  IF st='sin_error' THEN pass:=pass+1; r := r || E'\n[33] OK  process_notification_waves() (cron 7, olas 2/3) corre sin error';
  ELSE fail:=fail+1; r := r || E'\n[33] FAIL el cron de olas fallo: '||COALESCE(st,'NULL'); END IF;

  -- ══════════════ INVARIANTES ══════════════
  SELECT prosrc INTO v_txt FROM pg_proc
  WHERE oid = to_regprocedure('public.notify_wave_1(uuid,double precision,double precision,double precision,boolean)');
  IF v_txt LIKE '%_send_wave(v_req, 0, 3, v_urgent)%' THEN
    pass:=pass+1; r := r || E'\n[34] OK  top 3 intacto: _send_wave(v_req, 0, 3, v_urgent)';
  ELSE fail:=fail+1; r := r || E'\n[34] FAIL se perdio el top 3'; END IF;

  SELECT COUNT(*) INTO n FROM pg_proc p JOIN pg_namespace ns ON ns.oid=p.pronamespace
  WHERE ns.nspname='public' AND p.prosrc ILIKE '%event_requests%'
    AND (NOT p.prosecdef OR pg_get_userbyid(p.proowner) <> 'postgres');
  IF n=0 THEN pass:=pass+1; r := r || E'\n[35] OK  todas las funciones que tocan event_requests siguen SECDEF de postgres';
  ELSE fail:=fail+1; r := r || E'\n[35] FAIL '||COALESCE(n::text,'NULL')||' funciones dependerian de RLS'; END IF;

  IF has_table_privilege('authenticated','public.event_requests','SELECT')
     AND has_table_privilege('authenticated','public.event_requests','INSERT')
     AND has_table_privilege('authenticated','public.event_requests','UPDATE')
     AND has_table_privilege('service_role','public.event_requests','SELECT')
     AND NOT has_table_privilege('anon','public.event_requests','SELECT') THEN
    pass:=pass+1; r := r || E'\n[36] OK  grants finales: authenticated y service_role conservan, anon sin nada';
  ELSE fail:=fail+1; r := r || E'\n[36] FAIL grants finales incorrectos'; END IF;

  RAISE EXCEPTION E'TEST_REPORT_712 (todo revertido)\nPASS=% FAIL=% %', pass, fail, COALESCE(r,'(reporte NULL)');
END
$suite$;

ROLLBACK;
