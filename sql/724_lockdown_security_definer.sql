-- ═══════════════════════════════════════════════════════════════════════════
-- 724 — ETAPA 3.6A: cierre de SECURITY DEFINER expuestas y de los defaults
-- ═══════════════════════════════════════════════════════════════════════════
--
-- ── QUÉ SE ENCONTRÓ (probado, no supuesto) ────────────────────────────────
-- `public` tiene 753 funciones, 504 SECURITY DEFINER, 449 ejecutables por
-- `anon`. Probadas una por una en transacciones revertidas, estas resultaron
-- EXPLOTABLES llamándolas como `anon` SIN NINGUNA SESIÓN:
--   · confirm_gift_payment            → regalo de $500 nunca pagado pasó a 'paid',
--                                        wallet con available_balance = 300 y
--                                        2 filas en wallet_transactions. DINERO REAL.
--   · confirm_bid_payment             → orden 'paid' y bid activo sin pagar
--   · confirm_recommendation_payment  → 7 días de recomendación gratis
--   · mark_ad_payment                 → anuncio a 'pending_review' sin pagar
--   · renew_recommendation_subscription → segunda orden pagada
--   · renew_sponsored_subscription    → patrocinado a 'pending_review'
--   · activate_plus                   → Plus hasta 2027 (también desde
--                                        `authenticated`, en un grupo AJENO)
--   · deactivate_plus                 → apaga el Plus de un competidor
--   · admin_apply_strike_internal     → 3 strikes + suspended_at, y forja
--                                        financial_audit_logs con actor_role='admin'
--   · apply_ranking_boost             → boost 0.5 (el tope) por 30 días
--
-- ── DE DÓNDE VIENE EL PERMISO ─────────────────────────────────────────────
-- De NINGUNA migración descuidada: del default del esquema. `ALTER DEFAULT
-- PRIVILEGES IN SCHEMA public` (puesto por `postgres` y por `supabase_admin`)
-- concede a anon/authenticated/service_role EXECUTE en funciones y `arwdDxtm` en
-- tablas; más el EXECUTE a PUBLIC que Postgres pone solo. Así nacen TODAS: 436 de
-- las 504 comparten el ACL `{=X/postgres, postgres, anon, authenticated,
-- service_role}`. Sin cerrar el default, cada migración nueva reabre el agujero.
--
-- ── POR QUÉ EL REVOKE NO ROMPE NADA (verificado antes de escribir esto) ───
--   1. Las 51 tareas de cron corren como `postgres` (cron.job.username) → no
--      dependen del grant de anon.
--   2. Los webhooks usan service_role: `stripe-webhook/index.ts:13` crea el
--      cliente con SUPABASE_SERVICE_ROLE_KEY, y `conekta-webhook` llama por REST
--      con `Bearer SERVICE_KEY` + `apikey: SERVICE_KEY`.
--   3. Ninguna de las funciones que se cierran aquí es llamada por la app:
--      se extrajeron los 209 nombres de `.rpc()` de `src/` + `web/src/` y
--      ninguno coincide. Las 24 de `supabase/functions/` sí, y conservan
--      service_role.
--   4. NINGUNA tiene llamadores SECURITY INVOKER: los 15 objetivos solo se
--      invocan desde funciones que también son SECURITY DEFINER, y dentro de una
--      SECDEF la llamada interna corre como el OWNER, así que el EXECUTE del
--      usuario final es irrelevante. Por eso cerrar `ensure_group_wallet` (15
--      llamadores) o `queue_push_notification` (9) no rompe a sus padres.
--   5. Los triggers no consultan EXECUTE al dispararse (solo al crearse), así
--      que revocar en las 63 funciones de trigger no los apaga. Se prueba.
--
-- ── DEFENSA EN PROFUNDIDAD: SOLO en las 8 de webhook ──────────────────────
-- Además del REVOKE, las 8 de webhook llevan un guard interno. Va SOLO en ellas
-- porque son las únicas con CERO llamadores internos: si se le pusiera a una
-- función interna (p.ej. `admin_apply_strike_internal`), ROMPERÍA a su padre
-- `admin_apply_strike`, ya que dentro de un SECDEF llamado por un admin el JWT
-- sigue diciendo `authenticated`.
--
-- La regla es POSITIVA y no usa `auth.uid()` como señal (anon también lo tiene en
-- NULL): pasa únicamente `auth.role() = 'service_role'` (webhook vía PostgREST) o
-- `auth.role()` vacío/NULL (conexión directa sin JWT: cron, psql, migración).
-- `anon` llega con role='anon' y `authenticated` con role='authenticated', así que
-- ambos quedan fuera. Semántica verificada: `request.jwt.claims` es un GUC de
-- sesión que PostgREST fija desde el JWT ya validado y que SECURITY DEFINER **no**
-- altera, así que dentro de la función sigue describiendo a QUIEN LLAMÓ.
-- Es el mismo patrón que ya usa `notify_wave_1` en producción (sql/711).
--
-- ── LO QUE ESTE PARCHE NO HACE ────────────────────────────────────────────
-- NO toca los permisos por columna de `groups` (eso es 3.6B, y antes hace falta
-- auditar todos los .update() de la app para no romper perfiles instalados).
-- NO borra las 4 funciones huérfanas: solo las cierra y las deja documentadas.
-- NO toca lógica monetaria, comisión, extra_hours, Express, cancelaciones,
-- recordatorios, 697/700, ni sql/722.
-- `submit_provider_application` CONSERVA anon: es el registro público sin sesión.
-- ═══════════════════════════════════════════════════════════════════════════

BEGIN;

-- ── 0. Guardas: las 8 deben estar como se auditaron ────────────────────────
DO $guard$
DECLARE
  v_esperado JSONB := jsonb_build_object(
    'activate_plus',                     'b04afe6277c69d0fdeb75d62ccd131f6',
    'deactivate_plus',                   '05da08a7e8ec83d32e126de21de0f911',
    'confirm_bid_payment',               '02c327cf8272f075fe89f364ada4fe8c',
    'admin_apply_strike_internal',       '7c3dfba1319bbbdef3a5c22f64d674c8',
    'apply_ranking_boost',               '0532f27f830f0b16e6d7d9a2c7fc0239'
  );
  v_k TEXT;
  v_real TEXT;
BEGIN
  FOR v_k IN SELECT jsonb_object_keys(v_esperado) LOOP
    SELECT md5(prosrc) INTO v_real FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
    WHERE n.nspname='public' AND p.proname = v_k;
    IF v_real IS DISTINCT FROM (v_esperado->>v_k) THEN
      RAISE EXCEPTION '% cambio desde la auditoria (md5 % <> %). Reauditar antes de aplicar 724.',
        v_k, v_real, v_esperado->>v_k;
    END IF;
  END LOOP;

  -- Ninguna de las 8 debe tener ya el guard (este parche no se aplica dos veces).
  IF EXISTS (
    SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
    WHERE n.nspname='public' AND p.prosrc ~ 'auth\.role\(\)'
      AND p.proname IN ('confirm_gift_payment','confirm_bid_payment','confirm_recommendation_payment',
                        'mark_ad_payment','renew_recommendation_subscription',
                        'renew_sponsored_subscription','activate_plus','deactivate_plus')
  ) THEN
    RAISE EXCEPTION 'Alguna de las 8 ya tiene guard de rol. 724 ya se aplico? Revisar a mano.';
  END IF;
END
$guard$;

-- ── 1. Guard interno en las 8 de webhook ───────────────────────────────────
DO $guards$
DECLARE
  v_fn    RECORD;
  v_def   TEXT;
  v_nl    TEXT;
  v_ancla TEXT;
  v_pos   INT;
  v_texto TEXT;
  v_n     INT := 0;
BEGIN
  FOR v_fn IN
    SELECT p.oid, p.oid::regprocedure::text AS firma
    FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
    WHERE n.nspname='public' AND p.proname IN
      ('confirm_gift_payment','confirm_bid_payment','confirm_recommendation_payment',
       'mark_ad_payment','renew_recommendation_subscription','renew_sponsored_subscription',
       'activate_plus','deactivate_plus')
    ORDER BY p.proname
  LOOP
    v_def := pg_get_functiondef(v_fn.oid);
    v_nl  := CASE WHEN v_def LIKE '%' || chr(13) || '%' THEN chr(13) || chr(10) ELSE chr(10) END;
    v_ancla := v_nl || 'BEGIN' || v_nl;

    -- El primer "BEGIN" en linea propia es el del cuerpo: el encabezado
    -- (CREATE … RETURNS … LANGUAGE … AS $function$) no contiene ninguno.
    v_pos := position(v_ancla in v_def);
    IF v_pos = 0 THEN
      RAISE EXCEPTION 'No encontre el BEGIN del cuerpo en %', v_fn.firma;
    END IF;

    v_texto :=
      '  -- sql/724 — defensa en profundidad. Esta funcion es SOLO de webhook:' || v_nl ||
      '  -- el REVOKE ya bloquea a anon/authenticated, y esto ademas sobrevive a un' || v_nl ||
      '  -- CREATE OR REPLACE que reinstale el ACL por default del esquema.' || v_nl ||
      '  -- Regla POSITIVA: pasa service_role (webhook via PostgREST) o rol vacio' || v_nl ||
      '  -- (conexion directa sin JWT: cron, psql, migracion). auth.uid() NO se usa' || v_nl ||
      '  -- como senal porque anon tambien lo tiene en NULL.' || v_nl ||
      '  IF COALESCE(auth.role(), '''') NOT IN (''service_role'', '''') THEN' || v_nl ||
      '    RAISE EXCEPTION ''forbidden: solo el backend puede ejecutar esta operacion''' || v_nl ||
      '      USING ERRCODE = ''42501'';' || v_nl ||
      '  END IF;' || v_nl || v_nl;

    v_def := left(v_def, v_pos + length(v_ancla) - 1)
          || v_texto
          || substr(v_def, v_pos + length(v_ancla));

    EXECUTE v_def;
    v_n := v_n + 1;
  END LOOP;

  IF v_n <> 8 THEN
    RAISE EXCEPTION 'Se esperaban 8 funciones de webhook con guard, se procesaron %', v_n;
  END IF;
  RAISE NOTICE '724 — guard interno agregado a % funciones de webhook', v_n;
END
$guards$;

-- ── 2. REVOKE por familias (listas explicitas, nada "a ciegas") ────────────
DO $revoke$
DECLARE
  -- (a) Solo webhook/service_role. Verificado: 0 llamadores, 0 usos en la app.
  v_webhook TEXT[] := ARRAY[
    'confirm_gift_payment','confirm_bid_payment','confirm_recommendation_payment',
    'mark_ad_payment','renew_recommendation_subscription','renew_sponsored_subscription',
    'activate_plus','deactivate_plus'];

  -- (b) Internas de backend. Solo se invocan desde otras SECDEF (verificado),
  --     asi que cerrar el EXECUTE directo no rompe ninguna llamada interna.
  v_internas TEXT[] := ARRAY[
    'admin_apply_strike_internal','apply_ranking_boost','recalculate_group_reputation',
    'calculate_group_reliability','ensure_group_wallet','generate_referral_code',
    'queue_push_notification'];

  -- (c) Tareas de cron. Las 51 corren como postgres; ninguna la llama la app.
  v_crons TEXT[] := ARRAY[
    'check_city_auto_promotion','expire_advertisements','expire_available_now','expire_bids',
    'expire_boosts','expire_pending_extra_hours','expire_pending_payment_extras',
    'expire_plus_groups','expire_ranking_boosts','expire_stale_quotes','expire_stale_requests',
    'mark_stale_users_offline','notify_artists_activity_boost','notify_artists_daily_tip',
    'notify_break_transitions','notify_clients_available_groups','notify_expiring_bids',
    'notify_groups_with_nearby_requests','notify_inactive_groups','notify_today_events',
    'notify_upcoming_events','notify_visibility_fading','notify_weekend_clients',
    'notify_weekend_groups','process_matching_queue','process_notification_waves',
    'purge_old_location_history','release_all_eligible_payments','release_expired_express_locks',
    'review_group_health','send_city_activity_pulse','send_event_reminders',
    'send_event_reminders_2h','send_express_followups','send_group_health_warnings',
    'send_peak_demand_predictions','take_platform_snapshot','update_recent_completions'];

  -- (d) Funciones de trigger. Dispararse NO consulta EXECUTE (solo crear el
  --     trigger lo hace), y ninguna se llama como RPC.
  v_triggers TEXT[] := ARRAY[
    '_trg_boost_on_event_complete','_trg_boost_on_five_star','_trg_protect_client_on_group_cancel',
    '_trg_record_demand_heatmap','_trg_reliability_from_proposal','_trg_reliability_from_reservation',
    '_trg_reliability_from_review','_trg_reputation_from_proposal','_trg_reputation_from_reservation',
    '_trg_reputation_from_review','_trg_reservation_completed','_trg_start_smart_matching',
    'auto_queue_refund','auto_queue_refund_on_rejection','calculate_commission',
    'check_client_request_limit','cleanup_event_messages','close_dispatches_on_request_change',
    'create_member_confirmations_on_reservation','create_wallet_for_new_profile',
    'generate_event_payouts','guard_cross_border_quote','guard_event_request_spam',
    'guard_group_videos_limit','guard_quote_spam','handle_new_group','handle_new_talent',
    'handle_new_user','hide_talent_on_group_join','normalize_profile_location',
    'notify_admin_event_review','notify_bid_competition','notify_booking_events',
    'notify_direct_message','notify_express_accepted','notify_extra_hour_proposed',
    'notify_extra_hour_rejected','notify_gift_visibility_off','notify_group_on_express_dispatch',
    'notify_group_video_pending','notify_groups_in_zone','notify_members_on_event_start',
    'notify_next_gig_rush','notify_quotes_on_date_block','notify_reservation_cancelled',
    'notify_reservation_paid','notify_sound_coordination','notify_talent_on_job_invitation',
    'populate_event_financial_summary','protect_chat_messages','show_talent_on_group_leave',
    'snapshot_commission_rate','trg_assign_founder_badge','trg_auto_referral_code',
    'trg_filter_event_request_comments','trg_filter_proposal_notes','trg_filter_reservation_message',
    'trg_referral_reward_on_payment','trg_set_demand_multiplier','trg_warn_on_repeated_violations',
    'update_client_loyalty_on_completion','update_group_demand_signal','update_group_reputation',
    'validate_package_distribution'];

  -- (e) Huerfanas: parecen trigger pero NINGUN trigger las usa y nadie las
  --     llama. NO se borran en este parche; quedan cerradas y documentadas
  --     para una limpieza posterior.
  v_huerfanas TEXT[] := ARRAY[
    'notify_booking_status_change','notify_group_new_reservation',
    'notify_new_booking_received','notify_reservation_created'];

  v_todas TEXT[];
  v_fn    RECORD;
  v_n     INT := 0;
BEGIN
  v_todas := v_webhook || v_internas || v_crons || v_triggers || v_huerfanas;

  FOR v_fn IN
    SELECT p.oid::regprocedure::text AS firma
    FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
    WHERE n.nspname='public' AND p.proname = ANY (v_todas)
  LOOP
    EXECUTE format('REVOKE EXECUTE ON FUNCTION %s FROM PUBLIC', v_fn.firma);
    EXECUTE format('REVOKE EXECUTE ON FUNCTION %s FROM anon', v_fn.firma);
    EXECUTE format('REVOKE EXECUTE ON FUNCTION %s FROM authenticated', v_fn.firma);
    v_n := v_n + 1;
  END LOOP;

  -- service_role se CONSERVA tal como estaba: ni se otorga ni se quita.
  -- Las 8 de webhook y `send_event_reminders` lo necesitan y ya lo tenian.
  RAISE NOTICE '724 — EXECUTE revocado a PUBLIC/anon/authenticated en % firmas', v_n;

  IF v_n < 110 THEN
    RAISE EXCEPTION 'Se esperaban ~120 firmas y solo se procesaron %. Revisar las listas.', v_n;
  END IF;
END
$revoke$;

-- Las 8 de webhook deben quedar ejecutables por service_role de forma EXPLICITA,
-- no por herencia del default (que es justo lo que se esta cerrando).
DO $grant$
DECLARE v_fn RECORD;
BEGIN
  FOR v_fn IN
    SELECT p.oid::regprocedure::text AS firma
    FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
    WHERE n.nspname='public' AND p.proname IN
      ('confirm_gift_payment','confirm_bid_payment','confirm_recommendation_payment',
       'mark_ad_payment','renew_recommendation_subscription','renew_sponsored_subscription',
       'activate_plus','deactivate_plus')
  LOOP
    EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO service_role', v_fn.firma);
  END LOOP;
END
$grant$;

-- ── 3. Defaults del esquema: que lo NUEVO no nazca abierto ─────────────────
-- Solo se cambian los de `postgres`, que es el owner de las 504 SECURITY
-- DEFINER y el rol con el que corren todas las migraciones del proyecto.
-- `authenticated` CONSERVA el default (la mayoría de las RPC son para usuarios
-- con sesión; quitárselo obligaría a un GRANT explícito en cada migración y
-- rompería las futuras en silencio). Solo se cierra PUBLIC y anon.
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public
  REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC, anon;

-- Y que una tabla nueva no nazca escribible por anon. SELECT se conserva: los
-- catálogos públicos (groups, cities, gift_catalog…) dependen de él.
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public
  REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON TABLES FROM anon;

-- ⚠ NO SE PUEDE CERRAR EL DEFAULT DE `supabase_admin` DESDE AQUÍ.
-- `ALTER DEFAULT PRIVILEGES FOR ROLE supabase_admin …` falla con 42501:
-- `postgres` no es miembro de `supabase_admin` (pg_has_role = false) y no es
-- superusuario. Ese default solo aplica a objetos creados POR supabase_admin
-- (la plataforma), no a nuestras migraciones — las 504 SECDEF son todas de
-- `postgres`. Queda como riesgo documentado: si alguna vez se crea una función
-- conectado como supabase_admin, nacerá abierta otra vez.

-- ── 4. Verificación ────────────────────────────────────────────────────────
DO $verify$
DECLARE
  v_abiertas INT;
  v_sin_svc  INT;
  v_sin_guard INT;
BEGIN
  -- Ninguna de las 8 de webhook puede seguir siendo ejecutable por anon o authenticated.
  SELECT COUNT(*) INTO v_abiertas
  FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
  WHERE n.nspname='public' AND p.proname IN
    ('confirm_gift_payment','confirm_bid_payment','confirm_recommendation_payment',
     'mark_ad_payment','renew_recommendation_subscription','renew_sponsored_subscription',
     'activate_plus','deactivate_plus')
    AND (has_function_privilege('anon', p.oid, 'EXECUTE')
      OR has_function_privilege('authenticated', p.oid, 'EXECUTE'));
  IF v_abiertas > 0 THEN
    RAISE EXCEPTION '% funciones de webhook siguen abiertas a anon/authenticated. Abortando.', v_abiertas;
  END IF;

  -- …y todas deben seguir siendo ejecutables por service_role.
  SELECT COUNT(*) INTO v_sin_svc
  FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
  WHERE n.nspname='public' AND p.proname IN
    ('confirm_gift_payment','confirm_bid_payment','confirm_recommendation_payment',
     'mark_ad_payment','renew_recommendation_subscription','renew_sponsored_subscription',
     'activate_plus','deactivate_plus')
    AND NOT has_function_privilege('service_role', p.oid, 'EXECUTE');
  IF v_sin_svc > 0 THEN
    RAISE EXCEPTION '% funciones de webhook quedaron SIN service_role: romperia Stripe/Conekta. Abortando.', v_sin_svc;
  END IF;

  -- Las 8 deben tener el guard.
  SELECT COUNT(*) INTO v_sin_guard
  FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
  WHERE n.nspname='public' AND p.proname IN
    ('confirm_gift_payment','confirm_bid_payment','confirm_recommendation_payment',
     'mark_ad_payment','renew_recommendation_subscription','renew_sponsored_subscription',
     'activate_plus','deactivate_plus')
    AND p.prosrc NOT LIKE '%COALESCE(auth.role(), '''') NOT IN (''service_role'', '''')%';
  IF v_sin_guard > 0 THEN
    RAISE EXCEPTION '% funciones de webhook quedaron sin guard interno. Abortando.', v_sin_guard;
  END IF;

  -- El registro publico NO se toco.
  IF NOT has_function_privilege('anon',
      'public.submit_provider_application(text,text,text,integer,numeric,text,text,text,text,numeric,numeric,integer)',
      'EXECUTE') THEN
    RAISE EXCEPTION 'submit_provider_application perdio el acceso de anon: romperia el registro publico. Abortando.';
  END IF;

  -- Los defaults quedaron cerrados para PUBLIC/anon en funciones.
  IF EXISTS (
    SELECT 1 FROM pg_default_acl d JOIN pg_namespace n ON n.oid=d.defaclnamespace
    WHERE n.nspname='public' AND d.defaclobjtype='f'
      AND pg_get_userbyid(d.defaclrole) = 'postgres'
      AND d.defaclacl::text LIKE '%anon=X%'
  ) THEN
    RAISE EXCEPTION 'El default de funciones de postgres sigue concediendo anon. Abortando.';
  END IF;

  -- Nada de dinero se toco.
  IF (SELECT md5(prosrc) FROM pg_proc WHERE oid = to_regprocedure('public.calculate_final_price(numeric,boolean,text,text,numeric,text)'))
     <> '37e3c7bfc9844cc533f6340fed38e206' THEN
    RAISE EXCEPTION '724 modifico calculate_final_price. Abortando.';
  END IF;
  IF (SELECT md5(prosrc) FROM pg_proc WHERE oid = to_regprocedure('public.client_accept_quote(uuid,uuid,integer)'))
     <> '59d981aa1793176834b22c09b0f9c21e' THEN
    RAISE EXCEPTION '724 modifico client_accept_quote (sql/722 sigue sin aplicar). Abortando.';
  END IF;

  RAISE NOTICE '724 OK — 8 de webhook cerradas y con guard; defaults de postgres cerrados a PUBLIC/anon';
END
$verify$;

NOTIFY pgrst, 'reload schema';

COMMIT;
