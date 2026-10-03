-- ═══════════════════════════════════════════════════════════════════════════
-- 727 — SUITE AUTORREVERTIBLE de sql/726 (lockdown por columnas de groups)
-- ═══════════════════════════════════════════════════════════════════════════
-- Se ejecuta DESPUÉS de aplicar sql/726. No deja nada: la excepción final es el
-- reporte y revierte todo. Datos 100% sintéticos.
--
-- Cubre lo exigido en la autorización de 3.6B:
--   [6] pruebas de ataque: 27 intentos del proveedor sobre SU PROPIO grupo
--   [7] flujos legítimos: perfil completo, visa, regalos, estado/país,
--       catálogo comercial por su RPC, y dejar una reseña
--   [5] Admin y service_role siguen funcionando
--   [8] anon no puede hacer UPDATE
--   [2] compatibilidad: crear grupo y reenviar columnas protegidas sin cambiarlas
--   [ACL] el reparto final de privilegios por columna
--   [CANARIO] detecta SECURITY DEFINER nuevas y peligrosas abiertas a anon
--
-- SEMBRADO: los valores iniciales se eligen DISTINTOS de los que intentará el
-- atacante, para que cada ataque sea un CAMBIO real y no un no-op que el trigger
-- permite legítimamente.
-- ═══════════════════════════════════════════════════════════════════════════

BEGIN;

CREATE TEMP TABLE _r (i serial, nombre text, ok boolean, detalle text) ON COMMIT DROP;
CREATE OR REPLACE FUNCTION pg_temp.chk(n text, cond boolean, d text DEFAULT '')
RETURNS void LANGUAGE sql AS $$
  INSERT INTO _r(nombre, ok, detalle) VALUES (n, COALESCE(cond, false), d);
$$;
CREATE OR REPLACE FUNCTION pg_temp.intenta(p_sql text) RETURNS text
LANGUAGE plpgsql AS $$
BEGIN
  EXECUTE p_sql; RETURN 'OK';
EXCEPTION WHEN OTHERS THEN RETURN SQLSTATE;
END $$;

DO $suite$
DECLARE
  u_prov UUID := gen_random_uuid();
  u_otro UUID := gen_random_uuid();
  u_adm  UUID := gen_random_uuid();
  u_cli  UUID := gen_random_uuid();
  g      UUID := gen_random_uuid();
  g_otro UUID := gen_random_uuid();
  g_new  UUID := gen_random_uuid();
  v_rc TEXT; v_row RECORD; v_ataques TEXT[]; v_a TEXT;
  v_fallos INT := 0; v_det TEXT := ''; v_n INT := 0;
BEGIN
  INSERT INTO auth.users (id) VALUES (u_prov),(u_otro),(u_adm),(u_cli);
  INSERT INTO public.profiles (id, full_name, role) VALUES
    (u_prov,'Prov 727','group'),(u_otro,'Otro 727','group'),
    (u_adm,'Admin 727','admin'),(u_cli,'Cli 727','client')
  ON CONFLICT (id) DO UPDATE SET role = EXCLUDED.role;
  INSERT INTO public.groups (id, name, owner_id, state, country, genre, is_active, strike_count,
                             concierge_mode, express_enabled, is_plus_active, is_verified)
  VALUES (g,'Grupo Prov 727',u_prov,'Durango','México','Norteño',true,2,true,false,false,false),
         (g_otro,'Grupo Otro 727',u_otro,'Durango','México','Banda',true,0,false,false,false,false);
  UPDATE public.groups SET suspended_at = NOW(), trust_score = 50, verification_status = 'none' WHERE id = g;

  -- ════════ [6] ATAQUES: el dueño intenta auto-concederse todo ════════
  PERFORM set_config('request.jwt.claims', json_build_object('sub',u_prov::text,'role','authenticated')::text, true);
  v_ataques := ARRAY[
    'is_plus_active = true', 'plus_expires_at = NOW() + INTERVAL ''3650 days''',
    'ranking_boost = 0.5', 'bid_amount = 99999', 'is_verified = true',
    'admin_verified = true', 'admin_highlight = true', 'strike_count = 0',
    'suspended_at = NULL', 'commission_percentage = 0', 'trust_score = 100',
    'reliability_score = 100', 'ranking_score = 999', 'puntos_reputacion = 9999',
    'rating = 5', 'total_reviews = 999', 'owner_id = ''' || u_otro::text || '''',
    'min_hours = 1', 'price_from = 1', 'concierge_mode = false',
    'express_enabled = true', 'is_active = false', 'verification_status = ''approved''',
    'stripe_account_id = ''acct_falso''', 'referral_code = ''GRATIS''',
    'nivel = 99', 'badges = ARRAY[''falsa'']'];
  FOREACH v_a IN ARRAY v_ataques LOOP
    v_n := v_n + 1;
    PERFORM set_config('role','authenticated',true);
    v_rc := pg_temp.intenta(format('UPDATE public.groups SET %s WHERE id = %L', v_a, g));
    PERFORM set_config('role','postgres',true);
    IF v_rc = 'OK' THEN v_fallos := v_fallos + 1; v_det := v_det || v_a || ' | '; END IF;
  END LOOP;
  PERFORM pg_temp.chk('[6] TODOS los ataques del proveedor sobre SU grupo quedaron bloqueados',
    v_fallos = 0,
    CASE WHEN v_fallos = 0 THEN v_n::text || '/' || v_n::text || ' rechazados'
         ELSE 'PASARON: ' || v_det END);
  PERFORM pg_temp.chk('[6] y el grupo sigue exactamente igual',
    (SELECT NOT COALESCE(is_plus_active,false) AND COALESCE(strike_count,0) = 2
        AND suspended_at IS NOT NULL AND COALESCE(ranking_boost,0) = 0
        AND COALESCE(is_verified,false) = false AND trust_score = 50
        AND concierge_mode = true AND express_enabled = false
        AND owner_id = u_prov AND verification_status = 'none'
       FROM public.groups WHERE id = g));

  -- ════════ [7] FLUJOS LEGÍTIMOS del proveedor ════════
  PERFORM set_config('role','authenticated',true);
  v_rc := pg_temp.intenta(format(
    'UPDATE public.groups SET name = %L, description = %L, genre = %L, state = %L, country = %L,
       has_sound = true, sound_capacity_max = 200, has_lighting = true, lighting_level = %L,
       has_stage = true, stage_sizes_available = ARRAY[%L], has_led_screen = false,
       led_sizes_available = ARRAY[]::text[], power_amps = 40, needs_parking = true,
       setup_minutes = 45, includes_text = %L, category_details = ''{}''::jsonb
     WHERE id = %L',
    'Grupo Prov 727 editado','Somos buenos','Norteño','Durango','México','pro','medium','Traemos todo', g));
  PERFORM set_config('role','postgres',true);
  PERFORM pg_temp.chk('[7] el proveedor SI guarda su perfil completo (las 18 columnas de DashboardScreen)',
    v_rc = 'OK', 'SQLSTATE=' || v_rc);
  PERFORM pg_temp.chk('[7] y el cambio quedo',
    (SELECT name = 'Grupo Prov 727 editado' AND sound_capacity_max = 200 FROM public.groups WHERE id = g));

  PERFORM set_config('role','authenticated',true);
  v_rc := pg_temp.intenta(format('UPDATE public.groups SET has_work_visa = true WHERE id = %L', g));
  PERFORM set_config('role','postgres',true);
  PERFORM pg_temp.chk('[7] has_work_visa (ProfileScreen)', v_rc = 'OK', 'SQLSTATE=' || v_rc);

  PERFORM set_config('role','authenticated',true);
  v_rc := pg_temp.intenta(format('UPDATE public.groups SET show_gifts_to_members = true WHERE id = %L', g));
  PERFORM set_config('role','postgres',true);
  PERFORM pg_temp.chk('[7] show_gifts_to_members (WalletScreen)', v_rc = 'OK', 'SQLSTATE=' || v_rc);

  PERFORM set_config('role','authenticated',true);
  v_rc := pg_temp.intenta(format('UPDATE public.groups SET state = %L, country = %L WHERE id = %L',
    'Jalisco','México', g));
  PERFORM set_config('role','postgres',true);
  PERFORM pg_temp.chk('[7] state + country (ProfileScreen)', v_rc = 'OK', 'SQLSTATE=' || v_rc);

  -- ════════ [6] otro proveedor sobre grupo ajeno ════════
  PERFORM set_config('request.jwt.claims', json_build_object('sub',u_otro::text,'role','authenticated')::text, true);
  PERFORM set_config('role','authenticated',true);
  v_rc := pg_temp.intenta(format('UPDATE public.groups SET name = %L WHERE id = %L', 'secuestrado', g));
  PERFORM set_config('role','postgres',true);
  PERFORM pg_temp.chk('[6] otro proveedor no cambia nada de un grupo ajeno (RLS, 0 filas)',
    v_rc = 'OK' AND (SELECT name = 'Grupo Prov 727 editado' FROM public.groups WHERE id = g),
    'SQLSTATE=' || v_rc);

  -- ════════ [8] anon ════════
  PERFORM set_config('request.jwt.claims', json_build_object('role','anon')::text, true);
  PERFORM set_config('role','anon',true);
  v_rc := pg_temp.intenta(format('UPDATE public.groups SET name = %L WHERE id = %L', 'anon', g));
  PERFORM set_config('role','postgres',true);
  PERFORM pg_temp.chk('[8] anon no puede hacer UPDATE a groups ni en una columna de perfil',
    v_rc = '42501', 'SQLSTATE=' || v_rc);

  -- ════════ [5] ADMIN sigue funcionando ════════
  PERFORM set_config('request.jwt.claims', json_build_object('sub',u_adm::text,'role','authenticated')::text, true);
  PERFORM set_config('role','authenticated',true);
  v_rc := pg_temp.intenta(format(
    'UPDATE public.groups SET is_active = true, verification_status = %L, is_verified = true WHERE id = %L',
    'approved', g));
  PERFORM set_config('role','postgres',true);
  PERFORM pg_temp.chk('[5] Admin verifica un grupo por UPDATE directo (el panel web desplegado)',
    v_rc = 'OK' AND (SELECT is_verified FROM public.groups WHERE id = g), 'SQLSTATE=' || v_rc);

  PERFORM set_config('role','authenticated',true);
  v_rc := pg_temp.intenta(format(
    'UPDATE public.groups SET concierge_mode = false, express_enabled = true WHERE id = %L', g));
  PERFORM set_config('role','postgres',true);
  PERFORM pg_temp.chk('[5] Admin cambia conserjeria y Express', v_rc = 'OK', 'SQLSTATE=' || v_rc);

  PERFORM set_config('role','authenticated',true);
  v_rc := pg_temp.intenta(format('UPDATE public.groups SET name = %L, genre = %L WHERE id = %L',
    'Renombrado','Banda', g));
  PERFORM set_config('role','postgres',true);
  PERFORM pg_temp.chk('[5] Admin renombra y cambia genero', v_rc = 'OK', 'SQLSTATE=' || v_rc);

  -- ════════ [7] el catálogo comercial, por su RPC ════════
  PERFORM set_config('request.jwt.claims', json_build_object('sub',u_prov::text,'role','authenticated')::text, true);
  PERFORM set_config('role','authenticated',true);
  v_rc := pg_temp.intenta(format('SELECT public.set_group_commercial_catalog(%L, 3, 4, 900, NULL)', g));
  PERFORM set_config('role','postgres',true);
  PERFORM pg_temp.chk('[7] set_group_commercial_catalog SIGUE funcionando para el dueño aunque NO tenga la columna',
    v_rc = 'OK' AND (SELECT min_hours = 3 AND extra_hour_price = 900 FROM public.groups WHERE id = g),
    'SQLSTATE=' || v_rc || ' min_hours=' || COALESCE((SELECT min_hours::text FROM public.groups WHERE id = g),'NULL'));

  -- ════════ [7] dejar reseña sigue actualizando el rating ════════
  PERFORM set_config('request.jwt.claims', json_build_object('sub',u_cli::text,'role','authenticated')::text, true);
  PERFORM set_config('role','authenticated',true);
  v_rc := pg_temp.intenta(format(
    'INSERT INTO public.reviews (group_id, client_id, rating) VALUES (%L, %L, 5)', g, u_cli));
  PERFORM set_config('role','postgres',true);
  PERFORM pg_temp.chk('[7] un cliente deja resena y el trigger actualiza groups.rating (update_group_rating en SECDEF)',
    v_rc = 'OK' AND (SELECT rating = 5 AND total_reviews = 1 FROM public.groups WHERE id = g),
    'SQLSTATE=' || v_rc || ' rating=' || COALESCE((SELECT rating::text FROM public.groups WHERE id = g),'NULL'));

  -- ════════ [2] compatibilidad con la app instalada ════════
  PERFORM set_config('request.jwt.claims', json_build_object('sub',u_prov::text,'role','authenticated')::text, true);
  PERFORM set_config('role','authenticated',true);
  v_rc := pg_temp.intenta(format(
    'INSERT INTO public.groups (id, owner_id, name, genre, state, country, is_active, is_verified, verification_status)
     VALUES (%L, %L, %L, %L, %L, %L, true, true, %L)',
    g_new, u_prov, 'Grupo Nuevo 727', 'Norteño', 'Durango', 'México', 'approved'));
  PERFORM set_config('role','postgres',true);
  PERFORM pg_temp.chk('[2] crear grupo no falla aunque la pantalla mande is_verified', v_rc = 'OK', 'SQLSTATE=' || v_rc);
  PERFORM pg_temp.chk('[2] y nace SIN verificar aunque pidio is_verified=true y approved',
    (SELECT NOT is_verified AND verification_status = 'none' FROM public.groups WHERE id = g_new),
    'is_verified=' || COALESCE((SELECT is_verified::text FROM public.groups WHERE id = g_new),'NULL'));

  PERFORM set_config('role','authenticated',true);
  v_rc := pg_temp.intenta(format(
    'UPDATE public.groups SET name = %L, is_verified = false WHERE id = %L', 'Version vieja', g_new));
  PERFORM set_config('role','postgres',true);
  PERFORM pg_temp.chk('[2] una version vieja que reenvia una columna protegida SIN cambiarla sigue guardando',
    v_rc = 'OK', 'SQLSTATE=' || v_rc);

  -- ════════ [5] service_role ════════
  PERFORM set_config('request.jwt.claims', json_build_object('role','service_role')::text, true);
  PERFORM set_config('role','service_role',true);
  v_rc := pg_temp.intenta(format('UPDATE public.groups SET stripe_onboarding_completed = true WHERE id = %L', g));
  PERFORM set_config('role','postgres',true);
  PERFORM pg_temp.chk('[5] service_role (webhook de Stripe Connect) sigue escribiendo', v_rc = 'OK', 'SQLSTATE=' || v_rc);

  -- ════════ [ACL] reparto final ════════
  PERFORM pg_temp.chk('[ACL] anon sin UPDATE en ninguna de las 98 columnas',
    (SELECT COUNT(*) FROM pg_attribute WHERE attrelid='public.groups'::regclass AND attnum>0 AND NOT attisdropped
       AND has_column_privilege('anon','public.groups',attname,'UPDATE')) = 0);
  PERFORM pg_temp.chk('[ACL] authenticated con UPDATE en 40 de 98 columnas',
    (SELECT COUNT(*) FROM pg_attribute WHERE attrelid='public.groups'::regclass AND attnum>0 AND NOT attisdropped
       AND has_column_privilege('authenticated','public.groups',attname,'UPDATE')) = 40,
    'son ' || (SELECT COUNT(*)::text FROM pg_attribute WHERE attrelid='public.groups'::regclass AND attnum>0 AND NOT attisdropped
       AND has_column_privilege('authenticated','public.groups',attname,'UPDATE')) || ' de 98');
  PERFORM pg_temp.chk('[ACL] anon conserva SELECT y authenticated conserva INSERT',
    has_table_privilege('anon','public.groups','SELECT') AND has_table_privilege('authenticated','public.groups','INSERT'));
  PERFORM pg_temp.chk('[ACL] update_group_rating quedo SECURITY DEFINER',
    (SELECT prosecdef FROM pg_proc WHERE oid = to_regprocedure('public.update_group_rating()')));
  PERFORM pg_temp.chk('[ACL] no queda ninguna funcion SECURITY INVOKER que escriba groups',
    (SELECT COUNT(*) FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
      WHERE n.nspname='public' AND NOT p.prosecdef
        AND p.prosrc ~* '(UPDATE\s+(public\.)?groups|INSERT\s+INTO\s+(public\.)?groups)') = 0);
  PERFORM pg_temp.chk('[X] RLS de groups sin cambios (11 politicas)',
    (SELECT COUNT(*) FROM pg_policy WHERE polrelid='public.groups'::regclass) = 11,
    'politicas=' || (SELECT COUNT(*)::text FROM pg_policy WHERE polrelid='public.groups'::regclass));
  PERFORM pg_temp.chk('[X] 722 sigue sin aplicar y el precio no se movio',
    (SELECT md5(prosrc) FROM pg_proc WHERE oid=to_regprocedure('public.client_accept_quote(uuid,uuid,integer)'))
      = '59d981aa1793176834b22c09b0f9c21e'
    AND (SELECT md5(prosrc) FROM pg_proc WHERE oid=to_regprocedure('public.calculate_final_price(numeric,boolean,text,text,numeric,text)'))
      = '37e3c7bfc9844cc533f6340fed38e206');

  -- ════════ [CANARIO] para futuras migraciones ════════
  -- Falla cuando aparece una SECURITY DEFINER NUEVA que escribe datos, es
  -- ejecutable por anon y no revisa identidad. La lista es la foto de 3.6A: las
  -- 17 que quedaron a proposito y que se clasificaran en 3.6C.
  -- Correr esta consulta después de CADA migración futura.
  SELECT COUNT(*) INTO v_n
  FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
  WHERE n.nspname='public' AND p.prosecdef
    AND has_function_privilege('anon', p.oid, 'EXECUTE')
    AND p.prosrc ~* '(INSERT INTO|UPDATE |DELETE FROM)'
    AND p.prosrc !~* 'auth\.uid\(\)'
    AND p.prosrc !~* '(role\s*(=|IN|NOT IN)|is_admin|auth\.role\(\))'
    AND p.proname <> ALL (ARRAY[
      '_check_event_compliance','_notify_matching_wave','_send_wave',
      'complete_express_dispatch','dispatch_express_request','notify_express_groups',
      'notify_high_demand_groups','notify_new_city_groups','purge_group_location_history',
      'refresh_state_demand_cache','request_extra_hours_client','resolve_shared_event_id',
      'start_smart_matching','track_ad_click','track_ad_impression','track_group_view',
      'transition_city_statuses']);
  PERFORM pg_temp.chk('[CANARIO] no aparecio ninguna SECURITY DEFINER nueva, peligrosa y abierta a anon',
    v_n = 0,
    CASE WHEN v_n = 0 THEN 'linea base intacta: solo las 17 conocidas'
         ELSE 'APARECIERON ' || v_n::text || ' nuevas: ' || COALESCE((
           SELECT string_agg(p.proname, ', ') FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
           WHERE n.nspname='public' AND p.prosecdef
             AND has_function_privilege('anon', p.oid, 'EXECUTE')
             AND p.prosrc ~* '(INSERT INTO|UPDATE |DELETE FROM)'
             AND p.prosrc !~* 'auth\.uid\(\)'
             AND p.prosrc !~* '(role\s*(=|IN|NOT IN)|is_admin|auth\.role\(\))'
             AND p.proname <> ALL (ARRAY[
               '_check_event_compliance','_notify_matching_wave','_send_wave',
               'complete_express_dispatch','dispatch_express_request','notify_express_groups',
               'notify_high_demand_groups','notify_new_city_groups','purge_group_location_history',
               'refresh_state_demand_cache','request_extra_hours_client','resolve_shared_event_id',
               'start_smart_matching','track_ad_click','track_ad_impression','track_group_view',
               'transition_city_statuses'])), '?') END);

  -- ════════ REPORTE ════════
  DECLARE
    v_rep TEXT := E'\n'; v_pass INT; v_fail INT;
  BEGIN
    FOR v_row IN SELECT nombre, ok, detalle FROM _r ORDER BY i LOOP
      v_rep := v_rep || CASE WHEN v_row.ok THEN '  [OK]   ' ELSE '  [FAIL] ' END || v_row.nombre ||
               CASE WHEN COALESCE(v_row.detalle,'')='' THEN '' ELSE E'\n            ' || v_row.detalle END || E'\n';
    END LOOP;
    SELECT COUNT(*) FILTER (WHERE ok), COUNT(*) FILTER (WHERE NOT ok) INTO v_pass, v_fail FROM _r;
    RAISE EXCEPTION E'TEST_REPORT sql/727 — lockdown por columnas de groups%\n  PASS=% FAIL=%\n  TODO REVERTIDO.',
      v_rep, v_pass, v_fail;
  END;
END
$suite$;

ROLLBACK;
