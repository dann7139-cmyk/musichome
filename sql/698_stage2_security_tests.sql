-- ═══════════════════════════════════════════════════════════════════════════
-- 698 — SUITE DE SEGURIDAD de la Etapa 2 (autorevertible de principio a fin)
-- ═══════════════════════════════════════════════════════════════════════════
-- Esta suite es especial: **aplica ella misma los grants de `697` dentro de su
-- propia transacción**, prueba el resultado, y lo revierte todo. Así se puede
-- demostrar que el endurecimiento funciona SIN cerrar los permisos en
-- producción, que es justo lo que no se puede hacer todavía porque hay una app
-- instalada sin OTA.
--
-- Requisito: `sql/696` aplicado (las 4 RPCs). Los grants los pone la suite.
--
-- No mueve dinero real: no llama a ninguna función de wallets/payouts/reembolsos.
-- Todo lo que inserta son filas ficticias con prefijo RTSEC2 dentro de la misma
-- transacción revertida.
--
-- Pruebas NEGATIVAS (el ataque debe fallar) y POSITIVAS (el flujo legítimo debe
-- seguir funcionando), como pidió el usuario.
-- ═══════════════════════════════════════════════════════════════════════════

BEGIN;

-- ─── Los grants de 697, aquí solo para poder probarlos ────────────────────
REVOKE UPDATE, DELETE, TRUNCATE ON TABLE public.reservations FROM anon, authenticated;
GRANT UPDATE (break_type) ON TABLE public.reservations TO authenticated;
GRANT SELECT, INSERT ON TABLE public.reservations TO anon, authenticated;

DO $suite$
DECLARE
  v_client UUID := '889e7168-a30a-49c5-a32a-cbeb320d00f8';
  v_owner  UUID := '929ba9ba-1dfd-4b76-abf1-18168b1ac1ba';
  v_otro   UUID;
  v_mx UUID; v_g1 UUID; v_g2 UUID; v_ev UUID;
  v_res UUID;        -- reserva del cliente, pagada y confirmada (para reprogramar)
  v_res_nueva UUID;  -- reserva recien creada (para ubicacion/moneda)
  v_res_pend UUID;   -- reserva pendiente (para aceptar/rechazar)
  v_d JSONB; v_n INT; v_txt TEXT; v_num NUMERIC;
  v_col TEXT; v_fallos TEXT := '';
  -- Columnas sensibles que un cliente NO debe poder tocar directamente
  SENSIBLES TEXT[] := ARRAY[
    'total_price = 1', 'payment_status = ''fully_paid''', 'payout_status = ''released''',
    'commission_amount = 0', 'currency_code = ''USD''', 'status = ''completed''',
    'event_date = CURRENT_DATE + 900', 'event_time = ''23:00''',
    'group_id = NULL', 'client_id = NULL', 'event_id = NULL', 'quote_id = NULL',
    'deposit_amount = 1', 'deposit_paid = 1', 'base_price = 1', 'group_earnings = 999999'];
BEGIN
  SELECT id INTO v_mx FROM public.countries WHERE currency_code='MXN' LIMIT 1;
  SELECT id INTO v_otro FROM public.profiles WHERE id NOT IN (v_client, v_owner) LIMIT 1;

  RESET role;
  INSERT INTO public.groups (id,owner_id,name,genre,country_id)
  VALUES (gen_random_uuid(),v_owner,'RTSEC2 Grupo A','Banda',v_mx) RETURNING id INTO v_g1;
  INSERT INTO public.groups (id,owner_id,name,genre,country_id)
  VALUES (gen_random_uuid(),v_owner,'RTSEC2 Grupo B','Banda',v_mx) RETURNING id INTO v_g2;
  INSERT INTO public.events (client_id,event_date,event_time,address,status)
  VALUES (v_client,CURRENT_DATE+800,'20:00','RTSEC2 Salon','active') RETURNING id INTO v_ev;

  INSERT INTO public.reservations (id,client_id,group_id,event_id,event_date,event_time,address,
    total_price,base_price,status,payment_status,payout_status,currency_code,hours_count,break_type)
  VALUES (gen_random_uuid(),v_client,v_g1,v_ev,CURRENT_DATE+800,'20:00','RTSEC2 Salon',
    10000,8000,'confirmed','paid','held','MXN',3,'A') RETURNING id INTO v_res;

  INSERT INTO public.reservations (id,client_id,group_id,event_id,event_date,event_time,address,
    total_price,base_price,status,payment_status,currency_code,hours_count)
  VALUES (gen_random_uuid(),v_client,v_g2,v_ev,CURRENT_DATE+801,'18:00','RTSEC2 Salon',
    5000,4000,'pending_payment','unpaid','MXN',3) RETURNING id INTO v_res_nueva;

  v_res_pend := v_res_nueva;  -- la misma sirve para aceptar/rechazar (pending_payment)

  -- ═══════════════ CLIENTE ═══════════════
  PERFORM set_config('request.jwt.claims', json_build_object('sub',v_client::text,'role','authenticated')::text, true);
  PERFORM set_config('role','authenticated',true);

  -- [1] POSITIVA: puede LEER su reserva
  SELECT COUNT(*) INTO v_n FROM public.reservations WHERE id = v_res;
  ASSERT v_n = 1, '[1] el cliente deberia poder leer su propia reserva';

  -- [2] NEGATIVAS: ninguna columna sensible por UPDATE directo
  FOREACH v_col IN ARRAY SENSIBLES LOOP
    BEGIN
      EXECUTE format('UPDATE public.reservations SET %s WHERE id = %L', v_col, v_res);
      v_fallos := v_fallos || E'\n    · LOGRO cambiar: ' || v_col;
    EXCEPTION
      WHEN insufficient_privilege THEN NULL;            -- 42501: lo esperado
      WHEN OTHERS THEN
        -- Un CHECK/NOT NULL/RLS que frene antes tambien cuenta como bloqueado,
        -- pero se anota el codigo para poder revisarlo.
        IF SQLSTATE NOT IN ('23502','23514','23503','42501') THEN
          v_fallos := v_fallos || E'\n    · ' || v_col || ' fallo con SQLSTATE ' || SQLSTATE;
        END IF;
    END;
  END LOOP;
  ASSERT v_fallos = '', '[2] el cliente TODAVIA puede tocar columnas sensibles:' || v_fallos;

  -- [3] NEGATIVA: tampoco puede borrar. Tras el REVOKE esto ya no es "0 filas
  -- por RLS" sino un 42501 directo, que es mejor: falla antes de mirar filas.
  BEGIN
    DELETE FROM public.reservations WHERE id = v_res;
    GET DIAGNOSTICS v_n = ROW_COUNT;
    ASSERT v_n = 0, '[3] el cliente logro BORRAR su reserva';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;

  -- [4] POSITIVA: la RPC de ubicacion funciona y DERIVA la moneda
  v_d := public.client_set_booking_location(v_res_nueva, 'US', 'San Diego');
  ASSERT (v_d->>'ok')::boolean, '[4] client_set_booking_location fallo: ' || v_d::text;
  ASSERT v_d->>'currency_code' = 'USD', '[4] deberia derivar USD para US';
  RESET role;
  SELECT currency_code||'/'||COALESCE(event_country,'')||'/'||COALESCE(event_city,'')
    INTO v_txt FROM public.reservations WHERE id = v_res_nueva;
  ASSERT v_txt = 'USD/US/San Diego', '[4] no se guardo bien: ' || v_txt;
  PERFORM set_config('request.jwt.claims', json_build_object('sub',v_client::text,'role','authenticated')::text, true);
  PERFORM set_config('role','authenticated',true);

  -- [5] NEGATIVA: la RPC de ubicacion NO acepta paises fuera de lo soportado
  --     (no se amplian monedas: CAD sigue fuera a proposito)
  v_d := public.client_set_booking_location(v_res_nueva, 'CA', 'Toronto');
  ASSERT (v_d->>'ok')::boolean = false AND v_d->>'error' = 'unsupported_country',
    '[5] deberia rechazar CA en vez de intentar CAD: ' || v_d::text;

  -- [6] NEGATIVA: la RPC de ubicacion no sirve sobre una reserva AJENA
  v_d := public.client_set_booking_location(v_res, 'US', 'X');   -- esta ya esta pagada
  ASSERT (v_d->>'ok')::boolean = false, '[6] no deberia funcionar sobre una reserva ya pagada';

  -- [7] POSITIVA: reprogramar por RPC funciona
  v_d := public.client_reschedule_reservation(v_res, CURRENT_DATE + 805);
  ASSERT (v_d->>'ok')::boolean, '[7] client_reschedule_reservation fallo: ' || v_d::text;
  RESET role;
  SELECT event_date::text INTO v_txt FROM public.reservations WHERE id = v_res;
  ASSERT v_txt = (CURRENT_DATE+805)::text, '[7] no cambio la fecha: ' || v_txt;
  PERFORM set_config('request.jwt.claims', json_build_object('sub',v_client::text,'role','authenticated')::text, true);
  PERFORM set_config('role','authenticated',true);

  -- [8] NEGATIVA: no puede reprogramar una reserva AJENA
  DECLARE v_ajena UUID;
  BEGIN
    RESET role;
    INSERT INTO public.reservations (id,client_id,group_id,event_date,event_time,address,
      total_price,status,payment_status,currency_code,hours_count)
    VALUES (gen_random_uuid(),v_otro,v_g1,CURRENT_DATE+810,'20:00','RTSEC2 Ajena',
      5000,'confirmed','paid','MXN',3) RETURNING id INTO v_ajena;
    PERFORM set_config('request.jwt.claims', json_build_object('sub',v_client::text,'role','authenticated')::text, true);
    PERFORM set_config('role','authenticated',true);
    v_d := public.client_reschedule_reservation(v_ajena, CURRENT_DATE + 815);
    ASSERT v_d->>'error' = 'not_owner', '[8] pudo reprogramar una reserva ajena: ' || v_d::text;
  END;

  -- [9] NEGATIVA: reprogramar a una fecha con el proveedor ocupado se rechaza
  --     (can_schedule, con exclusion de la propia reserva)
  DECLARE v_choque UUID;
  BEGIN
    RESET role;
    INSERT INTO public.reservations (id,client_id,group_id,event_date,event_time,address,
      total_price,status,payment_status,currency_code,hours_count)
    VALUES (gen_random_uuid(),v_client,v_g1,CURRENT_DATE+830,'20:00','RTSEC2 Choque',
      1000,'confirmed','paid','MXN',3) RETURNING id INTO v_choque;
    PERFORM set_config('request.jwt.claims', json_build_object('sub',v_client::text,'role','authenticated')::text, true);
    PERFORM set_config('role','authenticated',true);
    v_d := public.client_reschedule_reservation(v_res, CURRENT_DATE + 830);
    ASSERT (v_d->>'ok')::boolean = false, '[9] deberia rechazar por choque de agenda: ' || v_d::text;
  END;

  -- [10] break_type: el CLIENTE dueño si puede (igual que hoy: ya lo elige al
  --      reservar via create_booking_with_event). Un tercero no, por RLS.
  UPDATE public.reservations SET break_type = 'B' WHERE id = v_res;
  GET DIAGNOSTICS v_n = ROW_COUNT;
  ASSERT v_n = 1, '[10] el cliente dueño deberia poder cambiar break_type';

  -- [11] NEGATIVA CLAVE: break_type NO puede acompañarse de otra columna en el
  --      mismo UPDATE (el grant es por columna, no una puerta trasera)
  BEGIN
    UPDATE public.reservations SET break_type = 'D', total_price = 1 WHERE id = v_res;
    RAISE EXCEPTION '[11] pudo colar total_price junto con break_type';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;

  -- ═══════════════ PROVEEDOR (dueño del grupo) ═══════════════
  PERFORM set_config('request.jwt.claims', json_build_object('sub',v_owner::text,'role','authenticated')::text, true);
  PERFORM set_config('role','authenticated',true);

  -- [12] NEGATIVA: el proveedor tampoco toca precio/pago/payout
  v_fallos := '';
  FOREACH v_col IN ARRAY ARRAY['total_price = 777777','payment_status = ''paid''',
                               'payout_status = ''released''','commission_amount = 0'] LOOP
    BEGIN
      EXECUTE format('UPDATE public.reservations SET %s WHERE id = %L', v_col, v_res);
      v_fallos := v_fallos || E'\n    · LOGRO cambiar: ' || v_col;
    EXCEPTION WHEN insufficient_privilege THEN NULL;
      WHEN OTHERS THEN IF SQLSTATE NOT IN ('23502','23514','23503','42501') THEN
        v_fallos := v_fallos || E'\n    · ' || v_col || ' SQLSTATE ' || SQLSTATE; END IF;
    END;
  END LOOP;
  ASSERT v_fallos = '', '[12] el proveedor TODAVIA puede tocar dinero:' || v_fallos;

  -- [13] POSITIVA: el proveedor puede cambiar break_type (su uso legitimo)
  UPDATE public.reservations SET break_type = 'D' WHERE id = v_res;
  GET DIAGNOSTICS v_n = ROW_COUNT;
  ASSERT v_n = 1, '[13] el proveedor deberia poder cambiar break_type';

  -- [14] POSITIVA: aceptar por RPC reproduce la semantica de la pantalla
  v_d := public.group_accept_booking(v_res_pend);
  ASSERT (v_d->>'ok')::boolean, '[14] group_accept_booking fallo: ' || v_d::text;
  ASSERT v_d->>'status' = 'accepted', '[14] deberia quedar en accepted, no en confirmed';
  RESET role;
  SELECT status||'/'||(booking_expiration_at IS NOT NULL)::text INTO v_txt
  FROM public.reservations WHERE id = v_res_pend;
  ASSERT v_txt = 'accepted/true', '[14] estado o booking_expiration_at incorrectos: ' || v_txt;
  PERFORM set_config('request.jwt.claims', json_build_object('sub',v_owner::text,'role','authenticated')::text, true);
  PERFORM set_config('role','authenticated',true);

  -- [15] idempotencia de aceptar
  v_d := public.group_accept_booking(v_res_pend);
  ASSERT (v_d->>'ok')::boolean AND (v_d->>'already')::boolean, '[15] deberia ser idempotente';

  -- [16] NEGATIVA: un CLIENTE no puede aceptar reservas
  PERFORM set_config('request.jwt.claims', json_build_object('sub',v_client::text,'role','authenticated')::text, true);
  PERFORM set_config('role','authenticated',true);
  v_d := public.group_accept_booking(v_res_pend);
  ASSERT v_d->>'error' = 'not_group_owner', '[16] el cliente no deberia poder aceptar: ' || v_d::text;
  v_d := public.group_decline_booking(v_res_pend);
  ASSERT v_d->>'error' = 'not_group_owner', '[16] el cliente no deberia poder rechazar: ' || v_d::text;

  -- ═══════════════ ANON ═══════════════
  PERFORM set_config('request.jwt.claims','',true);
  PERFORM set_config('role','anon',true);
  SELECT COUNT(*) INTO v_n FROM public.reservations;
  ASSERT v_n = 0, '[17] anon no deberia ver ninguna reserva';
  BEGIN
    UPDATE public.reservations SET break_type = 'A' WHERE id = v_res;
    -- Sin filas visibles el UPDATE afecta 0; lo que importa es que no explote
    -- con exito sobre datos ajenos.
    GET DIAGNOSTICS v_n = ROW_COUNT;
    ASSERT v_n = 0, '[17] anon logro escribir';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;

  -- ═══════════════ BACKEND ═══════════════
  RESET role;
  -- [18] postgres (los crons) sigue pudiendo escribir
  UPDATE public.reservations SET total_price = 12345 WHERE id = v_res;
  SELECT total_price INTO v_num FROM public.reservations WHERE id = v_res;
  ASSERT v_num = 12345, '[18] postgres deberia seguir pudiendo escribir';

  -- [19] service_role sigue con UPDATE completo (webhooks de Stripe/Conekta)
  ASSERT has_table_privilege('service_role', 'public.reservations', 'UPDATE'),
    '[19] service_role PERDIO UPDATE: romperia los webhooks';
  ASSERT has_table_privilege('service_role', 'public.reservations', 'INSERT')
     AND has_table_privilege('service_role', 'public.reservations', 'SELECT'),
    '[19] service_role perdio INSERT/SELECT';

  -- [20] y los roles de la app conservan lo que SI deben tener
  ASSERT NOT has_table_privilege('authenticated', 'public.reservations', 'UPDATE'),
    '[20] authenticated sigue con UPDATE general';
  ASSERT NOT has_table_privilege('anon', 'public.reservations', 'UPDATE'),
    '[20] anon sigue con UPDATE general';
  ASSERT has_table_privilege('authenticated', 'public.reservations', 'SELECT')
     AND has_table_privilege('authenticated', 'public.reservations', 'INSERT'),
    '[20] authenticated perdio SELECT/INSERT, que si necesita';
  ASSERT has_column_privilege('authenticated', 'public.reservations', 'break_type', 'UPDATE'),
    '[20] falta el grant por columna de break_type';
  ASSERT NOT has_column_privilege('authenticated', 'public.reservations', 'total_price', 'UPDATE'),
    '[20] authenticated conserva UPDATE sobre total_price';

  -- [21] las 4 RPCs existen sin overloads
  SELECT COUNT(*) INTO v_n FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
  WHERE n.nspname='public' AND p.proname IN
    ('client_set_booking_location','client_reschedule_reservation','group_accept_booking','group_decline_booking');
  ASSERT v_n = 4, '[21] esperaba 4 RPCs sin overloads, hay ' || v_n::text;

  RAISE EXCEPTION 'TEST_REPORT sql/698: TODO PASO (21/21) — el cliente lee su reserva y usa las 4 RPCs legitimas, pero NO puede tocar por UPDATE directo ninguna de 16 columnas sensibles ni borrar; la moneda la deriva el servidor y CA se rechaza sin inventar CAD; reprogramar valida dueño y agenda con can_schedule; el proveedor no toca precio/pago/payout pero si acepta/rechaza por RPC con la semantica actual (accepted + booking_expiration_at, NO confirmed); break_type funciona por columna y NO permite colar otra columna en el mismo UPDATE; anon sin acceso; postgres y service_role intactos';
END
$suite$;

ROLLBACK;
