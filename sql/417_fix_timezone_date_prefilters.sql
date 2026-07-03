-- ============================================================
-- sql/417_fix_timezone_date_prefilters.sql
-- FIX timezone: pre-filtros de fecha con CURRENT_DATE (UTC) vs
-- event_date (fecha local CDMX)
--
-- BUG: CURRENT_DATE es la fecha UTC de la sesión. Después de las
--   ~18:00 CDMX (00:00 UTC) "brinca" al día siguiente y los eventos
--   nocturnos de HOY salen del rango → se pierden recordatorios:
--   · 15 min (ventana 8-20)  → eventos ≥ ~18:15 CDMX
--   · 1 h   (ventana 50-70)  → eventos ≥ ~19:00 CDMX
--   · 2 h   (ventana 110-130)→ eventos ≥ ~20:00 CDMX
--   · morning: comparaba v_event_ts::DATE (fecha UTC del instante)
--     = CURRENT_DATE → NUNCA disparaba para eventos ≥ 18:00 CDMX
--
-- FIX: usar (NOW() AT TIME ZONE 'America/Mexico_City')::date como
--   "hoy" en todos los pre-filtros de fecha, y comparar el bloque
--   morning contra event_date (que YA es fecha local) directamente.
--
-- ⚠️ ESTE FIX NO MUEVE LA HORA DE NINGÚN EVENTO. El parse del
--   instante ((date||'T'||HH:MM)::TIMESTAMP AT TIME ZONE
--   'America/Mexico_City') queda idéntico en las 4 funciones; solo
--   cambia QUÉ filas entran al pre-filtro barato de fecha.
--
-- NOTA de documentación (corrige headers previos): México ABOLIÓ el
--   horario de verano en 2022 — America/Mexico_City es UTC-6 todo el
--   año. El comentario de sql/343 sobre "verano UTC-5" era erróneo
--   (inofensivo: AT TIME ZONE resuelve -06 siempre).
--
-- Bases (versiones vigentes, conservadas byte a byte salvo el filtro):
--   send_event_reminders / send_event_reminders_2h ← sql/422
--   notify_upcoming_events                          ← sql/409
--   auto_start_due_events                           ← sql/412
--   (auto_start se incluye por uniformidad; hoy lo salvaba el "-1")
-- ============================================================


-- ══════════════════════════════════════════════════════════════
-- 1. notify_upcoming_events (24h) — base sql/409
-- ══════════════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION public.notify_upcoming_events()
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_res      RECORD;
  v_event_ts TIMESTAMPTZ;
  v_today_mx DATE := (NOW() AT TIME ZONE 'America/Mexico_City')::date;
BEGIN
  FOR v_res IN
    SELECT
      r.id,
      r.client_id,
      r.group_id,
      r.event_date,
      r.event_time,
      g.owner_id,
      g.name AS group_name
    FROM  public.reservations r
    JOIN  public.groups g ON g.id = r.group_id
    WHERE r.status           = 'confirmed'
      AND r.event_started_at IS NULL
      -- [417] Pre-filtro por fecha LOCAL (antes: CURRENT_DATE, UTC)
      AND r.event_date BETWEEN v_today_mx AND v_today_mx + 2
      AND NOT EXISTS (
        SELECT 1 FROM public.notifications
        WHERE data->>'reservation_id' = r.id::text
          AND type = 'event_upcoming_24h'
      )
  LOOP

    BEGIN
      v_event_ts := (
        v_res.event_date::text || 'T' || LEFT(v_res.event_time::text, 5) || ':00'
      )::TIMESTAMP AT TIME ZONE 'America/Mexico_City';
    EXCEPTION WHEN OTHERS THEN
      RAISE WARNING '[notify_upcoming_events] Fecha inválida en reserva %', v_res.id;
      CONTINUE;
    END;

    IF v_event_ts NOT BETWEEN NOW() + INTERVAL '23 hours' AND NOW() + INTERVAL '25 hours' THEN
      CONTINUE;
    END IF;

    IF v_res.client_id IS NOT NULL THEN
      INSERT INTO public.notifications (user_id, type, title, body, data)
      VALUES (
        v_res.client_id, 'event_upcoming_24h',
        '📅 Tu evento es mañana',
        'Mañana llega ' || v_res.group_name || '. ¿Ya tienes todo listo para recibirlos?',
        jsonb_build_object('reservation_id', v_res.id, 'screen', 'ClientReservations')
      );
    END IF;

    IF v_res.owner_id IS NOT NULL THEN
      INSERT INTO public.notifications (user_id, type, title, body, data)
      VALUES (
        v_res.owner_id, 'event_upcoming_24h',
        '📅 Tienes un evento mañana',
        'Recuerda confirmar hora de llegada con el cliente. Evento: ' || v_res.event_date::text,
        jsonb_build_object('reservation_id', v_res.id, 'screen', 'GroupDashboard')
      );
    END IF;

  END LOOP;
END;
$$;

GRANT EXECUTE ON FUNCTION public.notify_upcoming_events() TO service_role;


-- ══════════════════════════════════════════════════════════════
-- 2. send_event_reminders (morning / 1h / 15m) — base sql/422
-- ══════════════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION public.send_event_reminders()
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_res      RECORD;
  v_member   RECORD;
  v_event_ts TIMESTAMPTZ;
  v_now      TIMESTAMPTZ := NOW();
  v_today_mx DATE := (NOW() AT TIME ZONE 'America/Mexico_City')::date;
BEGIN
  FOR v_res IN
    SELECT
      r.id,
      r.client_id,
      r.group_id,
      r.event_date,
      r.event_time,
      r.event_id,
      r.event_request_id,
      g.owner_id,
      g.name AS group_name
    FROM  public.reservations r
    JOIN  public.groups       g ON g.id = r.group_id
    WHERE r.status           = 'confirmed'
      AND r.event_started_at IS NULL
      -- [417] Pre-filtro por fecha LOCAL (antes: CURRENT_DATE, UTC)
      AND r.event_date BETWEEN v_today_mx AND v_today_mx + 1
  LOOP

    BEGIN
      v_event_ts := (
        v_res.event_date::text || 'T' || LEFT(v_res.event_time::text, 5) || ':00'
      )::TIMESTAMP AT TIME ZONE 'America/Mexico_City';
    EXCEPTION WHEN OTHERS THEN
      RAISE WARNING '[send_event_reminders] Fecha inválida en reserva %: date=%, time=%',
        v_res.id, v_res.event_date, v_res.event_time;
      CONTINUE;
    END;

    -- Recordatorio matutino: día del evento, antes de las 10 AM
    -- [417] event_date YA es fecha local → comparar directo (antes:
    -- v_event_ts::DATE = CURRENT_DATE, que fallaba para eventos ≥18:00)
    IF v_res.event_date = v_today_mx
       AND v_now < v_event_ts
       AND EXTRACT(HOUR FROM v_now AT TIME ZONE 'America/Mexico_City') BETWEEN 7 AND 10
       AND NOT EXISTS (
         SELECT 1 FROM public.notifications
         WHERE data->>'reservation_id' = v_res.id::text AND type = 'event_reminder_morning'
       )
    THEN
      INSERT INTO public.notifications (user_id, type, title, body, data)
      SELECT uid, 'event_reminder_morning',
             '📅 ¡Hoy es el día de tu evento!',
             'Tu evento con ' || v_res.group_name || ' es hoy. ¡Que todo salga perfecto!',
             jsonb_build_object('reservation_id', v_res.id, 'screen', 'LiveEvent')
      FROM (VALUES (v_res.client_id), (v_res.owner_id)) AS t(uid)
      WHERE uid IS NOT NULL;
    END IF;

    -- Recordatorio 1 h antes
    IF v_event_ts BETWEEN v_now + INTERVAL '50 min' AND v_now + INTERVAL '70 min'
       AND NOT EXISTS (
         SELECT 1 FROM public.notifications
         WHERE data->>'reservation_id' = v_res.id::text AND type = 'event_reminder_1h'
       )
    THEN
      INSERT INTO public.notifications (user_id, type, title, body, data)
      SELECT uid, 'event_reminder_1h',
             '⏰ ¡1 hora para el evento!',
             'El grupo estará llegando pronto. Asegúrate de que el lugar esté listo.',
             jsonb_build_object('reservation_id', v_res.id, 'screen', 'LiveEvent')
      FROM (VALUES (v_res.client_id), (v_res.owner_id)) AS t(uid)
      WHERE uid IS NOT NULL;
    END IF;

    -- Recordatorio ~15 min antes (ventana 8-20 min > cadencia 10 min)
    IF v_event_ts BETWEEN v_now + INTERVAL '8 min' AND v_now + INTERVAL '20 min'
       AND NOT EXISTS (
         SELECT 1 FROM public.notifications
         WHERE data->>'reservation_id' = v_res.id::text AND type = 'event_reminder_15m'
       )
    THEN
      INSERT INTO public.notifications (user_id, type, title, body, data)
      SELECT uid, 'event_reminder_15m',
             '⏰ Tu evento empieza en 15 min',
             '¿Ya están en el lugar?',
             jsonb_build_object('reservation_id', v_res.id, 'screen', 'LiveEvent')
      FROM (VALUES (v_res.client_id), (v_res.owner_id)) AS t(uid)
      WHERE uid IS NOT NULL;

      -- Integrantes permanentes + invitados a ESTE evento (sql/422)
      FOR v_member IN
        SELECT DISTINCT ji.invited_user_id AS user_id
        FROM   public.job_invitations ji
        WHERE  ji.status           = 'accepted'
          AND  ji.invited_user_id != v_res.owner_id
          AND (
                (ji.group_id = v_res.group_id
                 AND ji.event_id IS NULL AND ji.event_request_id IS NULL)
             OR (v_res.event_id IS NOT NULL AND ji.event_id = v_res.event_id)
             OR (v_res.event_request_id IS NOT NULL
                 AND ji.event_request_id = v_res.event_request_id)
          )
      LOOP
        INSERT INTO public.notifications (user_id, type, title, body, data)
        VALUES (
          v_member.user_id,
          'event_reminder_15m',
          '⏰ Tu evento empieza en 15 min',
          '¿Ya están en el lugar?',
          jsonb_build_object('reservation_id', v_res.id, 'screen', 'LiveEvent')
        );
      END LOOP;
    END IF;

  END LOOP;
END;
$$;

GRANT EXECUTE ON FUNCTION public.send_event_reminders() TO service_role;


-- ══════════════════════════════════════════════════════════════
-- 3. send_event_reminders_2h — base sql/422
-- ══════════════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION public.send_event_reminders_2h()
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_res        RECORD;
  v_member     RECORD;
  v_event_ts   TIMESTAMPTZ;
  v_bad_rows   INT := 0;
  v_sent_rows  INT := 0;
  v_today_mx   DATE := (NOW() AT TIME ZONE 'America/Mexico_City')::date;
BEGIN
  FOR v_res IN
    SELECT
      r.id,
      r.client_id,
      r.group_id,
      r.event_date,
      r.event_time,
      r.event_id,
      r.event_request_id,
      g.owner_id,
      g.name AS group_name
    FROM  public.reservations r
    JOIN  public.groups       g ON g.id = r.group_id
    WHERE r.status            = 'confirmed'
      AND r.event_started_at  IS NULL
      AND r.event_ended_at    IS NULL
      AND r.event_time        IS NOT NULL
      -- [417] Pre-filtro por fecha LOCAL (antes: CURRENT_DATE, UTC)
      AND r.event_date BETWEEN v_today_mx AND v_today_mx + 1
      AND NOT EXISTS (
        SELECT 1
        FROM   public.notifications n
        WHERE  n.data->>'reservation_id' = r.id::text
          AND  n.type = 'event_reminder_2h'
        LIMIT  1
      )
  LOOP

    BEGIN
      v_event_ts := (
        v_res.event_date::text || 'T' || LEFT(v_res.event_time::text, 5) || ':00'
      )::TIMESTAMP AT TIME ZONE 'America/Mexico_City';
    EXCEPTION WHEN OTHERS THEN
      v_bad_rows := v_bad_rows + 1;
      RAISE WARNING
        '[event-reminder-2h] Reserva % tiene fecha/hora inválida y será omitida. '
        'event_date=%, event_time=%, error=%',
        v_res.id, v_res.event_date, v_res.event_time, SQLERRM;
      CONTINUE;
    END;

    IF v_event_ts < NOW() + INTERVAL '110 minutes'
    OR v_event_ts > NOW() + INTERVAL '130 minutes' THEN
      CONTINUE;
    END IF;

    IF v_res.client_id IS NOT NULL THEN
      INSERT INTO public.notifications (user_id, type, title, body, data)
      VALUES (
        v_res.client_id,
        'event_reminder_2h',
        '🎵 Tu evento comienza en 2 horas',
        'Tu grupo estará llegando pronto. Asegúrate de que el lugar esté listo.',
        jsonb_build_object('reservation_id', v_res.id, 'screen', 'LiveEvent')
      );
    END IF;

    IF v_res.owner_id IS NOT NULL THEN
      INSERT INTO public.notifications (user_id, type, title, body, data)
      VALUES (
        v_res.owner_id,
        'event_reminder_2h',
        '⏰ Evento en 2 horas — salgan con tiempo',
        'Recuerden llegar antes del inicio para preparar sonido y logística.',
        jsonb_build_object('reservation_id', v_res.id, 'screen', 'LiveEvent')
      );
    END IF;

    -- Integrantes permanentes + invitados a ESTE evento (sql/422)
    FOR v_member IN
      SELECT DISTINCT ji.invited_user_id AS user_id
      FROM   public.job_invitations ji
      WHERE  ji.status           = 'accepted'
        AND  ji.invited_user_id != v_res.owner_id
        AND (
              (ji.group_id = v_res.group_id
               AND ji.event_id IS NULL AND ji.event_request_id IS NULL)
           OR (v_res.event_id IS NOT NULL AND ji.event_id = v_res.event_id)
           OR (v_res.event_request_id IS NOT NULL
               AND ji.event_request_id = v_res.event_request_id)
        )
    LOOP
      INSERT INTO public.notifications (user_id, type, title, body, data)
      VALUES (
        v_member.user_id,
        'event_reminder_2h',
        '⏰ Evento en 2 horas — salgan con tiempo',
        'Recuerden llegar antes del inicio para preparar sonido y logística.',
        jsonb_build_object('reservation_id', v_res.id, 'screen', 'LiveEvent')
      );
    END LOOP;

    v_sent_rows := v_sent_rows + 1;

  END LOOP;

  IF v_bad_rows > 0 THEN
    RAISE WARNING '[event-reminder-2h] % fila(s) con fecha inválida omitidas; % notificación(es) enviada(s).',
      v_bad_rows, v_sent_rows;
  END IF;
END;
$$;

GRANT EXECUTE ON FUNCTION public.send_event_reminders_2h() TO service_role;


-- ══════════════════════════════════════════════════════════════
-- 4. auto_start_due_events (auto-start + nudge + no-show) — base sql/412
--    Por uniformidad: hoy el "-1" lo salvaba, pero queda a prueba de
--    futuros cambios de rango.
-- ══════════════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION public.auto_start_due_events()
RETURNS INT
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_res         RECORD;
  v_event_ts    TIMESTAMPTZ;
  v_break_type  TEXT;
  v_started     INT := 0;
  v_alerts_sent INT := 0;
  v_nudges_sent INT := 0;
  v_admin_id    UUID;
  v_today_mx    DATE := (NOW() AT TIME ZONE 'America/Mexico_City')::date;
BEGIN
  IF NOT pg_try_advisory_xact_lock(7654321098) THEN
    RETURN 0;
  END IF;

  SELECT id INTO v_admin_id
  FROM   public.profiles
  WHERE  role = 'admin'
  LIMIT  1;

  FOR v_res IN
    SELECT
      r.id,
      r.client_id,
      r.group_id,
      r.event_date,
      r.event_time,
      r.group_arrived_at,
      g.owner_id,
      g.name AS group_name
    FROM  public.reservations r
    JOIN  public.groups       g ON g.id = r.group_id
    WHERE r.status            = 'confirmed'
      AND r.event_started_at  IS NULL
      AND r.event_ended_at    IS NULL
      AND r.event_time        IS NOT NULL
      -- [417] Pre-filtro por fecha LOCAL (antes: CURRENT_DATE, UTC)
      AND r.event_date BETWEEN v_today_mx - 1 AND v_today_mx
  LOOP

    BEGIN
      v_event_ts := (
        v_res.event_date::text || 'T' || LEFT(v_res.event_time::text, 5) || ':00'
      )::TIMESTAMP AT TIME ZONE 'America/Mexico_City';
    EXCEPTION WHEN OTHERS THEN
      RAISE WARNING '[auto-start-events] Fecha inválida en reserva %', v_res.id;
      CONTINUE;
    END;

    IF v_event_ts > NOW() THEN
      CONTINUE;
    END IF;

    IF v_event_ts < NOW() - INTERVAL '6 hours' THEN
      CONTINUE;
    END IF;

    -- ── CASO 0: Grupo llegó, hora pasada, dentro de la gracia de 10 min ──
    IF v_res.group_arrived_at IS NOT NULL
       AND v_event_ts + INTERVAL '10 minutes' > NOW()
       AND NOT EXISTS (
         SELECT 1 FROM public.notifications
         WHERE data->>'reservation_id' = v_res.id::text
           AND type = 'event_auto_started'
           AND data->>'nudge' = 'true'
       )
    THEN
      IF v_res.owner_id IS NOT NULL THEN
        INSERT INTO public.notifications (user_id, type, title, body, data)
        VALUES (
          v_res.owner_id,
          'event_auto_started',
          '🎸 ¿Ya empezaron a tocar?',
          'Marca el inicio de tu evento en la app.',
          jsonb_build_object(
            'reservation_id', v_res.id,
            'screen',         'EventTimer',
            'nudge',          true
          )
        );
        v_nudges_sent := v_nudges_sent + 1;
      END IF;
    END IF;

    -- ── CASO 1: Grupo llegó → auto-iniciar si pasaron 10 min ──
    IF v_res.group_arrived_at IS NOT NULL
       AND v_event_ts + INTERVAL '10 minutes' <= NOW()
    THEN

      SELECT break_type INTO v_break_type
      FROM   public.reservations
      WHERE  group_id    = v_res.group_id
        AND  break_type  IS NOT NULL
        AND  status      = 'completed'
      ORDER  BY event_date DESC
      LIMIT  1;

      v_break_type := COALESCE(v_break_type, 'B');

      UPDATE public.reservations
      SET
        status           = 'in_progress',
        event_started_at = v_event_ts + INTERVAL '10 minutes',
        break_type       = v_break_type
      WHERE id = v_res.id;

      IF v_res.owner_id IS NOT NULL THEN
        INSERT INTO public.notifications (user_id, type, title, body, data)
        VALUES (
          v_res.owner_id,
          'event_auto_started',
          '⏰ Tu evento inició automáticamente',
          'El evento comenzó. Abre la app para ver el timer y registrar el inicio oficial.',
          jsonb_build_object(
            'reservation_id', v_res.id,
            'screen',         'EventTimer',
            'auto_started',   true
          )
        );
      END IF;

      IF v_res.client_id IS NOT NULL THEN
        INSERT INTO public.notifications (user_id, type, title, body, data)
        VALUES (
          v_res.client_id,
          'event_auto_started',
          '🎵 ¡Tu evento ha iniciado!',
          v_res.group_name || ' ya está tocando. ¡Disfrútalo!',
          jsonb_build_object(
            'reservation_id', v_res.id,
            'screen',         'LiveEvent'
          )
        );
      END IF;

      v_started := v_started + 1;
      RAISE NOTICE '[auto-start-events] Reserva % iniciada automáticamente con break_type=%',
        v_res.id, v_break_type;

    -- ── CASO 2: Grupo NO llegó y pasaron > 30 min → alerta al admin ──
    ELSIF v_res.group_arrived_at IS NULL
          AND v_event_ts + INTERVAL '30 minutes' <= NOW()
          AND NOT EXISTS (
            SELECT 1 FROM public.notifications
            WHERE data->>'reservation_id' = v_res.id::text
              AND type = 'event_no_show_alert'
          )
    THEN
      IF v_admin_id IS NOT NULL THEN
        INSERT INTO public.notifications (user_id, type, title, body, data)
        VALUES (
          v_admin_id,
          'event_no_show_alert',
          '⚠️ Posible no-show: ' || v_res.group_name,
          'El grupo no marcó llegada y el evento debió iniciar hace más de 30 min. Reserva: ' || v_res.id::text,
          jsonb_build_object(
            'reservation_id', v_res.id,
            'group_id',       v_res.group_id,
            'event_ts',       v_event_ts,
            'screen',         'AdminVerifications'
          )
        );
        v_alerts_sent := v_alerts_sent + 1;
      END IF;

      RAISE WARNING '[auto-start-events] Posible no-show: reserva %, grupo %, evento a las %',
        v_res.id, v_res.group_id, v_event_ts;
    END IF;

  END LOOP;

  IF v_started > 0 OR v_alerts_sent > 0 OR v_nudges_sent > 0 THEN
    RAISE NOTICE '[auto-start-events] Iniciados: %, alertas no-show: %, nudges: %',
      v_started, v_alerts_sent, v_nudges_sent;
  END IF;

  RETURN v_started;
END;
$$;

GRANT EXECUTE ON FUNCTION public.auto_start_due_events() TO service_role;


-- ── Verificaciones ────────────────────────────────────────────────────────────
-- V1: ninguna de las 4 funciones usa ya CURRENT_DATE
SELECT
  (SELECT routine_definition NOT LIKE '%CURRENT_DATE%'
   FROM information_schema.routines
   WHERE routine_schema='public' AND routine_name='notify_upcoming_events')   AS upcoming_ok,
  (SELECT routine_definition NOT LIKE '%CURRENT_DATE%'
   FROM information_schema.routines
   WHERE routine_schema='public' AND routine_name='send_event_reminders')     AS reminders_ok,
  (SELECT routine_definition NOT LIKE '%CURRENT_DATE%'
   FROM information_schema.routines
   WHERE routine_schema='public' AND routine_name='send_event_reminders_2h')  AS reminders_2h_ok,
  (SELECT routine_definition NOT LIKE '%CURRENT_DATE%'
   FROM information_schema.routines
   WHERE routine_schema='public' AND routine_name='auto_start_due_events')    AS auto_start_ok;
-- Esperado: true | true | true | true

-- V2: las 4 conservan el parse del instante (la hora NO se movió)
SELECT
  (SELECT COUNT(*) FROM information_schema.routines
   WHERE routine_schema='public'
     AND routine_name IN ('notify_upcoming_events','send_event_reminders',
                          'send_event_reminders_2h','auto_start_due_events')
     AND routine_definition LIKE '%AT TIME ZONE ''America/Mexico_City''%') AS funcs_con_parse_local;
-- Esperado: 4

SELECT '417_fix_timezone_date_prefilters.sql ejecutado ✅' AS status;
