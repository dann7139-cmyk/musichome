-- ═══════════════════════════════════════════════════════════════════════════
-- 725 — SUITE AUTORREVERTIBLE de sql/724 (cierre de SECURITY DEFINER)
-- ═══════════════════════════════════════════════════════════════════════════
-- Se ejecuta DESPUÉS de aplicar sql/724. No deja nada: la excepción final es el
-- reporte y revierte todo. Datos 100% sintéticos.
--
-- Comprueba, como mínimo, lo exigido en la autorización:
--   [A] las explotables fallan desde anon
--   [B] también fallan desde authenticated
--   [C] siguen funcionando desde service_role
--   [D] confirm_gift_payment ya no crea saldo desde cliente
--   [E] Plus no puede activarse ni desactivarse desde cliente
--   [F] el bid no puede marcarse pagado desde cliente
--   [G] strikes y ranking internos no se pueden invocar directamente
--   [H] Stripe y Conekta conservan sus permisos (service_role)
--   [I] los crons siguen corriendo como postgres
--   [J] los triggers siguen disparándose aunque el usuario no tenga EXECUTE
--   [K] submit_provider_application sigue funcionando desde anon
--
-- CÓMO SE SIMULA CADA ROL: `set_config('role', …, true)` cambia el rol de
-- Postgres (lo que decide el EXECUTE) y `set_config('request.jwt.claims', …)`
-- cambia lo que ven `auth.uid()`/`auth.role()` (lo que decide el guard interno).
-- Ambos locales a la transacción.
-- ═══════════════════════════════════════════════════════════════════════════

BEGIN;

CREATE TEMP TABLE _r (i serial, nombre text, ok boolean, detalle text) ON COMMIT DROP;
CREATE OR REPLACE FUNCTION pg_temp.chk(n text, cond boolean, d text DEFAULT '')
RETURNS void LANGUAGE sql AS $$
  INSERT INTO _r (nombre, ok, detalle) VALUES (n, COALESCE(cond, false), d);
$$;

-- Intenta una llamada y devuelve 'OK' o el SQLSTATE del rechazo.
CREATE OR REPLACE FUNCTION pg_temp.intenta(p_sql text) RETURNS text
LANGUAGE plpgsql AS $$
BEGIN
  EXECUTE p_sql;
  RETURN 'OK';
EXCEPTION WHEN OTHERS THEN
  RETURN SQLSTATE;
END $$;

DO $suite$
DECLARE
  u_duenio UUID := gen_random_uuid();
  u_cli    UUID := gen_random_uuid();
  g        UUID := gen_random_uuid();
  g_trig   UUID := gen_random_uuid();
  v_gift   UUID;
  v_gift2  UUID;
  v_order  UUID;
  v_cat    UUID;
  v_sub    TEXT := 'sub_SINTETICO_725';
  v_rc     TEXT;
  v_wallet NUMERIC;
  v_tx     INT;
  v_row    RECORD;
BEGIN
  SELECT id INTO v_cat FROM public.gift_catalog LIMIT 1;

  INSERT INTO auth.users (id) VALUES (u_duenio), (u_cli);
  INSERT INTO public.profiles (id, full_name, role) VALUES
    (u_duenio, 'Dueno 725', 'group'), (u_cli, 'Cliente 725', 'client')
  ON CONFLICT (id) DO UPDATE SET role = EXCLUDED.role;
  INSERT INTO public.groups (id, name, owner_id, state, country, genre, is_active,
                             is_plus_active, plus_subscription_id, strike_count)
  VALUES (g, 'Grupo 725', u_duenio, 'Durango', 'México', 'Norteño', true, FALSE, v_sub, 0);
  INSERT INTO public.plus_subscriptions (group_id, owner_id, stripe_subscription_id, status)
  VALUES (g, u_duenio, v_sub, 'active');
  INSERT INTO public.bid_orders (id, group_id, user_id, amount, duration_days, status)
  VALUES (gen_random_uuid(), g, u_duenio, 999, 7, 'pending_payment') RETURNING id INTO v_order;
  INSERT INTO public.group_gifts (group_id, sender_id, gift_id, currency_code,
                                  amount, group_amount, platform_amount, status)
  VALUES (g, u_cli, v_cat, 'MXN', 500, 300, 200, 'pending') RETURNING id INTO v_gift;
  INSERT INTO public.group_gifts (group_id, sender_id, gift_id, currency_code,
                                  amount, group_amount, platform_amount, status)
  VALUES (g, u_cli, v_cat, 'MXN', 500, 300, 200, 'pending') RETURNING id INTO v_gift2;

  SELECT COUNT(*) INTO v_tx FROM public.wallet_transactions;

  -- ════════════════ [A] desde anon ════════════════
  PERFORM set_config('request.jwt.claims', json_build_object('role','anon')::text, true);
  PERFORM set_config('role', 'anon', true);

  v_rc := pg_temp.intenta(format('SELECT public.confirm_gift_payment(%L, %L)', v_gift, 'x'));
  PERFORM set_config('role','postgres',true);
  PERFORM pg_temp.chk('[A][D] confirm_gift_payment rechazada desde anon', v_rc = '42501', 'SQLSTATE=' || v_rc);
  PERFORM pg_temp.chk('[D] y el regalo sigue sin pagar',
    (SELECT status = 'pending' FROM public.group_gifts WHERE id = v_gift));
  PERFORM pg_temp.chk('[D] y NO se creo wallet ni saldo',
    NOT EXISTS (SELECT 1 FROM public.group_wallets WHERE group_id = g)
    AND (SELECT COUNT(*) FROM public.wallet_transactions) = v_tx);

  PERFORM set_config('role','anon',true);
  v_rc := pg_temp.intenta(format('SELECT public.activate_plus(%L, %L, NOW() + INTERVAL ''365 days'', %L)', g, 'active', v_sub));
  PERFORM set_config('role','postgres',true);
  PERFORM pg_temp.chk('[A][E] activate_plus rechazada desde anon', v_rc = '42501', 'SQLSTATE=' || v_rc);
  PERFORM pg_temp.chk('[E] y el grupo sigue sin Plus',
    (SELECT NOT is_plus_active FROM public.groups WHERE id = g));

  PERFORM set_config('role','anon',true);
  v_rc := pg_temp.intenta(format('SELECT public.deactivate_plus(%L)', v_sub));
  PERFORM set_config('role','postgres',true);
  PERFORM pg_temp.chk('[A][E] deactivate_plus rechazada desde anon', v_rc = '42501', 'SQLSTATE=' || v_rc);
  PERFORM pg_temp.chk('[E] y la suscripcion sigue activa',
    (SELECT status = 'active' FROM public.plus_subscriptions WHERE stripe_subscription_id = v_sub));

  PERFORM set_config('role','anon',true);
  v_rc := pg_temp.intenta(format('SELECT public.confirm_bid_payment(%L, %L)', v_order, 'x'));
  PERFORM set_config('role','postgres',true);
  PERFORM pg_temp.chk('[A][F] confirm_bid_payment rechazada desde anon', v_rc = '42501', 'SQLSTATE=' || v_rc);
  PERFORM pg_temp.chk('[F] y la orden sigue sin pagar',
    (SELECT status = 'pending_payment' FROM public.bid_orders WHERE id = v_order));

  PERFORM set_config('role','anon',true);
  v_rc := pg_temp.intenta(format('SELECT public.confirm_recommendation_payment(%L, %L)', gen_random_uuid(), 'x'));
  PERFORM set_config('role','postgres',true);
  PERFORM pg_temp.chk('[A] confirm_recommendation_payment rechazada desde anon', v_rc = '42501', 'SQLSTATE=' || v_rc);

  PERFORM set_config('role','anon',true);
  v_rc := pg_temp.intenta(format('SELECT public.mark_ad_payment(%L, %L)', gen_random_uuid(), 'x'));
  PERFORM set_config('role','postgres',true);
  PERFORM pg_temp.chk('[A] mark_ad_payment rechazada desde anon', v_rc = '42501', 'SQLSTATE=' || v_rc);

  PERFORM set_config('role','anon',true);
  v_rc := pg_temp.intenta(format('SELECT public.renew_recommendation_subscription(%L, %L, 1, 1)', g, 'x'));
  PERFORM set_config('role','postgres',true);
  PERFORM pg_temp.chk('[A] renew_recommendation_subscription rechazada desde anon', v_rc = '42501', 'SQLSTATE=' || v_rc);

  PERFORM set_config('role','anon',true);
  v_rc := pg_temp.intenta(format('SELECT public.renew_sponsored_subscription(%L, %L, 1)', gen_random_uuid(), 'x'));
  PERFORM set_config('role','postgres',true);
  PERFORM pg_temp.chk('[A] renew_sponsored_subscription rechazada desde anon', v_rc = '42501', 'SQLSTATE=' || v_rc);

  -- ════════════════ [B] desde authenticated ════════════════
  PERFORM set_config('request.jwt.claims',
    json_build_object('sub', u_cli::text, 'role','authenticated')::text, true);
  PERFORM set_config('role', 'authenticated', true);

  v_rc := pg_temp.intenta(format('SELECT public.confirm_gift_payment(%L, %L)', v_gift, 'x'));
  PERFORM set_config('role','postgres',true);
  PERFORM pg_temp.chk('[B][D] confirm_gift_payment rechazada desde authenticated', v_rc = '42501', 'SQLSTATE=' || v_rc);

  PERFORM set_config('role','authenticated',true);
  v_rc := pg_temp.intenta(format('SELECT public.activate_plus(%L, %L, NOW(), %L)', g, 'active', v_sub));
  PERFORM set_config('role','postgres',true);
  PERFORM pg_temp.chk('[B][E] activate_plus rechazada desde authenticated', v_rc = '42501', 'SQLSTATE=' || v_rc);

  PERFORM set_config('role','authenticated',true);
  v_rc := pg_temp.intenta(format('SELECT public.confirm_bid_payment(%L, %L)', v_order, 'x'));
  PERFORM set_config('role','postgres',true);
  PERFORM pg_temp.chk('[B][F] confirm_bid_payment rechazada desde authenticated', v_rc = '42501', 'SQLSTATE=' || v_rc);

  -- ════════════════ [G] internas privilegiadas ════════════════
  PERFORM set_config('role','authenticated',true);
  v_rc := pg_temp.intenta(format('SELECT public.admin_apply_strike_internal(%L, NULL, %L, %L, %L)', g, 'no_show', u_cli, 'x'));
  PERFORM set_config('role','postgres',true);
  PERFORM pg_temp.chk('[G] admin_apply_strike_internal rechazada desde authenticated', v_rc = '42501', 'SQLSTATE=' || v_rc);
  PERFORM pg_temp.chk('[G] y el grupo sigue sin strikes ni suspension',
    (SELECT COALESCE(strike_count,0) = 0 AND suspended_at IS NULL FROM public.groups WHERE id = g));

  PERFORM set_config('role','authenticated',true);
  v_rc := pg_temp.intenta(format('SELECT public.apply_ranking_boost(%L, 0.5, 720)', g));
  PERFORM set_config('role','postgres',true);
  PERFORM pg_temp.chk('[G] apply_ranking_boost rechazada desde authenticated', v_rc = '42501', 'SQLSTATE=' || v_rc);
  PERFORM pg_temp.chk('[G] y el boost sigue en cero',
    (SELECT COALESCE(ranking_boost,0) = 0 FROM public.groups WHERE id = g));

  PERFORM set_config('role','anon',true);
  v_rc := pg_temp.intenta(format('SELECT public.queue_push_notification(%L, %L, %L, %L)', u_cli, 'admin', 't', 'b'));
  PERFORM set_config('role','postgres',true);
  PERFORM pg_temp.chk('[G] queue_push_notification rechazada desde anon (ya no se puede spamear push)',
    v_rc = '42501', 'SQLSTATE=' || v_rc);

  PERFORM set_config('role','authenticated',true);
  v_rc := pg_temp.intenta(format('SELECT public.ensure_group_wallet(%L)', g));
  PERFORM set_config('role','postgres',true);
  PERFORM pg_temp.chk('[G] ensure_group_wallet rechazada desde authenticated', v_rc = '42501', 'SQLSTATE=' || v_rc);

  PERFORM set_config('role','anon',true);
  v_rc := pg_temp.intenta('SELECT public.review_group_health()');
  PERFORM set_config('role','postgres',true);
  PERFORM pg_temp.chk('[G] review_group_health (cron) rechazada desde anon', v_rc = '42501', 'SQLSTATE=' || v_rc);

  -- ════════════════ [C][H] service_role sigue funcionando ════════════════
  PERFORM set_config('request.jwt.claims', json_build_object('role','service_role')::text, true);
  PERFORM set_config('role', 'service_role', true);

  v_rc := pg_temp.intenta(format('SELECT public.confirm_gift_payment(%L, %L)', v_gift2, 'order_725'));
  PERFORM set_config('role','postgres',true);
  PERFORM pg_temp.chk('[C][H] confirm_gift_payment SI funciona desde service_role (el webhook sigue vivo)',
    v_rc = 'OK', 'SQLSTATE=' || v_rc);
  PERFORM pg_temp.chk('[C][H] y acredito el regalo como siempre',
    (SELECT status = 'paid' FROM public.group_gifts WHERE id = v_gift2)
    AND (SELECT available_balance = 300 FROM public.group_wallets WHERE group_id = g),
    'regalo=' || (SELECT status FROM public.group_gifts WHERE id = v_gift2)
    || ' saldo=' || COALESCE((SELECT available_balance::text FROM public.group_wallets WHERE group_id = g),'sin wallet'));

  PERFORM set_config('role','service_role',true);
  v_rc := pg_temp.intenta(format('SELECT public.activate_plus(%L, %L, NOW() + INTERVAL ''365 days'', %L)', g, 'active', v_sub));
  PERFORM set_config('role','postgres',true);
  PERFORM pg_temp.chk('[C][H] activate_plus SI funciona desde service_role', v_rc = 'OK', 'SQLSTATE=' || v_rc);
  PERFORM pg_temp.chk('[C][H] y activo el Plus',
    (SELECT is_plus_active FROM public.groups WHERE id = g));

  PERFORM set_config('role','service_role',true);
  v_rc := pg_temp.intenta(format('SELECT public.confirm_bid_payment(%L, %L)', v_order, 'pi_725'));
  PERFORM set_config('role','postgres',true);
  PERFORM pg_temp.chk('[C][H] confirm_bid_payment SI funciona desde service_role', v_rc = 'OK', 'SQLSTATE=' || v_rc);
  PERFORM pg_temp.chk('[C][H] y marco la orden pagada',
    (SELECT status = 'paid' FROM public.bid_orders WHERE id = v_order));

  -- ════════════════ [I] crons ════════════════
  PERFORM pg_temp.chk('[I] los crons siguen registrados y corriendo como postgres',
    (SELECT COUNT(*) FROM cron.job) >= 51 AND (SELECT COUNT(DISTINCT username) FROM cron.job) = 1
    AND (SELECT DISTINCT username FROM cron.job) = 'postgres',
    'jobs=' || (SELECT COUNT(*)::text FROM cron.job) || ' usuario=' || (SELECT DISTINCT username FROM cron.job));
  PERFORM pg_temp.chk('[I] postgres (dueño) sigue pudiendo ejecutar las funciones de cron',
    has_function_privilege('postgres', 'public.review_group_health()', 'EXECUTE')
    AND has_function_privilege('postgres', 'public.expire_stale_quotes()', 'EXECUTE'));
  PERFORM pg_temp.chk('[I] y el cron de recordatorios que llama una edge function conserva service_role',
    has_function_privilege('service_role', 'public.send_event_reminders()', 'EXECUTE'));

  -- ════════════════ [J] los triggers siguen disparandose ════════════════
  -- El usuario ya NO tiene EXECUTE sobre handle_new_group ni sobre
  -- trg_assign_referral_code, pero disparar un trigger no consulta EXECUTE.
  PERFORM pg_temp.chk('[J] authenticated ya NO puede ejecutar handle_new_group directamente',
    NOT has_function_privilege('authenticated', 'public.handle_new_group()', 'EXECUTE'));
  PERFORM set_config('request.jwt.claims',
    json_build_object('sub', u_duenio::text, 'role','authenticated')::text, true);
  PERFORM set_config('role','authenticated',true);
  v_rc := pg_temp.intenta(format(
    'INSERT INTO public.groups (id, name, owner_id, state, country, genre, is_active) VALUES (%L, %L, %L, %L, %L, %L, true)',
    g_trig, 'Grupo Trigger 725', u_duenio, 'Durango', 'México', 'Norteño'));
  PERFORM set_config('role','postgres',true);
  PERFORM pg_temp.chk('[J] un authenticated inserta su grupo y el INSERT pasa', v_rc = 'OK', 'SQLSTATE=' || v_rc);
  PERFORM pg_temp.chk('[J] y el trigger AFTER INSERT corrio igual (creo su job_board_profile)',
    EXISTS (SELECT 1 FROM public.job_board_profiles WHERE user_id = u_duenio));
  PERFORM pg_temp.chk('[J] y el trigger que asigna referral_code tambien corrio',
    (SELECT referral_code IS NOT NULL FROM public.groups WHERE id = g_trig),
    'referral_code=' || COALESCE((SELECT referral_code FROM public.groups WHERE id = g_trig),'NULL'));

  -- ════════════════ [K] el registro publico sigue abierto ════════════════
  PERFORM set_config('request.jwt.claims', json_build_object('role','anon')::text, true);
  PERFORM set_config('role','anon',true);
  v_rc := pg_temp.intenta(
    'SELECT public.submit_provider_application(''Proveedor 725'', ''6181239999'', ''grupo'', 3, 3, ''México'', ''Durango'', ''Durango'', NULL)');
  PERFORM set_config('role','postgres',true);
  PERFORM pg_temp.chk('[K] submit_provider_application sigue funcionando desde anon', v_rc = 'OK', 'SQLSTATE=' || v_rc);
  PERFORM pg_temp.chk('[K] y dejo su solicitud',
    EXISTS (SELECT 1 FROM public.provider_applications WHERE full_name = 'Proveedor 725'));

  -- ════════════════ Controles de no-regresion ════════════════
  PERFORM pg_temp.chk('[X] sql/722 sigue SIN aplicar (client_accept_quote intacta)',
    (SELECT md5(prosrc) FROM pg_proc WHERE oid=to_regprocedure('public.client_accept_quote(uuid,uuid,integer)'))
      = '59d981aa1793176834b22c09b0f9c21e');
  PERFORM pg_temp.chk('[X] calculate_final_price intacta',
    (SELECT md5(prosrc) FROM pg_proc WHERE oid=to_regprocedure('public.calculate_final_price(numeric,boolean,text,text,numeric,text)'))
      = '37e3c7bfc9844cc533f6340fed38e206');
  PERFORM pg_temp.chk('[X] el default de funciones ya no concede PUBLIC ni anon',
    (SELECT d.defaclacl::text NOT LIKE '%anon=X%' AND d.defaclacl::text NOT LIKE '{=X%'
       FROM pg_default_acl d JOIN pg_namespace n ON n.oid=d.defaclnamespace
      WHERE n.nspname='public' AND d.defaclobjtype='f' AND pg_get_userbyid(d.defaclrole)='postgres'),
    (SELECT d.defaclacl::text FROM pg_default_acl d JOIN pg_namespace n ON n.oid=d.defaclnamespace
      WHERE n.nspname='public' AND d.defaclobjtype='f' AND pg_get_userbyid(d.defaclrole)='postgres'));
  PERFORM pg_temp.chk('[X] el default de tablas ya no da escritura a anon (conserva SELECT)',
    (SELECT d.defaclacl::text LIKE '%anon=rxtm%'
       FROM pg_default_acl d JOIN pg_namespace n ON n.oid=d.defaclnamespace
      WHERE n.nspname='public' AND d.defaclobjtype='r' AND pg_get_userbyid(d.defaclrole)='postgres'));

  -- ════════════════ REPORTE ════════════════
  DECLARE
    v_rep TEXT := E'\n'; v_pass INT; v_fail INT;
  BEGIN
    FOR v_row IN SELECT nombre, ok, detalle FROM _r ORDER BY i LOOP
      v_rep := v_rep || CASE WHEN v_row.ok THEN '  [OK]   ' ELSE '  [FAIL] ' END || v_row.nombre ||
               CASE WHEN COALESCE(v_row.detalle,'') = '' THEN '' ELSE E'\n            ' || v_row.detalle END || E'\n';
    END LOOP;
    SELECT COUNT(*) FILTER (WHERE ok), COUNT(*) FILTER (WHERE NOT ok) INTO v_pass, v_fail FROM _r;
    RAISE EXCEPTION E'TEST_REPORT sql/725 — cierre de SECURITY DEFINER%\n  PASS=% FAIL=%\n  TODO REVERTIDO.',
      v_rep, v_pass, v_fail;
  END;
END
$suite$;

ROLLBACK;
