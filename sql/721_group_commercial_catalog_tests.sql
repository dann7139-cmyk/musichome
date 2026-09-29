-- ═══════════════════════════════════════════════════════════════════════════
-- 721 — SUITE AUTORREVERTIBLE de sql/720 (catálogo comercial)
-- ═══════════════════════════════════════════════════════════════════════════
-- Se ejecuta DESPUÉS de aplicar sql/720. No deja nada: la excepción final es el
-- reporte y revierte todo. Datos 100% sintéticos.
--
-- Cubre las 13 pruebas obligatorias de la autorización, etiquetadas [O1]…[O13],
-- más controles extra etiquetados [X].
--
--   [O1]  owner puede leer/editar únicamente su catálogo
--   [O2]  Admin autorizado puede editar catálogo de un grupo
--   [O3]  usuario ajeno no puede modificarlo
--   [O4]  valores NULL funcionan
--   [O5]  min_hours no acepta valores inválidos
--   [O6]  included_hours no acepta valores inválidos
--   [O7]  extra_hour_price no acepta negativos
--   [O8]  capacity_max no acepta valores inválidos
--   [O9]  aprobación de una provider_application conserva min_hours numéricamente
--   [O10] proveedores históricos no reciben valores inventados
--   [O11] no se modifica extra_hours
--   [O12] no cambia cálculo de quotes/margen
--   [O13] no cambia ningún flujo de pagos
--
-- CÓMO SE SIMULA CADA USUARIO: `auth.uid()` lee
-- `current_setting('request.jwt.claims')::jsonb->>'sub'`, así que se cambia con
-- `set_config('request.jwt.claims', …, true)` — local a la transacción. Para las
-- pruebas de RLS además se cambia el ROL de Postgres a `authenticated`, que es
-- lo que de verdad usa la app.
-- ═══════════════════════════════════════════════════════════════════════════

BEGIN;

CREATE TEMP TABLE _r (i serial, nombre text, ok boolean, detalle text) ON COMMIT DROP;

CREATE OR REPLACE FUNCTION pg_temp.chk(n text, cond boolean, d text DEFAULT '')
RETURNS void LANGUAGE sql AS $$
  INSERT INTO _r (nombre, ok, detalle) VALUES (n, COALESCE(cond, false), d);
$$;

-- Se vuelve "ese usuario" para las llamadas siguientes.
CREATE OR REPLACE FUNCTION pg_temp.actuar_como(p_uid uuid)
RETURNS void LANGUAGE sql AS $$
  SELECT set_config('request.jwt.claims',
    json_build_object('sub', p_uid::text, 'role', 'authenticated')::text, true);
$$;

DO $suite$
DECLARE
  u_owner_a UUID := gen_random_uuid();
  u_owner_b UUID := gen_random_uuid();
  u_admin   UUID := gen_random_uuid();
  u_ops_mx  UUID := gen_random_uuid();
  u_cliente UUID := gen_random_uuid();
  g_a       UUID := gen_random_uuid();   -- de u_owner_a, México
  g_b       UUID := gen_random_uuid();   -- de u_owner_b, México
  g_us      UUID := gen_random_uuid();   -- de u_owner_b, Estados Unidos
  v_app     UUID;
  v_res     JSONB;
  v_n       INT;
  v_mh      NUMERIC;
  v_grupo_nuevo UUID;
  v_huella_extra TEXT;
  v_huella_extra2 TEXT;
  v_huella_pagos TEXT;
  v_huella_pagos2 TEXT;
  v_nulos_antes INT;
  r         RECORD;
BEGIN
  -- ═══════════ 0. PRECONDICIONES ═══════════
  PERFORM pg_temp.chk('[X] 720 aplicado: las 4 columnas existen en groups',
    (SELECT COUNT(*) FROM pg_attribute WHERE attrelid='public.groups'::regclass
       AND attname IN ('min_hours','included_hours','extra_hour_price','capacity_max')
       AND NOT attisdropped) = 4);
  PERFORM pg_temp.chk('[X] existe la RPC del catalogo',
    to_regprocedure('public.set_group_commercial_catalog(uuid,numeric,numeric,numeric,integer)') IS NOT NULL);
  PERFORM pg_temp.chk('[X] anon NO puede ejecutar la RPC',
    NOT has_function_privilege('anon','public.set_group_commercial_catalog(uuid,numeric,numeric,numeric,integer)','EXECUTE'));
  PERFORM pg_temp.chk('[X] authenticated SI puede ejecutar la RPC',
    has_function_privilege('authenticated','public.set_group_commercial_catalog(uuid,numeric,numeric,numeric,integer)','EXECUTE'));
  PERFORM pg_temp.chk('[X] solo queda UNA version de submit_provider_application',
    (SELECT COUNT(*) FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
      WHERE n.nspname='public' AND p.proname='submit_provider_application') = 1);
  PERFORM pg_temp.chk('[X] el registro publico sigue ejecutable por anon',
    has_function_privilege('anon',
      'public.submit_provider_application(text,text,text,integer,numeric,text,text,text,text,numeric,numeric,integer)',
      'EXECUTE'));

  -- Huellas de "nada de esto se movio", tomadas ANTES de todo.
  SELECT (SELECT COUNT(*) FROM public.extra_hours)::text || '/' ||
         (SELECT COALESCE(SUM(total_extra_cost),0)::text FROM public.extra_hours) || '/' ||
         (SELECT md5(prosrc) FROM pg_proc WHERE oid=to_regprocedure('public.request_overtime(uuid,numeric,numeric)'))
    INTO v_huella_extra;
  SELECT (SELECT COUNT(*) FROM public.reservations)::text || '/' ||
         (SELECT COUNT(*) FROM public.wallet_transactions)::text || '/' ||
         (SELECT COUNT(*) FROM public.payment_receipts)::text || '/' ||
         (SELECT COALESCE(SUM(amount),0)::text FROM public.wallet_transactions)
    INTO v_huella_pagos;
  SELECT COUNT(*) INTO v_nulos_antes FROM public.groups WHERE min_hours IS NULL;

  -- ═══════════ 1. ACTORES ═══════════
  INSERT INTO auth.users (id) VALUES (u_owner_a),(u_owner_b),(u_admin),(u_ops_mx),(u_cliente);
  INSERT INTO public.profiles (id, full_name, role, admin_country_scope) VALUES
    (u_owner_a, 'Dueno A Sintetico', 'group',     NULL),
    (u_owner_b, 'Dueno B Sintetico', 'group',     NULL),
    (u_admin,   'Admin Sintetico',   'admin',     NULL),
    (u_ops_mx,  'Ops MX Sintetico',  'admin_ops', 'MX'),
    (u_cliente, 'Cliente Sintetico', 'client',    NULL)
  ON CONFLICT (id) DO UPDATE SET full_name = EXCLUDED.full_name, role = EXCLUDED.role,
                                 admin_country_scope = EXCLUDED.admin_country_scope;

  INSERT INTO public.groups (id, name, owner_id, state, country, genre, concierge_mode) VALUES
    (g_a,  'Grupo A Sintetico',  u_owner_a, 'Durango', 'México',          'Norteño', false),
    (g_b,  'Grupo B Sintetico',  u_owner_b, 'Durango', 'México',          'Banda',   true),
    (g_us, 'Grupo US Sintetico', u_owner_b, 'Texas',   'Estados Unidos',  'Country', true);

  -- ═══════════ [O1] el dueño edita SU catalogo ═══════════
  PERFORM pg_temp.actuar_como(u_owner_a);
  v_res := public.set_group_commercial_catalog(g_a, 3, 4, 900, 250);
  PERFORM pg_temp.chk('[O1] el dueno edita su propio catalogo', (v_res->>'ok')::boolean, v_res::text);
  PERFORM pg_temp.chk('[O1] los 4 valores quedaron guardados',
    (SELECT min_hours = 3 AND included_hours = 4 AND extra_hour_price = 900 AND capacity_max = 250
       FROM public.groups WHERE id = g_a));
  PERFORM pg_temp.chk('[O1] el dueno LEE su catalogo',
    (SELECT min_hours IS NOT NULL FROM public.groups WHERE id = g_a));

  -- …y NO el de otro grupo
  v_res := public.set_group_commercial_catalog(g_b, 8, 8, 1, 1);
  PERFORM pg_temp.chk('[O1] el dueno NO puede editar el catalogo de otro grupo',
    (v_res->>'error') = 'not_allowed', v_res::text);
  PERFORM pg_temp.chk('[O1] y el otro grupo sigue intacto',
    (SELECT min_hours IS NULL AND included_hours IS NULL FROM public.groups WHERE id = g_b));

  -- ═══════════ [O2] Admin edita el catalogo de un grupo ajeno ═══════════
  PERFORM pg_temp.actuar_como(u_admin);
  v_res := public.set_group_commercial_catalog(g_b, 5, 5, 1200, NULL);
  PERFORM pg_temp.chk('[O2] Admin edita el catalogo de un grupo que no es suyo',
    (v_res->>'ok')::boolean, v_res::text);
  PERFORM pg_temp.chk('[O2] el dato quedo en el MISMO groups.id (una sola fuente)',
    (SELECT min_hours = 5 AND extra_hour_price = 1200 AND capacity_max IS NULL
       FROM public.groups WHERE id = g_b));

  -- admin_ops: solo su pais
  PERFORM pg_temp.actuar_como(u_ops_mx);
  v_res := public.set_group_commercial_catalog(g_b, 6, 6, 1300, 300);
  PERFORM pg_temp.chk('[X] admin_ops MX SI puede editar un grupo de México',
    (v_res->>'ok')::boolean, v_res::text);
  v_res := public.set_group_commercial_catalog(g_us, 6, 6, 1300, 300);
  PERFORM pg_temp.chk('[X] admin_ops MX NO puede editar un grupo de Estados Unidos',
    (v_res->>'error') = 'not_allowed', v_res::text);

  -- ═══════════ [O3] un usuario ajeno no puede ═══════════
  PERFORM pg_temp.actuar_como(u_cliente);
  v_res := public.set_group_commercial_catalog(g_a, 12, 12, 5, 5);
  PERFORM pg_temp.chk('[O3] un cliente NO puede modificar el catalogo',
    (v_res->>'error') = 'not_allowed', v_res::text);
  PERFORM pg_temp.actuar_como(u_owner_b);
  v_res := public.set_group_commercial_catalog(g_a, 12, 12, 5, 5);
  PERFORM pg_temp.chk('[O3] otro proveedor NO puede modificar el catalogo ajeno',
    (v_res->>'error') = 'not_allowed', v_res::text);
  PERFORM pg_temp.chk('[O3] el catalogo de A sigue con sus valores',
    (SELECT min_hours = 3 AND capacity_max = 250 FROM public.groups WHERE id = g_a));

  -- Y tampoco por UPDATE directo: aqui se prueba RLS de verdad, con el rol
  -- `authenticated` que usa la app (no como postgres, que la evade).
  PERFORM pg_temp.actuar_como(u_owner_b);
  BEGIN
    -- set_config('role', …) equivale a SET ROLE y si se puede usar desde plpgsql.
    PERFORM set_config('role', 'authenticated', true);
    UPDATE public.groups SET min_hours = 99 WHERE id = g_a;
    GET DIAGNOSTICS v_n = ROW_COUNT;
    PERFORM set_config('role', 'postgres', true);
  EXCEPTION WHEN OTHERS THEN
    PERFORM set_config('role', 'postgres', true);
    v_n := -1;
  END;
  PERFORM pg_temp.chk('[O3] UPDATE directo de un proveedor ajeno no afecta ninguna fila (RLS)',
    v_n = 0, 'filas=' || v_n);
  PERFORM pg_temp.chk('[O3] y el valor no cambio',
    (SELECT min_hours = 3 FROM public.groups WHERE id = g_a));

  -- ═══════════ [O4] NULL es un valor valido ═══════════
  PERFORM pg_temp.actuar_como(u_owner_a);
  v_res := public.set_group_commercial_catalog(g_a, NULL, NULL, NULL, NULL);
  PERFORM pg_temp.chk('[O4] la RPC acepta los 4 en NULL', (v_res->>'ok')::boolean, v_res::text);
  PERFORM pg_temp.chk('[O4] los 4 quedaron en NULL (se puede vaciar el catalogo)',
    (SELECT min_hours IS NULL AND included_hours IS NULL
        AND extra_hour_price IS NULL AND capacity_max IS NULL
       FROM public.groups WHERE id = g_a));
  v_res := public.set_group_commercial_catalog(g_a, 3, NULL, NULL, NULL);
  PERFORM pg_temp.chk('[O4] se puede declarar solo min_hours y dejar el resto en NULL',
    (v_res->>'ok')::boolean AND
    (SELECT min_hours = 3 AND capacity_max IS NULL FROM public.groups WHERE id = g_a));

  -- ═══════════ [O5]…[O8] valores invalidos ═══════════
  v_res := public.set_group_commercial_catalog(g_a, 0, NULL, NULL, NULL);
  PERFORM pg_temp.chk('[O5] min_hours = 0 rechazado', (v_res->>'error') = 'invalid_min_hours', v_res::text);
  v_res := public.set_group_commercial_catalog(g_a, -2, NULL, NULL, NULL);
  PERFORM pg_temp.chk('[O5] min_hours negativo rechazado', (v_res->>'error') = 'invalid_min_hours', v_res::text);
  v_res := public.set_group_commercial_catalog(g_a, 25, NULL, NULL, NULL);
  PERFORM pg_temp.chk('[O5] min_hours > 24 rechazado', (v_res->>'error') = 'invalid_min_hours', v_res::text);

  v_res := public.set_group_commercial_catalog(g_a, NULL, 0, NULL, NULL);
  PERFORM pg_temp.chk('[O6] included_hours = 0 rechazado', (v_res->>'error') = 'invalid_included_hours', v_res::text);
  v_res := public.set_group_commercial_catalog(g_a, NULL, -1, NULL, NULL);
  PERFORM pg_temp.chk('[O6] included_hours negativo rechazado', (v_res->>'error') = 'invalid_included_hours', v_res::text);
  v_res := public.set_group_commercial_catalog(g_a, NULL, 30, NULL, NULL);
  PERFORM pg_temp.chk('[O6] included_hours > 24 rechazado', (v_res->>'error') = 'invalid_included_hours', v_res::text);

  v_res := public.set_group_commercial_catalog(g_a, NULL, NULL, -1, NULL);
  PERFORM pg_temp.chk('[O7] extra_hour_price negativo rechazado', (v_res->>'error') = 'invalid_extra_hour_price', v_res::text);
  v_res := public.set_group_commercial_catalog(g_a, NULL, NULL, 0, NULL);
  PERFORM pg_temp.chk('[O7] extra_hour_price = 0 SI se acepta (hora extra de cortesia)',
    (v_res->>'ok')::boolean, v_res::text);

  v_res := public.set_group_commercial_catalog(g_a, NULL, NULL, NULL, 0);
  PERFORM pg_temp.chk('[O8] capacity_max = 0 rechazado', (v_res->>'error') = 'invalid_capacity_max', v_res::text);
  v_res := public.set_group_commercial_catalog(g_a, NULL, NULL, NULL, -5);
  PERFORM pg_temp.chk('[O8] capacity_max negativo rechazado', (v_res->>'error') = 'invalid_capacity_max', v_res::text);
  v_res := public.set_group_commercial_catalog(g_a, NULL, NULL, NULL, 999999);
  PERFORM pg_temp.chk('[O8] capacity_max absurdo rechazado', (v_res->>'error') = 'invalid_capacity_max', v_res::text);

  -- Los CHECK son la garantia dura: valen aunque alguien NO use la RPC.
  BEGIN
    UPDATE public.groups SET min_hours = -3 WHERE id = g_a;
    v_n := 0;  -- no debio llegar aqui
  EXCEPTION WHEN check_violation THEN v_n := 1;
  END;
  PERFORM pg_temp.chk('[O5] el CHECK bloquea min_hours negativo por UPDATE directo', v_n = 1);
  BEGIN
    UPDATE public.groups SET included_hours = 99 WHERE id = g_a;
    v_n := 0;
  EXCEPTION WHEN check_violation THEN v_n := 1;
  END;
  PERFORM pg_temp.chk('[O6] el CHECK bloquea included_hours fuera de rango por UPDATE directo', v_n = 1);
  BEGIN
    UPDATE public.groups SET extra_hour_price = -50 WHERE id = g_a;
    v_n := 0;
  EXCEPTION WHEN check_violation THEN v_n := 1;
  END;
  PERFORM pg_temp.chk('[O7] el CHECK bloquea extra_hour_price negativo por UPDATE directo', v_n = 1);
  BEGIN
    UPDATE public.groups SET capacity_max = 0 WHERE id = g_a;
    v_n := 0;
  EXCEPTION WHEN check_violation THEN v_n := 1;
  END;
  PERFORM pg_temp.chk('[O8] el CHECK bloquea capacity_max = 0 por UPDATE directo', v_n = 1);

  -- incluidas < minimo: AVISO, no error (decision documentada en 720)
  PERFORM pg_temp.actuar_como(u_owner_a);
  v_res := public.set_group_commercial_catalog(g_a, 6, 4, NULL, NULL);
  PERFORM pg_temp.chk('[X] incluidas < minimo se guarda pero devuelve aviso',
    (v_res->>'ok')::boolean AND (v_res->'avisos') ? 'included_lt_min', v_res::text);
  v_res := public.set_group_commercial_catalog(g_a, 6, 8, NULL, NULL);
  PERFORM pg_temp.chk('[X] incluidas > minimo es valido y sin aviso',
    (v_res->>'ok')::boolean AND jsonb_array_length(v_res->'avisos') = 0, v_res::text);

  -- ═══════════ [O9] la aprobacion conserva el numero ═══════════
  PERFORM pg_temp.actuar_como(u_cliente);   -- el registro es publico
  v_res := public.submit_provider_application(
    'Proveedor Sintetico 721', '6181112233', 'terraza', 7, 5.5,
    'México', 'Durango', 'Durango', 'notas de prueba', 6.5, 850, 180);
  PERFORM pg_temp.chk('[O9] el registro acepta los 4 datos comerciales',
    (v_res->>'ok')::boolean, v_res::text);
  v_app := (v_res->>'application_id')::uuid;
  PERFORM pg_temp.chk('[O9] la solicitud los guarda numericamente',
    (SELECT min_hours = 5.5 AND included_hours = 6.5 AND extra_hour_price = 850 AND capacity_max = 180
       FROM public.provider_applications WHERE id = v_app));

  PERFORM pg_temp.actuar_como(u_admin);
  v_res := public.admin_approve_provider_application(
    v_app, 'sintetico721_' || substr(v_app::text,1,8) || '@daricefy.test', 'Norteño', 'ClaveTemporal721');
  PERFORM pg_temp.chk('[O9] la aprobacion corre ok', (v_res->>'ok')::boolean, v_res::text);
  v_grupo_nuevo := (v_res->>'group_id')::uuid;
  PERFORM pg_temp.chk('[O9] el grupo nace con min_hours NUMERICO (ya no solo en la prosa)',
    (SELECT min_hours = 5.5 FROM public.groups WHERE id = v_grupo_nuevo),
    'min_hours=' || COALESCE((SELECT min_hours::text FROM public.groups WHERE id = v_grupo_nuevo),'NULL'));
  PERFORM pg_temp.chk('[O9] y con los otros tres datos del catalogo',
    (SELECT included_hours = 6.5 AND extra_hour_price = 850 AND capacity_max = 180
       FROM public.groups WHERE id = v_grupo_nuevo));
  PERFORM pg_temp.chk('[X] la prosa de la descripcion se conserva igual que antes',
    (SELECT description LIKE '%Contrataci%n m%nima: 5.5 horas.%' FROM public.groups WHERE id = v_grupo_nuevo),
    COALESCE((SELECT description FROM public.groups WHERE id = v_grupo_nuevo),'NULL'));
  PERFORM pg_temp.chk('[X] el grupo nuevo nace en conserjeria (comportamiento previo intacto)',
    (SELECT concierge_mode FROM public.groups WHERE id = v_grupo_nuevo));

  -- Una solicitud SIN datos comerciales no debe inventar nada.
  PERFORM pg_temp.actuar_como(u_cliente);
  v_res := public.submit_provider_application(
    'Proveedor Sin Datos 721', '6184445566', 'comida', 3, NULL, 'México', 'Durango', 'Durango', NULL);
  v_app := (v_res->>'application_id')::uuid;
  PERFORM pg_temp.chk('[X] el registro sigue funcionando con la firma de 9 argumentos',
    (v_res->>'ok')::boolean, v_res::text);
  PERFORM pg_temp.actuar_como(u_admin);
  v_res := public.admin_approve_provider_application(
    v_app, 'sindatos721_' || substr(v_app::text,1,8) || '@daricefy.test', 'Taquizas', 'ClaveTemporal721');
  v_grupo_nuevo := (v_res->>'group_id')::uuid;
  PERFORM pg_temp.chk('[O10] sin dato declarado, el grupo nace con los 4 en NULL',
    (SELECT min_hours IS NULL AND included_hours IS NULL
        AND extra_hour_price IS NULL AND capacity_max IS NULL
       FROM public.groups WHERE id = v_grupo_nuevo));

  -- ═══════════ [O10] los historicos no reciben valores inventados ═══════════
  PERFORM pg_temp.chk('[O10] ningun grupo tiene min_hours sin origen numerico en su solicitud',
    NOT EXISTS (
      SELECT 1 FROM public.groups g
      WHERE g.min_hours IS NOT NULL
        AND g.id NOT IN (g_a, g_b, g_us)
        AND NOT EXISTS (
          SELECT 1 FROM public.provider_applications a
          WHERE a.linked_group_id = g.id AND a.min_hours = g.min_hours)));
  PERFORM pg_temp.chk('[O10] los grupos sin solicitud con numero siguen en NULL',
    (SELECT COUNT(*) FROM public.groups g
      WHERE g.min_hours IS NULL
        AND NOT EXISTS (SELECT 1 FROM public.provider_applications a
                        WHERE a.linked_group_id = g.id AND a.min_hours IS NOT NULL)) >= 1,
    'grupos en NULL antes de la suite: ' || v_nulos_antes);
  PERFORM pg_temp.chk('[O10] nadie recibio included_hours / extra_hour_price / capacity_max de la nada',
    (SELECT COUNT(*) FROM public.groups
      WHERE (included_hours IS NOT NULL OR extra_hour_price IS NOT NULL OR capacity_max IS NOT NULL)
        AND id NOT IN (g_a, g_b, g_us)
        AND id NOT IN (SELECT linked_group_id FROM public.provider_applications WHERE linked_group_id IS NOT NULL)) = 0);

  -- ═══════════ [O11] extra_hours intacto ═══════════
  SELECT (SELECT COUNT(*) FROM public.extra_hours)::text || '/' ||
         (SELECT COALESCE(SUM(total_extra_cost),0)::text FROM public.extra_hours) || '/' ||
         (SELECT md5(prosrc) FROM pg_proc WHERE oid=to_regprocedure('public.request_overtime(uuid,numeric,numeric)'))
    INTO v_huella_extra2;
  PERFORM pg_temp.chk('[O11] extra_hours: filas, suma y request_overtime sin cambios',
    v_huella_extra = v_huella_extra2, v_huella_extra || ' -> ' || v_huella_extra2);
  PERFORM pg_temp.chk('[O11] la RPC del catalogo no menciona extra_hours',
    (SELECT prosrc NOT ILIKE '%extra_hours%'
       FROM pg_proc WHERE oid=to_regprocedure('public.set_group_commercial_catalog(uuid,numeric,numeric,numeric,integer)')));
  PERFORM pg_temp.chk('[O11] groups.extra_hours_rate (la estadistica) sigue existiendo y separada',
    EXISTS (SELECT 1 FROM pg_attribute WHERE attrelid='public.groups'::regclass
            AND attname='extra_hours_rate' AND NOT attisdropped));

  -- ═══════════ [O12] quotes / margen intactos ═══════════
  PERFORM pg_temp.chk('[O12] calculate_final_price intacta (md5 37e3c7bf...)',
    (SELECT md5(prosrc) FROM pg_proc WHERE oid=to_regprocedure('public.calculate_final_price(numeric,boolean,text,text,numeric,text)'))
      = '37e3c7bfc9844cc533f6340fed38e206');
  PERFORM pg_temp.chk('[O12] admin_respond_quote intacta (md5 3dc60f49...)',
    (SELECT md5(prosrc) FROM pg_proc WHERE oid=to_regprocedure('public.admin_respond_quote(uuid,numeric,numeric,numeric,numeric,numeric,text)'))
      = '3dc60f49c53d45bff19c2c4f4ea44127');
  PERFORM pg_temp.chk('[O12] calculate_commission intacta (md5 aae27e71...)',
    (SELECT md5(prosrc) FROM pg_proc WHERE oid=to_regprocedure('public.calculate_commission()'))
      = 'aae27e71c8d0cb5489bb83bbac9ea703');
  PERFORM pg_temp.chk('[O12] client_accept_quote intacta (md5 59d981aa...)',
    (SELECT md5(prosrc) FROM pg_proc WHERE oid=to_regprocedure('public.client_accept_quote(uuid,uuid,integer)'))
      = '59d981aa1793176834b22c09b0f9c21e');
  PERFORM pg_temp.chk('[O12] quotes no gano ni perdio columnas de precio',
    (SELECT COUNT(*) FROM pg_attribute WHERE attrelid='public.quotes'::regclass AND NOT attisdropped
       AND attname IN ('base_price','total_amount','commission_pct','commission_amount',
                       'price_per_hour','extra_hour_price','overtime_1h_price','preset_package_price')) = 8);
  PERFORM pg_temp.chk('[X] NO se crearon package_price ni package_enabled en groups',
    NOT EXISTS (SELECT 1 FROM pg_attribute WHERE attrelid='public.groups'::regclass
                AND attname IN ('package_price','package_enabled') AND NOT attisdropped));

  -- ═══════════ [O13] pagos intactos ═══════════
  SELECT (SELECT COUNT(*) FROM public.reservations)::text || '/' ||
         (SELECT COUNT(*) FROM public.wallet_transactions)::text || '/' ||
         (SELECT COUNT(*) FROM public.payment_receipts)::text || '/' ||
         (SELECT COALESCE(SUM(amount),0)::text FROM public.wallet_transactions)
    INTO v_huella_pagos2;
  PERFORM pg_temp.chk('[O13] reservations/wallets/recibos/suma sin cambios',
    v_huella_pagos = v_huella_pagos2, v_huella_pagos || ' -> ' || v_huella_pagos2);
  PERFORM pg_temp.chk('[O13] confirm_reservation_payment_v2 intacta (md5 c32015cf...)',
    (SELECT md5(prosrc) FROM pg_proc WHERE oid=to_regprocedure('public.confirm_reservation_payment_v2(text,text,text,uuid,bigint,text,text,bigint,text,jsonb)'))
      = 'c32015cff0ec4d87db6326eed906f74b');
  PERFORM pg_temp.chk('[O13] la RPC del catalogo no menciona pagos ni comision',
    (SELECT prosrc !~* '(payment|stripe|conekta|wallet|commission|comision|refund|reembolso)'
       FROM pg_proc WHERE oid=to_regprocedure('public.set_group_commercial_catalog(uuid,numeric,numeric,numeric,integer)')));
  PERFORM pg_temp.chk('[X] make_busy_range intacta: 720 NO toco la duracion (md5 84501069...)',
    (SELECT md5(prosrc) FROM pg_proc WHERE oid=to_regprocedure('public.make_busy_range(date,time without time zone,text,numeric,integer)'))
      = '845010692b27fc02ab313d1937788a59');

  -- ═══════════ REPORTE ═══════════
  DECLARE
    v_rep  TEXT := E'\n';
    v_pass INT;
    v_fail INT;
  BEGIN
    FOR r IN SELECT nombre, ok, detalle FROM _r ORDER BY i LOOP
      v_rep := v_rep || CASE WHEN r.ok THEN '  [OK]   ' ELSE '  [FAIL] ' END || r.nombre ||
               CASE WHEN COALESCE(r.detalle,'') = '' THEN '' ELSE E'\n            ' || r.detalle END || E'\n';
    END LOOP;
    SELECT COUNT(*) FILTER (WHERE ok), COUNT(*) FILTER (WHERE NOT ok) INTO v_pass, v_fail FROM _r;
    RAISE EXCEPTION E'TEST_REPORT sql/721 — catalogo comercial%\n  PASS=% FAIL=% (obligatorias O1..O13 + controles X)\n  TODO REVERTIDO.',
      v_rep, v_pass, v_fail;
  END;
END
$suite$;

ROLLBACK;
