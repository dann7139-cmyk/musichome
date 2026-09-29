-- ═══════════════════════════════════════════════════════════════════════════
-- 719 — SUITE AUTORREVERTIBLE de sql/718 (recordatorios de cotizaciones)
-- ═══════════════════════════════════════════════════════════════════════════
-- Se ejecuta DESPUÉS de aplicar sql/718. No deja nada: todo pasa dentro de una
-- transacción que termina en ROLLBACK por la excepción final, que es también el
-- reporte. Datos 100% sintéticos (usuarios, grupos y quotes creados aquí).
--
-- Cubre las 11 pruebas obligatorias de la autorización, etiquetadas [O1]…[O11],
-- más controles extra etiquetados [X].
--
--   [O1]  no enviar antes de 12 h
--   [O2]  enviar 12 h una sola vez
--   [O3]  enviar 36 h una sola vez
--   [O4]  no recordar una quote que dejó de estar pending
--   [O5]  no recordar un evento pasado
--   [O6]  respetar horario silencioso
--   [O7]  cambio de concierge_mode entre 12 h y 36 h
--   [O8]  dos ejecuciones repetidas no duplican avisos
--   [O9]  varias quotes del mismo proveedor → un push agrupado, marcas individuales
--   [O10] expire_stale_quotes continúa comportándose igual
--   [O11] ninguna modificación a pagos/cotizaciones finales
--
-- NOTA SOBRE EL TIEMPO: dentro de una transacción `NOW()` es constante, así que
-- "que pasen 24 h" se simula moviendo `created_at` hacia atrás. Es exactamente lo
-- que ve la función.
-- ═══════════════════════════════════════════════════════════════════════════

BEGIN;

CREATE TEMP TABLE _r (i serial, nombre text, ok boolean, detalle text) ON COMMIT DROP;

CREATE OR REPLACE FUNCTION pg_temp.chk(n text, cond boolean, d text DEFAULT '')
RETURNS void LANGUAGE sql AS $$
  INSERT INTO _r (nombre, ok, detalle) VALUES (n, COALESCE(cond, false), d);
$$;

-- Crea una quote sintetica. `event_estado` a proposito NO existe en `states`, asi
-- guard_cross_border_quote devuelve NEW sin tocar el status y la prueba mide solo
-- lo que agrega 718.
CREATE OR REPLACE FUNCTION pg_temp.mkq(p_group uuid, p_client uuid, p_date date,
                                       p_created timestamptz, p_status text)
RETURNS uuid LANGUAGE plpgsql AS $$
DECLARE v_id uuid;
BEGIN
  INSERT INTO public.quotes (
    group_id, client_id, event_type, event_address, event_municipio, event_estado,
    event_date, event_time, duration_hours, venue_covered, venue_size, needs_sound,
    status, num_personas, created_at)
  VALUES (
    p_group, p_client, 'fiesta_privada', 'Domicilio Sintetico 1', 'Municipio Sintetico',
    'Zona Test Daricefy', p_date, '19:00', 4, 'si', 'salon_mediano', 'no',
    p_status, 100, p_created)
  RETURNING id INTO v_id;
  -- Por si algun trigger pisara created_at: se reafirma el valor sintetico.
  UPDATE public.quotes SET created_at = p_created WHERE id = v_id;
  RETURN v_id;
END $$;

DO $suite$
DECLARE
  -- actores sintéticos
  u_owner   UUID := gen_random_uuid();
  u_member  UUID := gen_random_uuid();
  u_admin   UUID := gen_random_uuid();
  u_cli1    UUID := gen_random_uuid();
  u_cli2    UUID := gen_random_uuid();
  u_cli3    UUID := gen_random_uuid();
  g_normal  UUID := gen_random_uuid();   -- concierge_mode = false
  g_conc    UUID := gen_random_uuid();   -- concierge_mode = true
  g_tz      UUID := gen_random_uuid();   -- para el horario silencioso
  g_multi   UUID := gen_random_uuid();   -- 3 quotes a la vez
  q_11h     UUID;
  q_13h     UUID;
  q_37h     UUID;
  q_quoted  UUID;
  q_pasado  UUID;
  q_viejo   UUID;
  q_toggle  UUID;
  q_tz      UUID;
  q_m1      UUID; q_m2 UUID; q_m3 UUID;
  q_conc    UUID;

  v_res     JSONB;
  v_n       INT;
  v_tz_out  TEXT;   -- estado cuya hora local está FUERA de 8–20 ahora mismo
  v_tz_in   TEXT;   -- estado cuya hora local está DENTRO de 8–20 ahora mismo
  v_pais_out TEXT;
  v_snap    JSONB;
  v_snap2   JSONB;
  v_money   TEXT;
  v_money2  TEXT;
  v_md5_exp TEXT;
  v_hoy     DATE := (NOW() AT TIME ZONE 'America/Mexico_City')::date;
  r         RECORD;
BEGIN
  -- ═══════════════ 0. PRECONDICIONES ═══════════════
  PERFORM pg_temp.chk('[X] sql/718 aplicado: existe notify_pending_quotes()',
    to_regprocedure('public.notify_pending_quotes()') IS NOT NULL);
  PERFORM pg_temp.chk('[X] existen las 3 columnas de recordatorio',
    (SELECT COUNT(*) FROM pg_attribute WHERE attrelid='public.quotes'::regclass
       AND attname IN ('reminder_12h_at','reminder_36h_at','escalated_48h_at')
       AND NOT attisdropped) = 3);
  PERFORM pg_temp.chk('[X] el cron notify-pending-quotes esta activo',
    EXISTS (SELECT 1 FROM cron.job WHERE jobname='notify-pending-quotes' AND active),
    COALESCE((SELECT schedule FROM cron.job WHERE jobname='notify-pending-quotes'),'sin cron'));
  -- El 5566778899 se MENCIONA en un comentario del codigo ("no es el de..."), asi
  -- que lo que se mide es la LLAMADA, no el texto.
  PERFORM pg_temp.chk('[X] usa un advisory lock DISTINTO al de expire_stale_quotes',
    (SELECT prosrc LIKE '%pg_try_advisory_xact_lock(8812345678)%'
        AND prosrc NOT LIKE '%pg_try_advisory_xact_lock(5566778899)%'
       FROM pg_proc WHERE oid=to_regprocedure('public.notify_pending_quotes()')));
  PERFORM pg_temp.chk('[X] anon NO puede ejecutarla',
    NOT has_function_privilege('anon','public.notify_pending_quotes()','EXECUTE'));
  PERFORM pg_temp.chk('[X] authenticated NO puede ejecutarla',
    NOT has_function_privilege('authenticated','public.notify_pending_quotes()','EXECUTE'));
  PERFORM pg_temp.chk('[X] service_role SI puede ejecutarla',
    has_function_privilege('service_role','public.notify_pending_quotes()','EXECUTE'));
  PERFORM pg_temp.chk('[X] el CHECK de notifications.type NO se modifico (admite new_quote_request)',
    EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid='public.notifications'::regclass
            AND contype='c' AND pg_get_constraintdef(oid) LIKE '%new_quote_request%'));
  -- La columna se menciona en un comentario del codigo; lo que NO debe existir es
  -- una asignacion.
  PERFORM pg_temp.chk('[X] NADIE escribe escalated_48h_at todavia',
    (SELECT prosrc NOT LIKE '%escalated_48h_at =%' AND prosrc NOT LIKE '%escalated_48h_at=%'
       FROM pg_proc WHERE oid=to_regprocedure('public.notify_pending_quotes()')));

  -- ═══════════════ 1. ACTORES ═══════════════
  INSERT INTO auth.users (id) VALUES (u_owner),(u_member),(u_admin),(u_cli1),(u_cli2),(u_cli3);
  -- auth.users tiene el trigger on_auth_user_created -> handle_new_user, que ya
  -- crea el profile. Por eso ON CONFLICT: aqui solo se le fija el rol.
  INSERT INTO public.profiles (id, full_name, role) VALUES
    (u_owner,  'Dueno Sintetico', 'group'),
    (u_member, 'Miembro Sintetico', 'group'),
    (u_admin,  'Admin Sintetico', 'admin'),
    (u_cli1,   'Cliente Uno', 'client'),
    (u_cli2,   'Cliente Dos', 'client'),
    (u_cli3,   'Cliente Tres', 'client')
  ON CONFLICT (id) DO UPDATE SET full_name = EXCLUDED.full_name, role = EXCLUDED.role;

  -- Qué zonas están dentro y fuera de la ventana AHORA MISMO. No se inventa la
  -- hora: se pregunta al servidor y se elige el estado correspondiente.
  SELECT z.estado, z.pais INTO v_tz_out, v_pais_out
  FROM (VALUES
      ('Newfoundland and Labrador','Canadá'), ('Ontario','Canadá'),
      ('Durango','México'), ('Baja California','México'), ('Hawaii','Estados Unidos'))
    AS z(estado, pais)
  WHERE EXTRACT(HOUR FROM NOW() AT TIME ZONE public.tz_for_event(z.estado, z.pais)) NOT BETWEEN 8 AND 20
  LIMIT 1;

  SELECT z.estado INTO v_tz_in
  FROM (VALUES
      ('Durango','México'), ('Baja California','México'), ('Hawaii','Estados Unidos'),
      ('Ontario','Canadá'), ('Newfoundland and Labrador','Canadá'))
    AS z(estado, pais)
  WHERE EXTRACT(HOUR FROM NOW() AT TIME ZONE public.tz_for_event(z.estado, z.pais)) BETWEEN 8 AND 20
  LIMIT 1;

  IF v_tz_in IS NULL THEN
    -- Sin ninguna zona dentro de la ventana no se puede probar NADA de envío.
    RAISE EXCEPTION 'SUITE NO EJECUTABLE: en este momento (% UTC) ninguna de las zonas candidatas esta entre 8 y 21 h local. Corre la suite dentro del horario habil de alguna zona.', NOW();
  END IF;

  -- Grupos. `state` es lo que decide la zona horaria del destinatario.
  INSERT INTO public.groups (id, name, owner_id, state, country, concierge_mode, genre)
  VALUES
    (g_normal, 'Grupo Normal Sintetico', u_owner,  v_tz_in, 'México', false, 'Mariachi'),
    (g_conc,   'Grupo Conserjeria Sint', u_owner,  v_tz_in, 'México', true,  'Banda'),
    (g_multi,  'Grupo Multi Sintetico',  u_owner,  v_tz_in, 'México', false, 'Norteno'),
    (g_tz,     'Grupo Zona Sintetico',   u_owner,  COALESCE(v_tz_out, v_tz_in), COALESCE(v_pais_out,'México'), false, 'Trio');

  -- Un miembro aceptado del grupo normal (patron de notify_quote_request).
  INSERT INTO public.job_invitations (group_id, invited_user_id, invitation_type, status)
  VALUES (g_normal, u_member, 'membership', 'accepted');

  -- ═══════════════ 2. QUOTES SINTETICAS ═══════════════
  -- `event_estado` a proposito NO existe en `states`: asi guard_cross_border_quote
  -- devuelve NEW sin tocar el status y la prueba mide solo lo nuestro.
  q_11h := pg_temp.mkq(g_normal, u_cli1, v_hoy + 30, NOW() - INTERVAL '11 hours', 'pending');
  q_13h := pg_temp.mkq(g_normal, u_cli2, v_hoy + 30, NOW() - INTERVAL '13 hours', 'pending');
  q_quoted := pg_temp.mkq(g_normal, u_cli3, v_hoy + 30, NOW() - INTERVAL '13 hours', 'quoted');
  q_pasado := pg_temp.mkq(g_conc,   u_cli1, v_hoy - 1,  NOW() - INTERVAL '13 hours', 'pending');
  q_viejo  := pg_temp.mkq(g_conc,   u_cli2, v_hoy + 30, NOW() - INTERVAL '4 days',   'pending');
  q_conc   := pg_temp.mkq(g_conc,   u_cli3, v_hoy + 30, NOW() - INTERVAL '13 hours', 'pending');
  q_tz     := pg_temp.mkq(g_tz,     u_cli1, v_hoy + 30, NOW() - INTERVAL '13 hours', 'pending');
  q_m1     := pg_temp.mkq(g_multi,  u_cli1, v_hoy + 30, NOW() - INTERVAL '13 hours', 'pending');
  q_m2     := pg_temp.mkq(g_multi,  u_cli2, v_hoy + 30, NOW() - INTERVAL '14 hours', 'pending');
  q_m3     := pg_temp.mkq(g_multi,  u_cli3, v_hoy + 30, NOW() - INTERVAL '20 hours', 'pending');

  -- Huella financiera y fotografía de una quote ANTES de correr nada.
  SELECT (SELECT COUNT(*) FROM public.reservations)::text || '/' ||
         (SELECT COUNT(*) FROM public.wallet_transactions)::text || '/' ||
         (SELECT COUNT(*) FROM public.payment_receipts)::text || '/' ||
         (SELECT COALESCE(SUM(amount),0)::text FROM public.wallet_transactions)
    INTO v_money;
  SELECT to_jsonb(q) - 'reminder_12h_at' - 'reminder_36h_at' - 'escalated_48h_at'
    INTO v_snap FROM public.quotes q WHERE q.id = q_13h;
  SELECT md5(prosrc) INTO v_md5_exp FROM pg_proc WHERE oid=to_regprocedure('public.expire_stale_quotes()');

  -- ═══════════════ 3. PRIMERA CORRIDA ═══════════════
  v_res := public.notify_pending_quotes();
  PERFORM pg_temp.chk('[X] la primera corrida devuelve ok', (v_res->>'ok')::boolean, v_res::text);

  -- [O1] no enviar antes de 12 h
  PERFORM pg_temp.chk('[O1] quote de 11 h: NO se marca',
    (SELECT reminder_12h_at IS NULL AND reminder_36h_at IS NULL FROM public.quotes WHERE id=q_11h));
  PERFORM pg_temp.chk('[O1] quote de 11 h: NO genera notificacion',
    NOT EXISTS (SELECT 1 FROM public.notifications
                WHERE data->>'reminder_stage' IS NOT NULL
                  AND (data->>'quote_id' = q_11h::text OR data->'quote_ids' ? q_11h::text)));

  -- [O2] enviar 12 h una sola vez
  PERFORM pg_temp.chk('[O2] quote de 13 h: se marca reminder_12h_at',
    (SELECT reminder_12h_at IS NOT NULL AND reminder_36h_at IS NULL FROM public.quotes WHERE id=q_13h));
  SELECT COUNT(*) INTO v_n FROM public.notifications
   WHERE user_id = u_owner AND data->>'reminder_stage' = '12h' AND data->>'group_id' = g_normal::text;
  PERFORM pg_temp.chk('[O2] el dueno recibe EXACTAMENTE 1 aviso de 12 h', v_n = 1, 'avisos=' || v_n);
  SELECT COUNT(*) INTO v_n FROM public.notifications
   WHERE user_id = u_member AND data->>'reminder_stage' = '12h' AND data->>'group_id' = g_normal::text;
  PERFORM pg_temp.chk('[X] el miembro aceptado tambien recibe 1 aviso (patron notify_quote_request)',
    v_n = 1, 'avisos=' || v_n);
  PERFORM pg_temp.chk('[X] el aviso reutiliza type=new_quote_request',
    EXISTS (SELECT 1 FROM public.notifications WHERE user_id=u_owner
            AND data->>'reminder_stage'='12h' AND type='new_quote_request'));
  PERFORM pg_temp.chk('[X] aviso de 1 sola quote: trae quote_id para abrirla directo',
    (SELECT data->>'quote_id' = q_13h::text FROM public.notifications
      WHERE user_id=u_owner AND data->>'reminder_stage'='12h' AND data->>'group_id'=g_normal::text));

  -- [O4] no recordar una quote que dejó de estar pending
  PERFORM pg_temp.chk('[O4] quote status=quoted: NO se marca',
    (SELECT reminder_12h_at IS NULL FROM public.quotes WHERE id=q_quoted));

  -- [O5] no recordar un evento pasado
  PERFORM pg_temp.chk('[O5] evento de ayer: NO se marca',
    (SELECT reminder_12h_at IS NULL AND reminder_36h_at IS NULL FROM public.quotes WHERE id=q_pasado));

  -- [X] una quote ya vencida (4 dias) es de expire_stale_quotes, no nuestra
  PERFORM pg_temp.chk('[X] quote de 4 dias: NO se le insiste (le toca expirar)',
    (SELECT reminder_12h_at IS NULL AND reminder_36h_at IS NULL FROM public.quotes WHERE id=q_viejo));

  -- [X] conserjeria: el aviso va al Admin, NO al dueno del grupo
  PERFORM pg_temp.chk('[X] conserjeria: el admin recibe el aviso',
    EXISTS (SELECT 1 FROM public.notifications WHERE user_id=u_admin
            AND data->>'reminder_stage'='12h' AND data->>'group_id'=g_conc::text));
  PERFORM pg_temp.chk('[X] conserjeria: el dueno NO recibe aviso de ese grupo',
    NOT EXISTS (SELECT 1 FROM public.notifications WHERE user_id=u_owner
                AND data->>'group_id'=g_conc::text));
  PERFORM pg_temp.chk('[X] conserjeria: el aviso lleva screen=AdminManagedQuotes',
    (SELECT data->>'screen' = 'AdminManagedQuotes' FROM public.notifications
      WHERE user_id=u_admin AND data->>'reminder_stage'='12h' AND data->>'group_id'=g_conc::text));

  -- [O9] varias quotes del mismo proveedor
  SELECT COUNT(*) INTO v_n FROM public.notifications
   WHERE user_id=u_owner AND data->>'reminder_stage'='12h' AND data->>'group_id'=g_multi::text;
  PERFORM pg_temp.chk('[O9] 3 quotes del mismo grupo -> UN solo push al dueno', v_n = 1, 'pushes=' || v_n);
  PERFORM pg_temp.chk('[O9] las 3 quotes quedan marcadas individualmente',
    (SELECT COUNT(*) FROM public.quotes WHERE id IN (q_m1,q_m2,q_m3) AND reminder_12h_at IS NOT NULL) = 3);
  PERFORM pg_temp.chk('[O9] el push agrupado lista las 3 en quote_ids',
    (SELECT jsonb_array_length(data->'quote_ids') = 3 FROM public.notifications
      WHERE user_id=u_owner AND data->>'reminder_stage'='12h' AND data->>'group_id'=g_multi::text));
  PERFORM pg_temp.chk('[O9] el push agrupado NO trae quote_id (abre el carrusel completo)',
    (SELECT NOT (data ? 'quote_id') FROM public.notifications
      WHERE user_id=u_owner AND data->>'reminder_stage'='12h' AND data->>'group_id'=g_multi::text));
  PERFORM pg_temp.chk('[O9] el texto agrupado dice cuantas son',
    (SELECT body LIKE '%3 solicitudes%' FROM public.notifications
      WHERE user_id=u_owner AND data->>'reminder_stage'='12h' AND data->>'group_id'=g_multi::text));

  -- [O6] horario silencioso
  IF v_tz_out IS NULL THEN
    PERFORM pg_temp.chk('[O6] horario silencioso NO EVALUABLE ahora (todas las zonas candidatas estan en ventana)',
      false, 'SKIP — no es un fallo del codigo: reejecutar en otra hora');
  ELSE
    PERFORM pg_temp.chk('[O6] fuera de 8-21 local (' || v_tz_out || '): NO se marca ni se avisa',
      (SELECT reminder_12h_at IS NULL FROM public.quotes WHERE id=q_tz)
      AND NOT EXISTS (SELECT 1 FROM public.notifications WHERE data->>'group_id'=g_tz::text),
      'hora local=' || EXTRACT(HOUR FROM NOW() AT TIME ZONE public.tz_for_event(v_tz_out, v_pais_out))::text);
    PERFORM pg_temp.chk('[O6] la funcion lo reporta como omitido_por_horario',
      (v_res->>'omitidos_por_horario')::int >= 1, v_res::text);
    -- Y queda PENDIENTE: al mover el grupo a una zona en ventana, sale.
    UPDATE public.groups SET state = v_tz_in, country = 'México' WHERE id = g_tz;
    PERFORM public.notify_pending_quotes();
    PERFORM pg_temp.chk('[O6] al abrir la ventana SI sale (quedo pendiente, no perdido)',
      (SELECT reminder_12h_at IS NOT NULL FROM public.quotes WHERE id=q_tz));
  END IF;

  -- [O8] dos ejecuciones repetidas no duplican
  PERFORM public.notify_pending_quotes();
  PERFORM public.notify_pending_quotes();
  SELECT COUNT(*) INTO v_n FROM public.notifications
   WHERE user_id=u_owner AND data->>'reminder_stage'='12h' AND data->>'group_id'=g_normal::text;
  PERFORM pg_temp.chk('[O8] tras 3 corridas sigue habiendo 1 solo aviso de 12 h', v_n = 1, 'avisos=' || v_n);
  SELECT COUNT(*) INTO v_n FROM public.notifications
   WHERE data->>'reminder_stage'='12h' AND data->>'group_id'=g_multi::text;
  PERFORM pg_temp.chk('[O8] el push agrupado tampoco se duplica', v_n = 1, 'avisos=' || v_n);

  -- ═══════════════ 4. AVANZA EL RELOJ A 37 h ═══════════════
  -- [O3] y [O7]: la misma quote cruza a 36 h mientras el grupo cambia a conserjeria.
  q_toggle := q_13h;
  UPDATE public.quotes SET created_at = NOW() - INTERVAL '37 hours' WHERE id = q_toggle;
  UPDATE public.groups SET concierge_mode = true WHERE id = g_normal;

  PERFORM public.notify_pending_quotes();

  PERFORM pg_temp.chk('[O3] a las 37 h se marca reminder_36h_at',
    (SELECT reminder_36h_at IS NOT NULL FROM public.quotes WHERE id=q_toggle));
  -- En conserjeria el aviso va a CADA admin que cubre el pais (aqui el sintetico y
  -- los reales), asi que "una sola vez" se mide POR DESTINATARIO.
  SELECT COUNT(*) INTO v_n FROM public.notifications
   WHERE user_id = u_admin AND data->>'reminder_stage'='36h'
     AND (data->>'quote_id'=q_toggle::text OR data->'quote_ids' ? q_toggle::text);
  PERFORM pg_temp.chk('[O3] el aviso de 36 h sale UNA sola vez por destinatario', v_n = 1, 'avisos=' || v_n);
  PERFORM pg_temp.chk('[O3] ningun destinatario recibe el de 36 h dos veces',
    NOT EXISTS (SELECT 1 FROM public.notifications
                WHERE data->>'reminder_stage'='36h'
                  AND (data->>'quote_id'=q_toggle::text OR data->'quote_ids' ? q_toggle::text)
                GROUP BY user_id HAVING COUNT(*) > 1));
  PERFORM public.notify_pending_quotes();
  SELECT COUNT(*) INTO v_n FROM public.notifications
   WHERE user_id = u_admin AND data->>'reminder_stage'='36h'
     AND (data->>'quote_id'=q_toggle::text OR data->'quote_ids' ? q_toggle::text);
  PERFORM pg_temp.chk('[O3] y sigue siendo UNA tras repetir la corrida', v_n = 1, 'avisos=' || v_n);

  -- [O7] el destinatario se resolvio AL ENVIAR: el de 36 h fue al admin
  PERFORM pg_temp.chk('[O7] el aviso de 36 h fue al ADMIN (concierge_mode cambio en medio)',
    EXISTS (SELECT 1 FROM public.notifications WHERE user_id=u_admin
            AND data->>'reminder_stage'='36h' AND data->>'group_id'=g_normal::text));
  PERFORM pg_temp.chk('[O7] el dueno NO recibio el de 36 h (ya no maneja su cuenta)',
    NOT EXISTS (SELECT 1 FROM public.notifications WHERE user_id=u_owner
                AND data->>'reminder_stage'='36h' AND data->>'group_id'=g_normal::text));
  PERFORM pg_temp.chk('[O7] pero el de 12 h SI se lo habia quedado el dueno',
    EXISTS (SELECT 1 FROM public.notifications WHERE user_id=u_owner
            AND data->>'reminder_stage'='12h' AND data->>'group_id'=g_normal::text));

  -- [X] salto de 12 h: una quote que nace vieja sella ambas columnas y manda 1 aviso
  q_37h := pg_temp.mkq(g_multi, u_cli1, v_hoy + 30, NOW() - INTERVAL '40 hours', 'pending');
  PERFORM public.notify_pending_quotes();
  PERFORM pg_temp.chk('[X] quote que nace con 40 h: sella las DOS columnas',
    (SELECT reminder_12h_at IS NOT NULL AND reminder_36h_at IS NOT NULL
       FROM public.quotes WHERE id=q_37h));
  SELECT COUNT(*) INTO v_n FROM public.notifications
   WHERE data->>'quote_id'=q_37h::text OR data->'quote_ids' ? q_37h::text;
  PERFORM pg_temp.chk('[X] y manda UN solo aviso, no dos seguidos', v_n = 1, 'avisos=' || v_n);

  -- [X] escalated_48h_at sigue intacta en TODAS las quotes sinteticas
  PERFORM pg_temp.chk('[X] escalated_48h_at sigue NULL en todo (48 h no implementada)',
    NOT EXISTS (SELECT 1 FROM public.quotes WHERE escalated_48h_at IS NOT NULL));

  -- ═══════════════ 5. [O10] expire_stale_quotes INTACTA ═══════════════
  PERFORM pg_temp.chk('[O10] expire_stale_quotes no fue modificada (md5)',
    (SELECT md5(prosrc) FROM pg_proc WHERE oid=to_regprocedure('public.expire_stale_quotes()'))
      = '3c47a4175f7baf0b598c400664b13a36');
  PERFORM pg_temp.chk('[O10] su cron sigue activo y en el minuto 0',
    EXISTS (SELECT 1 FROM cron.job WHERE jobname='expire-stale-quotes' AND active AND schedule='0 * * * *'));
  PERFORM pg_temp.chk('[O10] los dos crons no comparten advisory lock',
    (SELECT prosrc LIKE '%5566778899%' FROM pg_proc WHERE oid=to_regprocedure('public.expire_stale_quotes()'))
    AND (SELECT prosrc LIKE '%8812345678%' FROM pg_proc WHERE oid=to_regprocedure('public.notify_pending_quotes()')));
  -- y sigue expirando exactamente lo mismo: la de 4 dias y la de fecha pasada
  v_res := public.expire_stale_quotes();
  PERFORM pg_temp.chk('[O10] expire_stale_quotes sigue corriendo ok', (v_res->>'ok')::boolean, v_res::text);
  PERFORM pg_temp.chk('[O10] sigue expirando la quote de 4 dias',
    (SELECT status='expired' FROM public.quotes WHERE id=q_viejo));
  PERFORM pg_temp.chk('[O10] sigue expirando la de fecha pasada',
    (SELECT status='expired' FROM public.quotes WHERE id=q_pasado));
  PERFORM pg_temp.chk('[O10] NO expira la que solo recibio recordatorios',
    (SELECT status='pending' FROM public.quotes WHERE id=q_13h)
    AND (SELECT status='pending' FROM public.quotes WHERE id=q_11h));

  -- ═══════════════ 6. [O11] NADA DE DINERO SE MOVIO ═══════════════
  SELECT (SELECT COUNT(*) FROM public.reservations)::text || '/' ||
         (SELECT COUNT(*) FROM public.wallet_transactions)::text || '/' ||
         (SELECT COUNT(*) FROM public.payment_receipts)::text || '/' ||
         (SELECT COALESCE(SUM(amount),0)::text FROM public.wallet_transactions)
    INTO v_money2;
  PERFORM pg_temp.chk('[O11] reservations/wallet_transactions/payment_receipts/suma: sin cambios',
    v_money = v_money2, v_money || '  ->  ' || v_money2);

  SELECT to_jsonb(q) - 'reminder_12h_at' - 'reminder_36h_at' - 'escalated_48h_at'
    INTO v_snap2 FROM public.quotes q WHERE q.id = q_13h;
  -- created_at se movio a mano en la prueba [O3]; se excluye de la comparacion.
  PERFORM pg_temp.chk('[O11] de la quote solo cambiaron las columnas de recordatorio',
    (v_snap - 'created_at' - 'updated_at') = (v_snap2 - 'created_at' - 'updated_at'),
    -- Detalle compacto: solo las claves que cambiaron (deberia ser ninguna).
    COALESCE((SELECT string_agg(k, ', ') FROM (
      SELECT key AS k FROM jsonb_each(v_snap - 'created_at' - 'updated_at') a
      WHERE a.value IS DISTINCT FROM (v_snap2 - 'created_at' - 'updated_at') -> a.key
    ) d), 'ninguna clave cambio'));

  PERFORM pg_temp.chk('[O11] la funcion no menciona precios ni comisiones ni pagos',
    (SELECT prosrc !~* '(base_price|final_price|total_amount|commission|comision|wallet|payment|stripe|conekta|reservation)'
       FROM pg_proc WHERE oid=to_regprocedure('public.notify_pending_quotes()')));
  PERFORM pg_temp.chk('[O11] lo unico que escribe en quotes son las 2 columnas de recordatorio',
    (SELECT (regexp_count(prosrc, 'UPDATE public\.quotes') = 2)
        AND (regexp_count(prosrc, 'SET reminder_36h_at') = 1)
        AND (regexp_count(prosrc, 'SET reminder_12h_at') = 1)
        AND (prosrc NOT LIKE '%SET status%')
       FROM pg_proc WHERE oid=to_regprocedure('public.notify_pending_quotes()')));
  -- notify_quote_request se NOMBRA en un comentario ("mismo conjunto que..."); lo
  -- que no debe existir es una llamada.
  PERFORM pg_temp.chk('[O11] no llama a notify_quote_request ni a admin_respond_quote',
    (SELECT prosrc NOT LIKE '%notify_quote_request(%' AND prosrc NOT LIKE '%admin_respond_quote(%'
       FROM pg_proc WHERE oid=to_regprocedure('public.notify_pending_quotes()')));
  PERFORM pg_temp.chk('[O11] notify_quote_request intacta (md5 9370583d...)',
    (SELECT md5(prosrc) FROM pg_proc WHERE oid=to_regprocedure('public.notify_quote_request(uuid)'))
      = '9370583d139a63ef74ff45d976b1a2d3');
  PERFORM pg_temp.chk('[O11] admin_respond_quote intacta (md5 3dc60f49...)',
    (SELECT md5(prosrc) FROM pg_proc
      WHERE oid=to_regprocedure('public.admin_respond_quote(uuid,numeric,numeric,numeric,numeric,numeric,text)'))
      = '3dc60f49c53d45bff19c2c4f4ea44127');

  -- ═══════════════ 7. REPORTE ═══════════════
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
    RAISE EXCEPTION E'TEST_REPORT sql/719 — recordatorios de cotizaciones%\n  PASS=% FAIL=% (obligatorias O1..O11 + controles X)\n  TODO REVERTIDO.',
      v_rep, v_pass, v_fail;
  END;
END
$suite$;

ROLLBACK;
