-- ═══════════════════════════════════════════════════════════════════════════
-- 723 — SUITE AUTORREVERTIBLE de sql/722 (duración de la quote + price_from)
-- ═══════════════════════════════════════════════════════════════════════════
-- Se ejecuta DESPUÉS de aplicar sql/722. No deja nada: la excepción final es el
-- reporte y revierte todo. Datos 100% sintéticos.
--
-- Pruebas obligatorias de la autorización, etiquetadas [O1]…[O7]:
--   [O1] quote de 3 h  → reservación de 3 h
--   [O2] quote de 5.5 h → "si el esquema actual lo soporta" (NO lo soporta: se
--        demuestra por qué, con el CHECK real)
--   [O3] quote de 10 h → reservación de 10 h
--   [O4] busy_range refleja esa duración
--   [O5] Express conserva su comportamiento
--   [O6] no cambia precio, comisión, pago ni payout
--   [O7] extra_hours permanece intacto
-- Más [P*] para price_from y [X] controles extra.
--
-- CÓMO SE MIDE busy_range: `make_busy_range` arma
--   [inicio - 30 min , inicio + horas + extras*75min + 45 min)
-- así que para una reserva sin horas extra la duración del rango es
--   30 + horas*60 + 45  minutos.
-- Con el defecto, una quote de 10 h daba 4 h 15 min (como si fueran 3 h).
-- ═══════════════════════════════════════════════════════════════════════════

BEGIN;

CREATE TEMP TABLE _r (i serial, nombre text, ok boolean, detalle text) ON COMMIT DROP;

CREATE OR REPLACE FUNCTION pg_temp.chk(n text, cond boolean, d text DEFAULT '')
RETURNS void LANGUAGE sql AS $$
  INSERT INTO _r (nombre, ok, detalle) VALUES (n, COALESCE(cond, false), d);
$$;

CREATE OR REPLACE FUNCTION pg_temp.actuar_como(p_uid uuid)
RETURNS void LANGUAGE sql AS $$
  SELECT set_config('request.jwt.claims',
    json_build_object('sub', p_uid::text, 'role', 'authenticated')::text, true);
$$;

-- Crea una quote sintetica ya "cotizada", lista para aceptar.
CREATE OR REPLACE FUNCTION pg_temp.mkq(p_group uuid, p_client uuid, p_date date, p_horas int)
RETURNS uuid LANGUAGE plpgsql AS $$
DECLARE v_id uuid;
BEGIN
  INSERT INTO public.quotes (
    group_id, client_id, event_type, event_address, event_municipio, event_estado,
    event_date, event_time, duration_hours, venue_covered, venue_size, needs_sound,
    status, num_personas, base_price, total_amount)
  VALUES (
    p_group, p_client, 'fiesta_privada', 'Domicilio Sintetico 723', 'Municipio Sintetico',
    'Zona Test Daricefy', p_date, '18:00', p_horas, 'si', 'salon_mediano', 'no',
    'quoted', 100, 10000, 12500)
  RETURNING id INTO v_id;
  RETURN v_id;
END $$;

-- Minutos que dura el busy_range de una reserva.
CREATE OR REPLACE FUNCTION pg_temp.minutos(p_res uuid)
RETURNS numeric LANGUAGE sql AS $$
  SELECT EXTRACT(EPOCH FROM (upper(busy_range) - lower(busy_range))) / 60
  FROM public.reservations WHERE id = p_res;
$$;

DO $suite$
DECLARE
  u_owner   UUID := gen_random_uuid();
  u_cli     UUID := gen_random_uuid();
  u_admin   UUID := gen_random_uuid();
  g_main    UUID := gen_random_uuid();
  q3        UUID;
  q10       UUID;
  q12       UUID;
  r3        UUID;
  r10       UUID;
  v_res     JSONB;
  v_hoy     DATE := (NOW() AT TIME ZONE 'America/Mexico_City')::date;
  v_n       INT;
  v_huella_dinero  TEXT;
  v_huella_dinero2 TEXT;
  v_huella_extra   TEXT;
  v_huella_extra2  TEXT;
  v_snap_quote  JSONB;
  v_snap_quote2 JSONB;
  v_row     RECORD;
BEGIN
  -- ═══════════ 0. PRECONDICIONES ═══════════
  PERFORM pg_temp.chk('[X] 722 aplicado: client_accept_quote copia duration_hours',
    (SELECT prosrc LIKE '%v_quote.duration_hours%'
       FROM pg_proc WHERE oid=to_regprocedure('public.client_accept_quote(uuid,uuid,integer)')));
  PERFORM pg_temp.chk('[X] y NO metio un COALESCE propio (el 3 vive solo en make_busy_range)',
    (SELECT prosrc NOT LIKE '%COALESCE(v_quote.duration_hours%'
       FROM pg_proc WHERE oid=to_regprocedure('public.client_accept_quote(uuid,uuid,integer)')));
  PERFORM pg_temp.chk('[O4] make_busy_range NO fue modificada (md5 84501069...)',
    (SELECT md5(prosrc) FROM pg_proc
      WHERE oid=to_regprocedure('public.make_busy_range(date,time without time zone,text,numeric,integer)'))
      = '845010692b27fc02ab313d1937788a59');
  PERFORM pg_temp.chk('[X] existe la RPC del catalogo con price_from (6 argumentos)',
    to_regprocedure('public.set_group_commercial_catalog(uuid,numeric,numeric,numeric,integer,numeric)') IS NOT NULL);
  PERFORM pg_temp.chk('[X] solo queda UNA version de la RPC del catalogo',
    (SELECT COUNT(*) FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
      WHERE n.nspname='public' AND p.proname='set_group_commercial_catalog') = 1);

  -- ═══════════ [O2] la quote NO puede expresar 5.5 h ═══════════
  PERFORM pg_temp.chk('[O2] quotes.duration_hours es INTEGER y NOT NULL',
    (SELECT format_type(atttypid,atttypmod) = 'integer' AND attnotnull
       FROM pg_attribute WHERE attrelid='public.quotes'::regclass AND attname='duration_hours'),
    (SELECT format_type(atttypid,atttypmod) || ' notnull=' || attnotnull::text
       FROM pg_attribute WHERE attrelid='public.quotes'::regclass AND attname='duration_hours'));
  PERFORM pg_temp.chk('[O2] y su CHECK la acota a 3..12, asi que 5.5 NO es representable',
    (SELECT pg_get_constraintdef(oid) LIKE '%duration_hours >= 3%duration_hours <= 12%'
       FROM pg_constraint WHERE conrelid='public.quotes'::regclass AND conname='quotes_duration_hours_check'),
    (SELECT pg_get_constraintdef(oid) FROM pg_constraint
      WHERE conrelid='public.quotes'::regclass AND conname='quotes_duration_hours_check'));
  PERFORM pg_temp.chk('[O2] reservations.hours_count SI es numeric: el dia que la quote admita medias horas, el destino ya las aguanta',
    (SELECT format_type(atttypid,atttypmod) = 'numeric'
       FROM pg_attribute WHERE attrelid='public.reservations'::regclass AND attname='hours_count'));
  PERFORM pg_temp.chk('[O2] duration_hours NULL es IMPOSIBLE hoy (0 filas, columna NOT NULL)',
    (SELECT COUNT(*) FROM public.quotes WHERE duration_hours IS NULL) = 0);

  -- ═══════════ 1. ACTORES ═══════════
  INSERT INTO auth.users (id) VALUES (u_owner),(u_cli),(u_admin);
  INSERT INTO public.profiles (id, full_name, role) VALUES
    (u_owner, 'Dueno 723', 'group'),
    (u_cli,   'Cliente 723', 'client'),
    (u_admin, 'Admin 723', 'admin')
  ON CONFLICT (id) DO UPDATE SET full_name = EXCLUDED.full_name, role = EXCLUDED.role;

  INSERT INTO public.groups (id, name, owner_id, state, country, genre, concierge_mode)
  VALUES (g_main, 'Grupo 723 Sintetico', u_owner, 'Durango', 'México', 'Norteño', false);

  -- Huellas de dinero y de extra_hours ANTES de aceptar nada.
  SELECT (SELECT COUNT(*) FROM public.wallet_transactions)::text || '/' ||
         (SELECT COALESCE(SUM(amount),0)::text FROM public.wallet_transactions) || '/' ||
         (SELECT COUNT(*) FROM public.payment_receipts)::text || '/' ||
         (SELECT COALESCE(SUM(total_price),0)::text FROM public.reservations)
    INTO v_huella_dinero;
  SELECT (SELECT COUNT(*) FROM public.extra_hours)::text || '/' ||
         (SELECT COALESCE(SUM(total_extra_cost),0)::text FROM public.extra_hours) || '/' ||
         (SELECT COALESCE(SUM(hours_added),0)::text FROM public.extra_hours)
    INTO v_huella_extra;

  -- ═══════════ [O1] quote de 3 h ═══════════
  q3 := pg_temp.mkq(g_main, u_cli, v_hoy + 60, 3);
  SELECT to_jsonb(q) INTO v_snap_quote FROM public.quotes q WHERE q.id = q3;

  PERFORM pg_temp.actuar_como(u_cli);
  v_res := public.client_accept_quote(q3, NULL, NULL);
  PERFORM pg_temp.chk('[O1] la cotizacion de 3 h se acepta', (v_res->>'ok')::boolean, v_res::text);
  r3 := (v_res->>'reservation_id')::uuid;
  PERFORM pg_temp.chk('[O1] reservations.hours_count = 3',
    (SELECT hours_count = 3 FROM public.reservations WHERE id = r3),
    'hours_count=' || COALESCE((SELECT hours_count::text FROM public.reservations WHERE id = r3),'NULL'));
  PERFORM pg_temp.chk('[O4] busy_range de 3 h = 30 + 180 + 45 = 255 min',
    pg_temp.minutos(r3) = 255, 'minutos=' || COALESCE(pg_temp.minutos(r3)::text,'NULL'));

  -- ═══════════ [O3] quote de 10 h ═══════════
  q10 := pg_temp.mkq(g_main, u_cli, v_hoy + 90, 10);
  PERFORM pg_temp.actuar_como(u_cli);
  v_res := public.client_accept_quote(q10, NULL, NULL);
  PERFORM pg_temp.chk('[O3] la cotizacion de 10 h se acepta', (v_res->>'ok')::boolean, v_res::text);
  r10 := (v_res->>'reservation_id')::uuid;
  PERFORM pg_temp.chk('[O3] reservations.hours_count = 10',
    (SELECT hours_count = 10 FROM public.reservations WHERE id = r10),
    'hours_count=' || COALESCE((SELECT hours_count::text FROM public.reservations WHERE id = r10),'NULL'));
  PERFORM pg_temp.chk('[O4] busy_range de 10 h = 30 + 600 + 45 = 675 min',
    pg_temp.minutos(r10) = 675, 'minutos=' || COALESCE(pg_temp.minutos(r10)::text,'NULL'));
  -- Esta es la prueba del defecto: antes de 722 habria dado 255 (como 3 h).
  PERFORM pg_temp.chk('[O4] y NO 255 min, que es lo que daba el defecto (3 h fijas)',
    pg_temp.minutos(r10) <> 255, 'minutos=' || COALESCE(pg_temp.minutos(r10)::text,'NULL'));
  PERFORM pg_temp.chk('[O4] el rango de 10 h es exactamente 7 h mas largo que el de 3 h',
    pg_temp.minutos(r10) - pg_temp.minutos(r3) = 420,
    'diferencia=' || COALESCE((pg_temp.minutos(r10) - pg_temp.minutos(r3))::text,'NULL'));

  -- ═══════════ [X] el tope del CHECK tambien viaja ═══════════
  q12 := pg_temp.mkq(g_main, u_cli, v_hoy + 120, 12);
  PERFORM pg_temp.actuar_como(u_cli);
  v_res := public.client_accept_quote(q12, NULL, NULL);
  PERFORM pg_temp.chk('[X] quote de 12 h (el maximo) -> reservacion de 12 h y 795 min de rango',
    (SELECT hours_count = 12 FROM public.reservations WHERE id = (v_res->>'reservation_id')::uuid)
    AND pg_temp.minutos((v_res->>'reservation_id')::uuid) = 795,
    v_res::text);

  -- ═══════════ [X] la quote no se modifico mas que su status ═══════════
  SELECT to_jsonb(q) INTO v_snap_quote2 FROM public.quotes q WHERE q.id = q3;
  PERFORM pg_temp.chk('[X] de la quote solo cambio status (a accepted); duration_hours intacta',
    (v_snap_quote - 'status' - 'updated_at') = (v_snap_quote2 - 'status' - 'updated_at')
    AND (v_snap_quote2->>'status') = 'accepted'
    AND (v_snap_quote2->>'duration_hours') = '3');

  -- ═══════════ [O5] Express intacto ═══════════
  PERFORM pg_temp.chk('[O5] instant_accept_request intacta (md5 a5dffe3d...)',
    (SELECT md5(prosrc) FROM pg_proc WHERE oid=to_regprocedure('public.instant_accept_request(uuid,numeric,numeric,text)'))
      = 'a5dffe3d273846f6efbfdef2df412c30');
  PERFORM pg_temp.chk('[O5] client_accept_proposal intacta (md5 362d4a3c...)',
    (SELECT md5(prosrc) FROM pg_proc WHERE oid=to_regprocedure('public.client_accept_proposal(uuid,uuid)'))
      = '362d4a3c884e2cd5e5a51128c5a7fc11');
  PERFORM pg_temp.chk('[O5] Express sigue tomando sus horas de event_requests.hours, no de quotes',
    (SELECT prosrc LIKE '%COALESCE(v_req.hours, 3)%'
       FROM pg_proc WHERE oid=to_regprocedure('public.instant_accept_request(uuid,numeric,numeric,text)')));
  PERFORM pg_temp.chk('[O5] 722 no toco ninguna funcion de Express ni de event_requests',
    (SELECT prosrc NOT LIKE '%event_requests%'
       FROM pg_proc WHERE oid=to_regprocedure('public.client_accept_quote(uuid,uuid,integer)')));

  -- ═══════════ [X] el segundo carril sigue roto (hallazgo abierto) ═══════════
  PERFORM pg_temp.chk('[X] HALLAZGO ABIERTO: create_booking_with_event sigue sin escribir hours_count',
    (SELECT prosrc NOT LIKE '%hours_count%' FROM pg_proc
      WHERE proname='create_booking_with_event' AND pronamespace='public'::regnamespace),
    'no se corrigio a proposito: no tiene ningun parametro de duracion que copiar');
  PERFORM pg_temp.chk('[X] y de hecho no tiene parametro de duracion',
    (SELECT pg_get_function_arguments(oid) NOT LIKE '%duration%' AND pg_get_function_arguments(oid) NOT LIKE '%hours%'
       FROM pg_proc WHERE proname='create_booking_with_event' AND pronamespace='public'::regnamespace));

  -- ═══════════ [O6] precio, comision, pago y payout sin cambios ═══════════
  PERFORM pg_temp.chk('[O6] la reserva de 10 h conserva el precio de la quote, sin recalcular por horas',
    (SELECT r.base_price = 10000 AND r.total_price = 12500 FROM public.reservations r WHERE r.id = r10),
    (SELECT 'base=' || r.base_price::text || ' total=' || r.total_price::text
       FROM public.reservations r WHERE r.id = r10));
  PERFORM pg_temp.chk('[O6] la de 3 h y la de 10 h tienen EXACTAMENTE el mismo precio: las horas no mueven dinero',
    (SELECT COUNT(DISTINCT total_price) FROM public.reservations WHERE id IN (r3, r10)) = 1);
  PERFORM pg_temp.chk('[O6] y la misma comision calculada por el trigger',
    (SELECT COUNT(DISTINCT COALESCE(platform_commission, -1)) FROM public.reservations WHERE id IN (r3, r10)) = 1,
    (SELECT COALESCE(string_agg(COALESCE(platform_commission::text,'NULL'), ' / '),'')
       FROM public.reservations WHERE id IN (r3, r10)));
  PERFORM pg_temp.chk('[O6] calculate_final_price intacta (md5 37e3c7bf...)',
    (SELECT md5(prosrc) FROM pg_proc WHERE oid=to_regprocedure('public.calculate_final_price(numeric,boolean,text,text,numeric,text)'))
      = '37e3c7bfc9844cc533f6340fed38e206');
  PERFORM pg_temp.chk('[O6] calculate_commission intacta (md5 aae27e71...)',
    (SELECT md5(prosrc) FROM pg_proc WHERE oid=to_regprocedure('public.calculate_commission()'))
      = 'aae27e71c8d0cb5489bb83bbac9ea703');
  PERFORM pg_temp.chk('[O6] admin_respond_quote intacta (md5 3dc60f49...)',
    (SELECT md5(prosrc) FROM pg_proc WHERE oid=to_regprocedure('public.admin_respond_quote(uuid,numeric,numeric,numeric,numeric,numeric,text)'))
      = '3dc60f49c53d45bff19c2c4f4ea44127');
  PERFORM pg_temp.chk('[O6] confirm_reservation_payment_v2 intacta (md5 c32015cf...)',
    (SELECT md5(prosrc) FROM pg_proc WHERE oid=to_regprocedure('public.confirm_reservation_payment_v2(text,text,text,uuid,bigint,text,text,bigint,text,jsonb)'))
      = 'c32015cff0ec4d87db6326eed906f74b');
  SELECT (SELECT COUNT(*) FROM public.wallet_transactions)::text || '/' ||
         (SELECT COALESCE(SUM(amount),0)::text FROM public.wallet_transactions) || '/' ||
         (SELECT COUNT(*) FROM public.payment_receipts)::text || '/' ||
         (SELECT COALESCE(SUM(total_price),0)::text FROM public.reservations)
    INTO v_huella_dinero2;
  PERFORM pg_temp.chk('[O6] wallets y recibos sin un solo movimiento nuevo (solo subio el total por las reservas sinteticas)',
    split_part(v_huella_dinero,'/',1) = split_part(v_huella_dinero2,'/',1)
    AND split_part(v_huella_dinero,'/',2) = split_part(v_huella_dinero2,'/',2)
    AND split_part(v_huella_dinero,'/',3) = split_part(v_huella_dinero2,'/',3),
    v_huella_dinero || '  ->  ' || v_huella_dinero2);
  -- payout_status nace en 'held' por default: nada se libero.
  PERFORM pg_temp.chk('[O6] ningun payout se libero: las dos reservas siguen en held',
    (SELECT COUNT(*) FROM public.reservations WHERE id IN (r3, r10) AND payout_status = 'held') = 2,
    (SELECT COALESCE(string_agg(COALESCE(payout_status,'NULL'), ' / '),'')
       FROM public.reservations WHERE id IN (r3, r10)));

  -- ═══════════ [O7] extra_hours intacto ═══════════
  SELECT (SELECT COUNT(*) FROM public.extra_hours)::text || '/' ||
         (SELECT COALESCE(SUM(total_extra_cost),0)::text FROM public.extra_hours) || '/' ||
         (SELECT COALESCE(SUM(hours_added),0)::text FROM public.extra_hours)
    INTO v_huella_extra2;
  PERFORM pg_temp.chk('[O7] extra_hours: filas, costo y horas sin cambios',
    v_huella_extra = v_huella_extra2, v_huella_extra || ' -> ' || v_huella_extra2);
  PERFORM pg_temp.chk('[O7] client_accept_quote no menciona extra_hours',
    (SELECT prosrc NOT ILIKE '%extra_hours%'
       FROM pg_proc WHERE oid=to_regprocedure('public.client_accept_quote(uuid,uuid,integer)')));
  PERFORM pg_temp.chk('[O7] las reservas nuevas nacen con 0 horas extra',
    (SELECT COUNT(*) FROM public.extra_hours WHERE reservation_id IN (r3, r10)) = 0);
  -- La unica funcion que usaba hours_count para un PRECIO esta muerta.
  PERFORM pg_temp.chk('[X] request_overtime (la unica que usaba hours_count para precio) sigue muerta: packages no existe',
    to_regclass('public.packages') IS NULL
    AND (SELECT prosrc LIKE '%public.packages%' FROM pg_proc WHERE oid=to_regprocedure('public.request_overtime(uuid,numeric,numeric)')));

  -- ═══════════ [P*] price_from ═══════════
  PERFORM pg_temp.actuar_como(u_owner);
  v_res := public.set_group_commercial_catalog(g_main, 3, 4, 900, NULL, 15000);
  PERFORM pg_temp.chk('[P1] el dueno publica su precio "desde"', (v_res->>'ok')::boolean, v_res::text);
  PERFORM pg_temp.chk('[P1] y queda guardado en groups.price_from',
    (SELECT price_from = 15000 FROM public.groups WHERE id = g_main));
  v_res := public.set_group_commercial_catalog(g_main, 3, NULL, NULL, NULL, 15000);
  PERFORM pg_temp.chk('[P2] un "desde" sin horas incluidas avisa (no bloquea)',
    (v_res->>'ok')::boolean AND (v_res->'avisos') ? 'price_without_included_hours', v_res::text);
  v_res := public.set_group_commercial_catalog(g_main, NULL, NULL, NULL, NULL, -1);
  PERFORM pg_temp.chk('[P3] price_from negativo rechazado', (v_res->>'error') = 'invalid_price_from', v_res::text);
  v_res := public.set_group_commercial_catalog(g_main, NULL, NULL, NULL, NULL, 99999999);
  PERFORM pg_temp.chk('[P3] price_from absurdo rechazado', (v_res->>'error') = 'invalid_price_from', v_res::text);
  BEGIN
    UPDATE public.groups SET price_from = -5 WHERE id = g_main;
    v_n := 0;
  EXCEPTION WHEN check_violation THEN v_n := 1;
  END;
  PERFORM pg_temp.chk('[P3] el CHECK bloquea price_from negativo por UPDATE directo', v_n = 1);
  v_res := public.set_group_commercial_catalog(g_main, NULL, NULL, NULL, NULL, NULL);
  PERFORM pg_temp.chk('[P4] se puede dejar sin precio publicado (NULL = "A cotizar")',
    (v_res->>'ok')::boolean AND (SELECT price_from IS NULL FROM public.groups WHERE id = g_main));
  PERFORM pg_temp.actuar_como(u_cli);
  v_res := public.set_group_commercial_catalog(g_main, NULL, NULL, NULL, NULL, 1);
  PERFORM pg_temp.chk('[P5] un ajeno no puede publicar precio de otro proveedor',
    (v_res->>'error') = 'not_allowed', v_res::text);
  PERFORM pg_temp.chk('[P6] price_from NO entra en el precio de la reserva ya creada',
    (SELECT total_price = 12500 FROM public.reservations WHERE id = r10));
  PERFORM pg_temp.chk('[P6] la RPC del catalogo no menciona quotes, comision ni pagos',
    (SELECT prosrc !~* '(quotes|commission|payment|stripe|conekta|wallet|reservation)'
       FROM pg_proc WHERE oid=to_regprocedure('public.set_group_commercial_catalog(uuid,numeric,numeric,numeric,integer,numeric)')));
  PERFORM pg_temp.chk('[P7] no se invento price_from para los grupos historicos: sigue habiendo 1 real',
    (SELECT COUNT(*) FROM public.groups WHERE price_from IS NOT NULL AND id <> g_main) = 1,
    'grupos reales con precio: ' || (SELECT COUNT(*)::text FROM public.groups WHERE price_from IS NOT NULL AND id <> g_main));

  -- El registro tambien lo captura.
  PERFORM pg_temp.actuar_como(u_cli);
  v_res := public.submit_provider_application(
    'Proveedor 723', '6189990011', 'renta', 4, NULL, 'México', 'Durango', 'Durango',
    NULL, NULL, NULL, NULL, 2500);
  PERFORM pg_temp.chk('[P8] el registro acepta price_from (y renta por fin trae dato comercial)',
    (v_res->>'ok')::boolean, v_res::text);
  PERFORM pg_temp.chk('[P8] la solicitud lo guarda',
    (SELECT price_from = 2500 FROM public.provider_applications
      WHERE id = (v_res->>'application_id')::uuid));
  PERFORM pg_temp.actuar_como(u_admin);
  v_res := public.admin_approve_provider_application(
    (SELECT id FROM public.provider_applications WHERE full_name = 'Proveedor 723'),
    'p723_' || substr(gen_random_uuid()::text,1,8) || '@daricefy.test', 'Renta de mesas', 'Clave723');
  PERFORM pg_temp.chk('[P9] al aprobar, el grupo nace con su precio "desde"',
    (SELECT price_from = 2500 FROM public.groups WHERE id = (v_res->>'group_id')::uuid),
    v_res::text);

  -- ═══════════ REPORTE ═══════════
  DECLARE
    v_rep  TEXT := E'\n';
    v_pass INT;
    v_fail INT;
  BEGIN
    FOR v_row IN SELECT nombre, ok, detalle FROM _r ORDER BY i LOOP
      v_rep := v_rep || CASE WHEN v_row.ok THEN '  [OK]   ' ELSE '  [FAIL] ' END || v_row.nombre ||
               CASE WHEN COALESCE(v_row.detalle,'') = '' THEN '' ELSE E'\n            ' || v_row.detalle END || E'\n';
    END LOOP;
    SELECT COUNT(*) FILTER (WHERE ok), COUNT(*) FILTER (WHERE NOT ok) INTO v_pass, v_fail FROM _r;
    RAISE EXCEPTION E'TEST_REPORT sql/723 — duracion de la quote + price_from%\n  PASS=% FAIL=%\n  TODO REVERTIDO.',
      v_rep, v_pass, v_fail;
  END;
END
$suite$;

ROLLBACK;
