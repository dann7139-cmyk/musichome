-- ═══════════════════════════════════════════════════════════════════════════
-- 726 — ETAPA 3.6B: un proveedor ya no puede auto-concederse nada en su grupo
-- ═══════════════════════════════════════════════════════════════════════════
--
-- ── EL AGUJERO (probado en 3.6) ───────────────────────────────────────────
-- Con rol `authenticated` y el uid del dueño, un UPDATE directo sobre SU propia
-- fila de `groups`: 1 fila afectada, sin error. Se puso solo `is_plus_active`,
-- `plus_expires_at` a 10 años, `ranking_boost = 0.5`, `bid_amount = 99999`,
-- `is_verified`, `admin_verified`, `admin_highlight`, `strike_count = 0` y
-- `commission_percentage = 0`.
-- Causa: el GRANT de tabla del default del esquema + la política
-- `groups_owner_all` (`owner_id = auth.uid()`), que autoriza TODAS las columnas
-- de su fila. RLS contiene el GRANT contra filas AJENAS; contra la propia, no.
--
-- ── POR QUÉ NO BASTAN LOS PERMISOS POR COLUMNA ────────────────────────────
-- Los privilegios de columna son POR ROL, y en Supabase **Admin también es
-- `authenticated`**: el panel web (`web/src/lib/supabase.ts` usa la anon key con
-- sesión de usuario) escribe por UPDATE directo `is_verified`,
-- `verification_status` e `is_active`, y las pantallas de Admin en la app
-- escriben `concierge_mode`, `express_enabled`, `is_active`, `name` y `genre`.
-- Si se le quitara `is_verified` a `authenticated`, se rompería el panel web ya
-- desplegado. Por eso van DOS capas:
--
--   Capa 1 — TRIGGER `guard_group_platform_columns`: rechaza CAMBIOS en las
--            columnas de plataforma salvo que quien llama sea admin/admin_ops o
--            el backend. Es consciente de QUIÉN llama, cosa que un GRANT no
--            puede expresar. Esta es la que de verdad cierra el agujero.
--   Capa 2 — PRIVILEGIOS POR COLUMNA: `authenticated` pierde el UPDATE de tabla
--            y recibe UPDATE solo sobre las columnas de perfil. Así, aunque
--            alguien borrara el trigger, 58 de las 98 columnas siguen fuera de
--            su alcance.
--
-- ── COMPATIBILIDAD CON LA APP INSTALADA (requisito previo) ────────────────
-- Inventario completo de escrituras a `groups` en `src/`, `web/`, `navigation/` y
-- `supabase/functions/`: **19 escrituras**, todas con un objeto EXPLÍCITO y corto.
-- NO existe ninguna pantalla que mande "el objeto completo", así que nadie manda
-- accidentalmente una columna protegida. Aun así, el trigger compara OLD vs NEW y
-- solo rechaza CAMBIOS REALES: una versión vieja que reenvíe una columna
-- protegida con el mismo valor que ya tenía sigue guardando sin error. Eso es lo
-- que hace que este parche no dependa de actualizar la app.
--
-- Caso especial, el INSERT de grupo (`group/DashboardScreen.tsx:868`): manda
-- `is_verified: false` y `verification_status: 'none'`. En vez de rechazarlo
-- (rompería la pantalla), el trigger FUERZA los valores seguros en INSERT, así
-- que la pantalla sigue funcionando y un cliente malicioso que mandara
-- `is_verified: true` tampoco lo consigue.
--
-- ── EL BLOQUEADOR QUE APARECIÓ EN EL INVENTARIO ───────────────────────────
-- `update_group_rating()` es un trigger sobre `reviews` que hace
-- `UPDATE groups SET rating = …, total_reviews = …`, y estaba en **SECURITY
-- INVOKER**: al dejar una reseña, ese UPDATE corría CON EL ROL DEL CLIENTE. Tal
-- cual, este parche habría roto el dejar reseñas por los dos lados (el privilegio
-- de columna y el trigger de guarda).
-- Se corrige pasándola a SECURITY DEFINER con `search_path` fijo. El cuerpo NO
-- cambia: sigue recalculando el promedio desde `reviews`. Además cierra de paso
-- otro agujero, porque el cliente deja de necesitar permiso de escritura sobre
-- `groups.rating` — hoy lo tenía, y con él podía inflarse su propia calificación.
-- Es el ÚNICO caller SECURITY INVOKER que escribe `groups` (verificado sobre las
-- 249 funciones INVOKER del esquema).
--
-- ── LO QUE NO SE TOCA ─────────────────────────────────────────────────────
-- SELECT de `groups` sigue público (el explorador lo necesita). INSERT y DELETE
-- no se modifican. `service_role` y `postgres` intactos. Las columnas del
-- catálogo comercial (min_hours, included_hours, extra_hour_price, capacity_max,
-- price_from) NO se le conceden a `authenticated`: su única vía es la RPC
-- `set_group_commercial_catalog`, que es SECURITY DEFINER y corre como el owner
-- (sql/720+722). No se abre UPDATE general para arreglar una RPC.
-- No se cambia lógica de negocio, ni precios, ni comisión, ni extra_hours, ni
-- Express, ni cancelaciones. 722/723/697/700 siguen sin aplicar.
-- ═══════════════════════════════════════════════════════════════════════════

BEGIN;

DO $guard$
BEGIN
  IF to_regclass('public.groups') IS NULL THEN
    RAISE EXCEPTION 'No existe public.groups. Abortando.';
  END IF;
  IF EXISTS (SELECT 1 FROM pg_trigger WHERE tgrelid='public.groups'::regclass
             AND tgname='trg_00_guard_platform_columns') THEN
    RAISE EXCEPTION 'El trigger ya existe. 726 ya se aplico? Revisar a mano.';
  END IF;
  -- La politica del dueño debe seguir ahi: esta migracion NO toca RLS.
  IF NOT EXISTS (SELECT 1 FROM pg_policy WHERE polrelid='public.groups'::regclass
                 AND polname='groups_owner_all') THEN
    RAISE EXCEPTION 'Falta la politica groups_owner_all; el modelo cambio. Reauditar.';
  END IF;
END
$guard$;

-- ── 0.bis El unico caller SECURITY INVOKER que escribe groups ──────────────
-- Sin esto, dejar una resena fallaria: el trigger de `reviews` actualiza
-- groups.rating con el rol del cliente.
DO $rating$
DECLARE
  v_def TEXT;
  v_nl  TEXT;
  v_n   INT;
BEGIN
  IF (SELECT md5(prosrc) FROM pg_proc WHERE oid = to_regprocedure('public.update_group_rating()'))
     <> '80b63a72a83e76bbc696ac68412ecee5' THEN
    RAISE EXCEPTION 'update_group_rating cambio (md5 <> 80b63a72...). Reauditar antes de aplicar 726.';
  END IF;

  SELECT pg_get_functiondef(oid) INTO v_def FROM pg_proc
  WHERE oid = to_regprocedure('public.update_group_rating()');

  -- OJO: el ENCABEZADO que genera pg_get_functiondef usa chr(10), pero el CUERPO
  -- de esta funcion trae CRLF. Por eso el ancla NO incluye ningun salto de linea:
  -- se corta justo despues de la clausula LANGUAGE y se insertan las dos nuevas.
  v_nl := chr(10);
  v_n := (length(v_def) - length(replace(v_def, ' LANGUAGE plpgsql', '')))
         / length(' LANGUAGE plpgsql');
  IF v_n <> 1 THEN
    RAISE EXCEPTION 'update_group_rating: esperaba 1 clausula LANGUAGE, encontre %', v_n;
  END IF;

  v_def := replace(v_def,
    ' LANGUAGE plpgsql',
    ' LANGUAGE plpgsql' || v_nl || ' SECURITY DEFINER' || v_nl ||
    ' SET search_path TO ''public''');

  EXECUTE v_def;
END
$rating$;

COMMENT ON FUNCTION public.update_group_rating() IS
  'sql/726 — recalcula groups.rating y total_reviews desde reviews. Paso a SECURITY DEFINER: antes corria con el rol del cliente que dejaba la resena, asi que el cliente necesitaba (y tenia) permiso de escritura sobre groups.rating. El cuerpo no cambio.';

-- Al volverse SECURITY DEFINER queda en la misma categoria que las 63 funciones
-- de trigger que cerro sql/724: nadie la invoca directo y dispararse NO consulta
-- EXECUTE. Se le aplica el mismo REVOKE para que no quede como una SECDEF que
-- escribe groups abierta a anon (lo detecto el canario de sql/727).
REVOKE EXECUTE ON FUNCTION public.update_group_rating() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.update_group_rating() FROM anon;
REVOKE EXECUTE ON FUNCTION public.update_group_rating() FROM authenticated;

-- ── 1. CAPA 1: el trigger ──────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.guard_group_platform_columns()
RETURNS trigger
LANGUAGE plpgsql
SECURITY INVOKER          -- a proposito: necesita ver el rol REAL de quien llama
SET search_path TO 'public'
AS $function$
DECLARE
  -- Columnas que decide Daricefy, nunca el proveedor.
  v_protegidas TEXT[] := ARRAY[
    -- Plus y suscripcion
    'is_plus_active','plus_expires_at','plus_subscription_id',
    -- posicionamiento pagado
    'bid_amount','bid_ends_at',
    -- boost y ranking
    'ranking_boost','boost_expires_at','boost_ends_at','boost_score','ranking_score',
    'search_penalty','visibility_penalty_until','is_high_demand',
    -- verificacion y moderacion de medios
    'is_verified','admin_verified','verification_status','verification_level',
    'photo_status','video_status','photo_reject_reason','video_reject_reason',
    -- destacado por Admin
    'admin_highlight',
    -- castigos
    'strike_count','last_strike_at','suspended_at','suspended_by','warnings_count',
    'compliance_flags','penalty_expires_at','reliability_penalty','cancelaciones',
    -- dinero
    'commission_percentage',
    -- scores y contadores que calcula la plataforma
    'trust_score','reliability_score','puntos_reputacion','nivel','rating',
    'average_rating','total_reviews','total_events_completed','total_eventos_completados',
    'recent_completions','members_count','last_booked_at','extra_hours_rate','badges',
    -- referidos
    'referral_code','referral_rate','referral_bonus_expires_at','referred_by_user_id',
    -- Stripe Connect
    'stripe_account_id','stripe_onboarding_completed',
    -- banderas operativas de plataforma
    'is_active','concierge_mode','express_enabled',
    -- catalogo comercial: solo por set_group_commercial_catalog (sql/720+722)
    'min_hours','included_hours','extra_hour_price','capacity_max','price_from',
    -- y nadie regala ni roba un grupo
    'owner_id'
  ];
  v_uid       UUID := auth.uid();
  v_jwt_role  TEXT := COALESCE(auth.role(), '');
  v_backend   BOOLEAN;
  v_admin     BOOLEAN;
  v_old       JSONB;
  v_new       JSONB;
  v_col       TEXT;
BEGIN
  -- ── ¿Quien llama? ────────────────────────────────────────────────────────
  -- Backend si: es service_role, o no hay JWT (cron / psql / migracion), o el
  -- usuario efectivo ya es un rol privilegiado porque quien nos invoco es una
  -- funcion SECURITY DEFINER (ahi current_user pasa a ser su owner).
  -- auth.uid() NO se usa como senal: anon tambien lo tiene en NULL.
  v_backend := v_jwt_role IN ('service_role', '')
            OR current_user IN ('postgres', 'service_role', 'supabase_admin');
  IF v_backend THEN
    RETURN NEW;
  END IF;

  v_admin := v_uid IS NOT NULL AND EXISTS (
    SELECT 1 FROM public.profiles p
    WHERE p.id = v_uid AND p.role IN ('admin', 'admin_ops'));
  IF v_admin THEN
    RETURN NEW;
  END IF;

  -- ── A partir de aqui: proveedor o cliente normal ─────────────────────────
  IF TG_OP = 'INSERT' THEN
    -- Un grupo nuevo nace SIN privilegios, diga lo que diga el cliente. Se
    -- fuerzan en vez de rechazar para no romper la pantalla de crear grupo, que
    -- hoy manda is_verified:false y verification_status:'none'.
    NEW.is_verified          := false;
    NEW.admin_verified       := false;
    NEW.verification_status  := 'none';
    NEW.verification_level   := NULL;
    NEW.admin_highlight      := false;
    NEW.is_plus_active       := false;
    NEW.plus_expires_at      := NULL;
    NEW.plus_subscription_id := NULL;
    NEW.ranking_boost        := NULL;
    NEW.boost_expires_at     := NULL;
    NEW.bid_amount           := NULL;
    NEW.bid_ends_at          := NULL;
    NEW.strike_count         := 0;
    NEW.suspended_at         := NULL;
    NEW.suspended_by         := NULL;
    NEW.commission_percentage := NULL;
    NEW.trust_score          := NULL;
    NEW.min_hours            := NULL;
    NEW.included_hours       := NULL;
    NEW.extra_hour_price     := NULL;
    NEW.capacity_max         := NULL;
    NEW.price_from           := NULL;
    RETURN NEW;
  END IF;

  -- UPDATE: se rechaza el CAMBIO, no el hecho de mencionar la columna. Mandar el
  -- mismo valor que ya estaba no falla, y eso es lo que mantiene compatible a
  -- cualquier version instalada.
  v_old := to_jsonb(OLD);
  v_new := to_jsonb(NEW);

  FOREACH v_col IN ARRAY v_protegidas LOOP
    IF v_old -> v_col IS DISTINCT FROM v_new -> v_col THEN
      RAISE EXCEPTION
        'forbidden: "%" de groups la controla Daricefy, no el proveedor', v_col
        USING ERRCODE = '42501',
              HINT = 'Ese dato se cambia desde Admin o por su RPC correspondiente.';
    END IF;
  END LOOP;

  RETURN NEW;
END;
$function$;

COMMENT ON FUNCTION public.guard_group_platform_columns() IS
  'sql/726 — impide que un proveedor se auto-conceda Plus, boost, bid, verificacion, destacado, comision 0, o se borre strikes/suspension editando su propia fila de groups. Deja pasar al backend (service_role, sin JWT, o SECURITY DEFINER) y a admin/admin_ops. En UPDATE compara OLD vs NEW y solo rechaza CAMBIOS, para no romper versiones instaladas que reenvien el mismo valor. En INSERT fuerza los valores seguros.';

-- trg_00_: debe correr ANTES que los demas BEFORE de groups.
CREATE TRIGGER trg_00_guard_platform_columns
  BEFORE INSERT OR UPDATE ON public.groups
  FOR EACH ROW EXECUTE FUNCTION public.guard_group_platform_columns();

-- ── 2. CAPA 2: privilegios por columna ─────────────────────────────────────
-- anon: no existe ningun flujo publico que haga UPDATE a groups (verificado en
-- el inventario: las 19 escrituras son de authenticated o de service_role).
REVOKE UPDATE ON public.groups FROM anon;

-- authenticated: fuera el UPDATE de tabla y fuera cualquier resto por columna
-- (sql/405 habia concedido 12 columnas de equipo una por una).
REVOKE UPDATE ON public.groups FROM authenticated;

DO $limpia$
DECLARE v_sql TEXT;
BEGIN
  SELECT 'REVOKE UPDATE (' || string_agg(quote_ident(attname), ', ' ORDER BY attnum)
         || ') ON public.groups FROM anon, authenticated'
  INTO v_sql
  FROM pg_attribute
  WHERE attrelid='public.groups'::regclass AND attnum > 0 AND NOT attisdropped;
  EXECUTE v_sql;
END
$limpia$;

-- Y de vuelta, solo lo que un proveedor edita de verdad. La lista es GENEROSA a
-- proposito: incluye columnas de perfil que las pantallas actuales ya no mandan,
-- porque el binario instalado puede ser mas viejo que HEAD y no quiero que a
-- alguien le falle guardar su perfil.
GRANT UPDATE (
  -- identidad y presentacion
  name, description, genre, profile_image, promo_video, video_url,
  -- ubicacion
  state, country, city, city_id, state_id, country_id, country_code,
  latitude, longitude, service_cities,
  -- disponibilidad declarada por el proveedor
  availability, available_now, available_now_since,
  -- equipo y logistica (sql/403)
  has_sound, sound_capacity_max, has_lighting, lighting_level,
  has_stage, stage_sizes_available, has_led_screen, led_sizes_available,
  power_amps, needs_parking, setup_minutes, includes_text,
  -- preguntas propias de su categoria (sql/623)
  category_details,
  -- otros ajustes suyos
  has_work_visa, show_gifts_to_members,
  -- marca de tiempo
  updated_at,
  -- COMPARTIDAS CON ADMIN: se conceden porque Admin tambien es `authenticated`
  -- (el panel web usa la anon key con sesion). El trigger de arriba es lo que
  -- impide que un proveedor las cambie.
  is_active, is_verified, verification_status, concierge_mode, express_enabled
) ON public.groups TO authenticated;

-- ── 3. Verificación ────────────────────────────────────────────────────────
DO $verify$
DECLARE
  v_n INT;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgrelid='public.groups'::regclass
                 AND tgname='trg_00_guard_platform_columns' AND tgenabled = 'O') THEN
    RAISE EXCEPTION 'El trigger no quedo activo. Abortando.';
  END IF;

  -- anon no debe poder actualizar NINGUNA columna.
  SELECT COUNT(*) INTO v_n FROM pg_attribute
  WHERE attrelid='public.groups'::regclass AND attnum > 0 AND NOT attisdropped
    AND has_column_privilege('anon', 'public.groups', attname, 'UPDATE');
  IF v_n > 0 THEN
    RAISE EXCEPTION 'anon conserva UPDATE en % columnas de groups. Abortando.', v_n;
  END IF;

  -- authenticated NO debe poder tocar las de plataforma…
  SELECT COUNT(*) INTO v_n FROM unnest(ARRAY[
    'is_plus_active','plus_expires_at','ranking_boost','bid_amount','admin_verified',
    'admin_highlight','strike_count','suspended_at','commission_percentage','trust_score',
    'reliability_score','ranking_score','puntos_reputacion','nivel','owner_id',
    'min_hours','included_hours','extra_hour_price','capacity_max','price_from',
    'stripe_account_id','referral_code']) AS c
  WHERE has_column_privilege('authenticated', 'public.groups', c, 'UPDATE');
  IF v_n > 0 THEN
    RAISE EXCEPTION 'authenticated conserva UPDATE en % columnas de plataforma. Abortando.', v_n;
  END IF;

  -- …y SI debe poder tocar las de su perfil, o se rompe la app.
  SELECT COUNT(*) INTO v_n FROM unnest(ARRAY[
    'name','description','genre','state','country','has_sound','sound_capacity_max',
    'has_lighting','lighting_level','has_stage','stage_sizes_available','has_led_screen',
    'led_sizes_available','power_amps','needs_parking','setup_minutes','includes_text',
    'category_details','has_work_visa','show_gifts_to_members',
    'is_active','is_verified','verification_status','concierge_mode','express_enabled']) AS c
  WHERE NOT has_column_privilege('authenticated', 'public.groups', c, 'UPDATE');
  IF v_n > 0 THEN
    RAISE EXCEPTION 'authenticated perdio UPDATE en % columnas legitimas: romperia la app. Abortando.', v_n;
  END IF;

  -- SELECT publico intacto, INSERT intacto.
  IF NOT has_table_privilege('anon', 'public.groups', 'SELECT') THEN
    RAISE EXCEPTION 'anon perdio el SELECT de groups: romperia el explorador. Abortando.';
  END IF;
  IF NOT has_table_privilege('authenticated', 'public.groups', 'INSERT') THEN
    RAISE EXCEPTION 'authenticated perdio el INSERT de groups: no podria crear su grupo. Abortando.';
  END IF;

  -- service_role y el dueño de la tabla siguen pudiendo todo.
  IF NOT has_table_privilege('service_role', 'public.groups', 'UPDATE') THEN
    RAISE EXCEPTION 'service_role perdio UPDATE sobre groups. Abortando.';
  END IF;

  -- RLS sin cambios.
  IF (SELECT COUNT(*) FROM pg_policy WHERE polrelid='public.groups'::regclass) < 11 THEN
    RAISE EXCEPTION '726 altero las politicas RLS de groups. Abortando.';
  END IF;

  -- Nada de dinero ni de 722.
  IF (SELECT md5(prosrc) FROM pg_proc WHERE oid = to_regprocedure('public.calculate_final_price(numeric,boolean,text,text,numeric,text)'))
     <> '37e3c7bfc9844cc533f6340fed38e206' THEN
    RAISE EXCEPTION '726 modifico calculate_final_price. Abortando.';
  END IF;
  IF (SELECT md5(prosrc) FROM pg_proc WHERE oid = to_regprocedure('public.client_accept_quote(uuid,uuid,integer)'))
     <> '59d981aa1793176834b22c09b0f9c21e' THEN
    RAISE EXCEPTION '726 modifico client_accept_quote (722 sigue sin aplicar). Abortando.';
  END IF;

  -- El trigger de resenas tiene que haber quedado en SECURITY DEFINER, o dejar
  -- una resena fallaria.
  IF NOT (SELECT prosecdef FROM pg_proc WHERE oid = to_regprocedure('public.update_group_rating()')) THEN
    RAISE EXCEPTION 'update_group_rating no quedo SECURITY DEFINER: dejar resenas fallaria. Abortando.';
  END IF;
  IF has_function_privilege('anon','public.update_group_rating()','EXECUTE')
     OR has_function_privilege('authenticated','public.update_group_rating()','EXECUTE') THEN
    RAISE EXCEPTION 'update_group_rating quedo abierta a anon/authenticated. Abortando.';
  END IF;
  -- Y no debe quedar NINGUN otro caller SECURITY INVOKER que escriba groups.
  SELECT COUNT(*) INTO v_n FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
  WHERE n.nspname='public' AND NOT p.prosecdef
    AND p.prosrc ~* '(UPDATE\s+(public\.)?groups|INSERT\s+INTO\s+(public\.)?groups)';
  IF v_n > 0 THEN
    RAISE EXCEPTION 'Quedan % funciones SECURITY INVOKER que escriben groups. Reauditar.', v_n;
  END IF;

  RAISE NOTICE '726 OK — trigger activo, anon sin UPDATE, authenticated acotado por columnas';
END
$verify$;

NOTIFY pgrst, 'reload schema';

COMMIT;
