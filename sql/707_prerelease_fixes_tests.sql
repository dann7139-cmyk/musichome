-- ═══════════════════════════════════════════════════════════════════════════
-- 707 — PRUEBAS de las tres correcciones pre-release (704, 705, 706)
-- ═══════════════════════════════════════════════════════════════════════════
-- AUTOREVERTIBLE de principio a fin. **Aplica ella misma las tres migraciones
-- dentro de su propia transacción** y lo revierte todo, así se puede validar el
-- resultado antes de tocar producción.
--
-- No mueve dinero: `open_dispute` solo inserta en `disputes` y `notifications`, y
-- todo desaparece con el ROLLBACK. Nada llama a funciones de wallet/payout.
--
-- Semillas con prefijo RT707.
-- ═══════════════════════════════════════════════════════════════════════════

BEGIN;

-- ── 704 + 705: retirar las firmas duplicadas ──────────────────────────────
DROP FUNCTION public.notify_wave_1(UUID, DOUBLE PRECISION, DOUBLE PRECISION, DOUBLE PRECISION);
DROP FUNCTION public.open_dispute(UUID, TEXT, TEXT[]);

-- ── 706: crear log_fraud_signal ───────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.log_fraud_signal(
  p_user_id UUID, p_signal_type TEXT, p_details JSONB DEFAULT '{}'::jsonb
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE
  v_uid UUID; v_id UUID;
  TIPOS_PERMITIDOS TEXT[] := ARRAY['chat_phone_bypass'];
BEGIN
  v_uid := auth.uid();
  IF v_uid IS NULL THEN RETURN jsonb_build_object('ok', false, 'error', 'not_authenticated'); END IF;
  IF p_user_id IS DISTINCT FROM v_uid THEN RETURN jsonb_build_object('ok', false, 'error', 'not_self'); END IF;
  IF p_signal_type IS NULL OR NOT (p_signal_type = ANY (TIPOS_PERMITIDOS)) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_signal_type');
  END IF;
  INSERT INTO public.fraud_signals (user_id, signal_type, severity, description, metadata)
  VALUES (v_uid, p_signal_type, 'low',
          'Intentos de compartir contacto por el chat (detectado en la app)',
          COALESCE(p_details, '{}'::jsonb))
  RETURNING id INTO v_id;
  RETURN jsonb_build_object('ok', true, 'signal_id', v_id);
END;
$function$;
REVOKE EXECUTE ON FUNCTION public.log_fraud_signal(UUID, TEXT, JSONB) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.log_fraud_signal(UUID, TEXT, JSONB) TO authenticated, service_role;

DO $suite$
DECLARE
  v_cli UUID := '889e7168-a30a-49c5-a32a-cbeb320d00f8';
  v_dA  UUID := '929ba9ba-1dfd-4b76-abf1-18168b1ac1ba';
  v_otro UUID;
  v_mx UUID; v_g UUID; v_req UUID; v_res UUID;
  v_d JSONB; v_n INT; v_disp_antes INT; v_fs_antes INT;
BEGIN
  SELECT id INTO v_mx FROM public.countries WHERE currency_code='MXN' LIMIT 1;
  SELECT id INTO v_otro FROM public.profiles WHERE id NOT IN (v_cli, v_dA) LIMIT 1;
  SELECT COUNT(*) INTO v_disp_antes FROM public.disputes;
  SELECT COUNT(*) INTO v_fs_antes   FROM public.fraud_signals;

  RESET role;
  INSERT INTO public.groups (id,owner_id,name,genre,country_id)
  VALUES (gen_random_uuid(),v_dA,'RT707 Grupo','Banda',v_mx) RETURNING id INTO v_g;
  -- reserva DENTRO de la ventana de 7 dias que exige open_dispute
  INSERT INTO public.reservations (id,client_id,group_id,event_date,event_time,address,
    total_price,base_price,status,payment_status,payout_status,currency_code,hours_count)
  VALUES (gen_random_uuid(),v_cli,v_g,CURRENT_DATE-1,'20:00','RT707 Salon',
    10000,8000,'completed','paid','held','MXN',3) RETURNING id INTO v_res;
  INSERT INTO public.event_requests (id,client_id,genre,event_type,event_date,location_city,location_estado)
  VALUES (gen_random_uuid(),v_cli,'Banda','boda',CURRENT_DATE+30,'Zapopan','Jalisco') RETURNING id INTO v_req;

  -- ══ notify_wave_1 ══════════════════════════════════════════════════════
  -- [1] una sola firma
  SELECT COUNT(*) INTO v_n FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
   WHERE n.nspname='public' AND p.proname='notify_wave_1';
  ASSERT v_n = 1, '[1] notify_wave_1 deberia tener 1 firma, tiene '||v_n::text;

  -- [2] las 4 claves EXACTAS de la app ya no dan 42725 y funciona
  PERFORM set_config('request.jwt.claims', json_build_object('sub',v_cli::text,'role','authenticated')::text, true);
  PERFORM set_config('role','authenticated',true);
  BEGIN
    v_d := public.notify_wave_1(p_request_id => v_req, p_event_lat => 20.67,
                                p_event_lng => -103.39, p_radius_km => 50);
  EXCEPTION WHEN SQLSTATE '42725' THEN
    RAISE EXCEPTION '[2] sigue ambigua (42725) con las claves de la app';
  END;
  ASSERT (v_d->>'ok')::boolean, '[2] el caller legitimo deberia funcionar: '||v_d::text;
  ASSERT (v_d->>'wave')::int = 1, '[2] deberia reportar wave 1';

  -- [3] no duplica: la segunda llamada NO vuelve a enviar
  v_d := public.notify_wave_1(p_request_id => v_req, p_event_lat => 20.67,
                              p_event_lng => -103.39, p_radius_km => 50);
  ASSERT (v_d->>'ok')::boolean = false AND v_d->>'error' = 'wave_already_started',
    '[3] la segunda llamada deberia rechazarse, no reenviar: '||v_d::text;
  RESET role;
  SELECT current_wave INTO v_n FROM public.event_requests WHERE id = v_req;
  ASSERT v_n = 1, '[3] current_wave deberia seguir en 1, esta en '||v_n::text;

  -- ══ open_dispute ═══════════════════════════════════════════════════════
  -- [4] una sola firma
  SELECT COUNT(*) INTO v_n FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
   WHERE n.nspname='public' AND p.proname='open_dispute';
  ASSERT v_n = 1, '[4] open_dispute deberia tener 1 firma, tiene '||v_n::text;

  -- [5] un tercero NO puede abrir disputa de una reserva ajena
  PERFORM set_config('request.jwt.claims', json_build_object('sub',v_otro::text,'role','authenticated')::text, true);
  PERFORM set_config('role','authenticated',true);
  BEGIN
    PERFORM public.open_dispute(p_reservation_id => v_res, p_reason => 'RT707 intruso');
    RAISE EXCEPTION '[5] un tercero abrio una disputa ajena';
  EXCEPTION
    WHEN SQLSTATE '42725' THEN RAISE EXCEPTION '[5] sigue ambigua (42725)';
    WHEN OTHERS THEN
      IF SQLERRM NOT LIKE '%no eres parte de esta reserva%' THEN
        RAISE EXCEPTION '[5] fallo por otro motivo: %', SQLERRM;
      END IF;
  END;

  -- [6] el cliente dueño SI puede, con las 2 claves exactas de la app
  PERFORM set_config('request.jwt.claims', json_build_object('sub',v_cli::text,'role','authenticated')::text, true);
  PERFORM set_config('role','authenticated',true);
  BEGIN
    v_d := public.open_dispute(p_reservation_id => v_res, p_reason => 'RT707 problema real');
  EXCEPTION WHEN SQLSTATE '42725' THEN
    RAISE EXCEPTION '[6] sigue ambigua (42725) con las claves de la app';
  END;
  ASSERT (v_d->>'ok')::boolean, '[6] el dueño deberia poder abrir la disputa: '||v_d::text;

  -- [7] escribio en `disputes` (la tabla que leen las guardas financieras)
  RESET role;
  SELECT COUNT(*) INTO v_n FROM public.disputes WHERE reservation_id = v_res AND status='open';
  ASSERT v_n = 1, '[7] deberia haber 1 disputa en `disputes`, hay '||v_n::text;

  -- [8] no se crea una SEGUNDA disputa por el arreglo
  PERFORM set_config('request.jwt.claims', json_build_object('sub',v_cli::text,'role','authenticated')::text, true);
  PERFORM set_config('role','authenticated',true);
  BEGIN
    PERFORM public.open_dispute(p_reservation_id => v_res, p_reason => 'RT707 segunda');
    RAISE EXCEPTION '[8] permitio una segunda disputa abierta';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM NOT LIKE '%Ya existe una disputa abierta%' THEN
      RAISE EXCEPTION '[8] fallo por otro motivo: %', SQLERRM;
    END IF;
  END;
  RESET role;
  SELECT COUNT(*) INTO v_n FROM public.disputes WHERE reservation_id = v_res;
  ASSERT v_n = 1, '[8] quedaron '||v_n::text||' disputas y deberia haber 1';

  -- [9] la ventana de 7 dias sigue frenando lo antiguo (el "estado invalido"
  --     que de verdad valida esta funcion)
  DECLARE v_viejo UUID; v_g2 UUID;
  BEGIN
    RESET role;
    INSERT INTO public.groups (id,owner_id,name,genre,country_id)
    VALUES (gen_random_uuid(),v_dA,'RT707 Grupo2','Banda',v_mx) RETURNING id INTO v_g2;
    INSERT INTO public.reservations (id,client_id,group_id,event_date,event_time,address,
      total_price,base_price,status,payment_status,currency_code,hours_count)
    VALUES (gen_random_uuid(),v_cli,v_g2,CURRENT_DATE-40,'20:00','RT707 Viejo',
      1000,900,'completed','paid','MXN',3) RETURNING id INTO v_viejo;
    PERFORM set_config('request.jwt.claims', json_build_object('sub',v_cli::text,'role','authenticated')::text, true);
    PERFORM set_config('role','authenticated',true);
    BEGIN
      PERFORM public.open_dispute(p_reservation_id => v_viejo, p_reason => 'RT707 tarde');
      RAISE EXCEPTION '[9] permitio disputar un evento de hace 40 dias';
    EXCEPTION WHEN OTHERS THEN
      IF SQLERRM NOT LIKE '%más de 7 días%' THEN
        RAISE EXCEPTION '[9] fallo por otro motivo: %', SQLERRM;
      END IF;
    END;
  END;

  -- ══ log_fraud_signal ═══════════════════════════════════════════════════
  -- [10] la firma EXACTA que manda ChatScreen existe
  ASSERT to_regprocedure('public.log_fraud_signal(uuid, text, jsonb)') IS NOT NULL,
    '[10] no existe la firma (uuid, text, jsonb)';

  -- [11] el usuario autenticado registra LO SUYO
  PERFORM set_config('request.jwt.claims', json_build_object('sub',v_cli::text,'role','authenticated')::text, true);
  PERFORM set_config('role','authenticated',true);
  v_d := public.log_fraud_signal(p_user_id => v_cli, p_signal_type => 'chat_phone_bypass',
                                 p_details => jsonb_build_object('reservation_id', v_res, 'attempts', 3));
  ASSERT (v_d->>'ok')::boolean, '[11] deberia registrar: '||v_d::text;

  -- [12] NO puede atribuir la señal a otra persona
  v_d := public.log_fraud_signal(p_user_id => v_otro, p_signal_type => 'chat_phone_bypass');
  ASSERT (v_d->>'ok')::boolean = false AND v_d->>'error' = 'not_self',
    '[12] pudo atribuir una señal a otro: '||v_d::text;

  -- [13] tipo invalido se rechaza
  v_d := public.log_fraud_signal(p_user_id => v_cli, p_signal_type => 'inventado_por_el_cliente');
  ASSERT (v_d->>'ok')::boolean = false AND v_d->>'error' = 'invalid_signal_type',
    '[13] acepto un tipo fuera de la lista blanca: '||v_d::text;

  -- [14] anon no puede ejecutarla
  PERFORM set_config('request.jwt.claims','',true);
  PERFORM set_config('role','anon',true);
  BEGIN
    PERFORM public.log_fraud_signal(p_user_id => v_cli, p_signal_type => 'chat_phone_bypass');
    RAISE EXCEPTION '[14] anon pudo registrar una señal antifraude';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;

  -- [15] solo quedo 1 señal nueva (la legitima)
  RESET role;
  SELECT COUNT(*) INTO v_n FROM public.fraud_signals;
  ASSERT v_n = v_fs_antes + 1, '[15] se registraron '||(v_n-v_fs_antes)::text||' señales y deberia ser 1';

  RAISE EXCEPTION 'TEST_REPORT sql/707: TODO PASO (15/15) — notify_wave_1 con 1 sola firma, las 4 claves de la app resuelven y funcionan, y la segunda llamada no reenvia; open_dispute con 1 sola firma, un tercero no puede, el dueño si, escribe en `disputes`, no admite una segunda disputa y la ventana de 7 dias sigue vigente; log_fraud_signal existe con la firma de ChatScreen, registra lo propio, rechaza atribuir a otro, rechaza tipos fuera de la lista blanca y anon no la ejecuta';
END
$suite$;

ROLLBACK;
