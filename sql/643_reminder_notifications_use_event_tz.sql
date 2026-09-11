-- ============================================================
-- sql/643_reminder_notifications_use_event_tz.sql
--
-- Petición del usuario (2026-09-11): "verifica los notificaciones de un
-- día antes o el día del evento... me imagino que es lo mismo para
-- Estados Unidos y Canadá".
--
-- HALLAZGO REAL: NO era lo mismo. Las 4 funciones que mandan estos
-- recordatorios (notify_today_events, notify_upcoming_events,
-- send_event_reminders, send_event_reminders_2h) calculan el momento
-- exacto del evento asumiendo SIEMPRE 'America/Mexico_City' — con
-- `(event_date + event_time) AT TIME ZONE 'America/Mexico_City'` escrito
-- literal en las 3 últimas.
--
-- Pero desde sql/514 (19 de julio) ya existe `reservations.event_tz`:
-- la zona horaria IANA REAL de cada evento, calculada por
-- tz_for_event(state, country) y usada correctamente por el sistema de
-- disponibilidad (busy_range) — cubre las 4 zonas de México (incluye
-- Tijuana, Hermosillo, Cancún, Mazatlán, Chihuahua, que NO son
-- Mexico_City), varias zonas de EE.UU. y varias de Canadá. Los
-- recordatorios simplemente nunca se actualizaron para usarla.
--
-- Impacto real hoy: CERO — las únicas 8 reservas que existen en la BD
-- son todas event_tz = 'America/Mexico_City' (verificado antes de
-- tocar nada). Pero en cuanto se confirme la primera reserva de EE.UU.,
-- Canadá, o un estado fronterizo de México, sus recordatorios de
-- "2 horas antes", "1 hora antes", "15 minutos antes" y el de la mañana
-- del evento saldrían en el momento EQUIVOCADO (hasta ±3-4 horas de
-- diferencia real, según la zona).
--
-- Corrección: las 4 funciones ahora usan
-- `AT TIME ZONE COALESCE(r.event_tz, 'America/Mexico_City')` — el
-- fallback a Mexico_City solo protege filas viejísimas de antes de
-- sql/514 que por algún motivo nunca se respaldaron (no debería haber
-- ninguna: sql/514 hizo backfill de las 100%).
--
-- Limpieza de paso (hallada al revisar los cron jobs, no relacionada
-- al bug): dos cron jobs distintos (ids 62 y 78) llamaban a la MISMA
-- función send_event_reminders_2h() en horarios distintos (cada 15 min
-- y cada 10 min) — redundante pero inofensivo (la función es
-- idempotente por el NOT EXISTS). Se elimina el duplicado más antiguo.
-- ============================================================

BEGIN;

-- ── 1. notify_today_events — "hoy" según la zona del EVENTO, no UTC ──
CREATE OR REPLACE FUNCTION public.notify_today_events()
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_rec           RECORD;
  v_member_id     UUID;
  v_group_name    TEXT;
  v_client_name   TEXT;
BEGIN
  FOR v_rec IN
    SELECT
      r.id AS reservation_id, r.client_id, r.group_id, r.event_date, r.event_time,
      g.name AS group_name, g.owner_id, p.full_name AS client_name
    FROM public.reservations r
    JOIN public.groups       g ON g.id = r.group_id
    JOIN public.profiles     p ON p.id = r.client_id
    WHERE r.event_date = (NOW() AT TIME ZONE COALESCE(r.event_tz, 'America/Mexico_City'))::date  -- [643] antes: CURRENT_DATE (fecha UTC, ignoraba la zona del evento)
      AND r.status IN ('confirmed', 'accepted', 'in_progress')
  LOOP
    v_group_name  := v_rec.group_name;
    v_client_name := v_rec.client_name;

    IF v_rec.owner_id IS NOT NULL THEN
      INSERT INTO public.notifications (user_id, type, title, message, body, reference_id, data)
      VALUES (
        v_rec.owner_id, 'event_reminder_24h', '🎵 ¡Hoy es el evento!',
        '¡' || v_group_name || ' brilla hoy! El evento con ' || v_client_name ||
        ' es hoy' || COALESCE(' a las ' || v_rec.event_time, '') || '. ¡Mucha energía y éxito! 🎶',
        '¡' || v_group_name || ' brilla hoy! El evento con ' || v_client_name ||
        ' es hoy' || COALESCE(' a las ' || v_rec.event_time, '') || '. ¡Mucha energía y éxito! 🎶',
        v_rec.reservation_id,
        jsonb_build_object('reservation_id', v_rec.reservation_id, 'screen', 'EventTimer')
      )
      ON CONFLICT DO NOTHING;
    END IF;

    FOR v_member_id IN
      SELECT ji.invited_user_id FROM public.job_invitations ji
      WHERE ji.group_id = v_rec.group_id AND ji.status = 'accepted'
        AND ji.event_id IS NULL AND ji.invited_user_id != v_rec.owner_id
    LOOP
      INSERT INTO public.notifications (user_id, type, title, message, body, reference_id, data)
      VALUES (
        v_member_id, 'event_reminder_24h', '🎵 ¡Hoy es el evento!',
        '¡Hoy toca con ' || v_group_name || '! El evento es hoy' ||
        COALESCE(' a las ' || v_rec.event_time, '') || '. ¡Dalo todo, el equipo cuenta contigo! 🔥',
        '¡Hoy toca con ' || v_group_name || '! El evento es hoy' ||
        COALESCE(' a las ' || v_rec.event_time, '') || '. ¡Dalo todo, el equipo cuenta contigo! 🔥',
        v_rec.reservation_id,
        jsonb_build_object('reservation_id', v_rec.reservation_id, 'screen', 'EventTimer')
      )
      ON CONFLICT DO NOTHING;
    END LOOP;

    IF v_rec.client_id IS NOT NULL THEN
      INSERT INTO public.notifications (user_id, type, title, message, body, reference_id, data)
      VALUES (
        v_rec.client_id, 'event_reminder_24h', '🎶 ¡Tu evento es hoy!',
        v_group_name || ' se está alistando para hacer de tu evento algo inolvidable' ||
        COALESCE(' a las ' || v_rec.event_time, '') || '. ¡Prepárate! 🎉',
        v_group_name || ' se está alistando para hacer de tu evento algo inolvidable' ||
        COALESCE(' a las ' || v_rec.event_time, '') || '. ¡Prepárate! 🎉',
        v_rec.reservation_id,
        jsonb_build_object('reservation_id', v_rec.reservation_id, 'screen', 'EventTimer')
      )
      ON CONFLICT DO NOTHING;
    END IF;
  END LOOP;
END;
$function$;

-- ── 2. notify_upcoming_events — "mañana" en la zona del EVENTO ───────
CREATE OR REPLACE FUNCTION public.notify_upcoming_events()
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
      r.event_tz,   -- [643]
      g.owner_id,
      g.name AS group_name
    FROM  public.reservations r
    JOIN  public.groups g ON g.id = r.group_id
    WHERE r.status           = 'confirmed'
      AND r.event_started_at IS NULL
      -- Pre-filtro amplio (±2 días) — solo para no recorrer toda la tabla;
      -- la ventana precisa de 23-25h de abajo es la que de verdad decide.
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
      )::TIMESTAMP AT TIME ZONE COALESCE(v_res.event_tz, 'America/Mexico_City');  -- [643] antes: 'America/Mexico_City' fijo
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
$function$;

-- ── 3. send_event_reminders — mañana/1h/15min en la zona del EVENTO ──
CREATE OR REPLACE FUNCTION public.send_event_reminders()
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_res      RECORD;
  v_member   RECORD;
  v_event_ts TIMESTAMPTZ;
  v_now      TIMESTAMPTZ := NOW();
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
      r.event_tz,   -- [643]
      g.owner_id,
      g.name AS group_name
    FROM  public.reservations r
    JOIN  public.groups       g ON g.id = r.group_id
    WHERE r.status IN ('confirmed', 'accepted')   -- [485] pagadas viven en 'accepted'
      AND r.event_started_at IS NULL
      AND r.event_date BETWEEN CURRENT_DATE AND CURRENT_DATE + 1
  LOOP

    BEGIN
      v_event_ts := (
        v_res.event_date::text || 'T' || LEFT(v_res.event_time::text, 5) || ':00'
      )::TIMESTAMP AT TIME ZONE COALESCE(v_res.event_tz, 'America/Mexico_City');  -- [643] antes: 'America/Mexico_City' fijo
    EXCEPTION WHEN OTHERS THEN
      RAISE WARNING '[send_event_reminders] Fecha inválida en reserva %: date=%, time=%',
        v_res.id, v_res.event_date, v_res.event_time;
      CONTINUE;
    END;

    -- ── Recordatorio matutino: día del evento, antes de las 10 AM (hora LOCAL del evento) ──
    IF v_event_ts::DATE = CURRENT_DATE
       AND v_now < v_event_ts
       AND EXTRACT(HOUR FROM v_now AT TIME ZONE COALESCE(v_res.event_tz, 'America/Mexico_City')) BETWEEN 7 AND 10  -- [643] antes: siempre hora de MX
       AND NOT EXISTS (
         SELECT 1 FROM public.notifications
         WHERE data->>'reservation_id' = v_res.id::text AND type = 'event_reminder_morning'
       )
    THEN
      IF v_res.client_id IS NOT NULL THEN
        INSERT INTO public.notifications (user_id, type, title, body, data)
        VALUES (v_res.client_id, 'event_reminder_morning',
          '📅 ¡Hoy es el día de tu evento!',
          'Hoy toca ' || v_res.group_name || ' en tu evento. ¡Que todo salga perfecto!',
          jsonb_build_object('reservation_id', v_res.id, 'screen', 'LiveEvent'));
      END IF;
      IF v_res.owner_id IS NOT NULL THEN
        INSERT INTO public.notifications (user_id, type, title, body, data)
        VALUES (v_res.owner_id, 'event_reminder_morning',
          '📅 ¡Hoy tienes tocada!',
          'Hoy es tu evento. Revisa la hora y prepárate para salir con tiempo.',
          jsonb_build_object('reservation_id', v_res.id, 'screen', 'LiveEvent'));
      END IF;
    END IF;

    -- ── Recordatorio 1 h antes ─────────────────────────────────────────
    IF v_event_ts BETWEEN v_now + INTERVAL '50 min' AND v_now + INTERVAL '70 min'
       AND NOT EXISTS (
         SELECT 1 FROM public.notifications
         WHERE data->>'reservation_id' = v_res.id::text AND type = 'event_reminder_1h'
       )
    THEN
      IF v_res.client_id IS NOT NULL THEN
        INSERT INTO public.notifications (user_id, type, title, body, data)
        VALUES (v_res.client_id, 'event_reminder_1h',
          '⏰ ¡1 hora para tu evento!',
          'El grupo está por salir hacia el lugar. Asegúrate de que todo esté listo para recibirlos.',
          jsonb_build_object('reservation_id', v_res.id, 'screen', 'LiveEvent'));
      END IF;
      IF v_res.owner_id IS NOT NULL THEN
        INSERT INTO public.notifications (user_id, type, title, body, data)
        VALUES (v_res.owner_id, 'event_reminder_1h',
          '⏰ ¡En 1 hora es tu evento!',
          'Salgan con tiempo para llegar y preparar el sonido antes del inicio.',
          jsonb_build_object('reservation_id', v_res.id, 'screen', 'LiveEvent'));
      END IF;
    END IF;

    -- ── Recordatorio ~15 min antes (ventana 8-20 min > cadencia 10 min) ─
    IF v_event_ts BETWEEN v_now + INTERVAL '8 min' AND v_now + INTERVAL '20 min'
       AND NOT EXISTS (
         SELECT 1 FROM public.notifications
         WHERE data->>'reservation_id' = v_res.id::text AND type = 'event_reminder_15m'
       )
    THEN
      IF v_res.client_id IS NOT NULL THEN
        INSERT INTO public.notifications (user_id, type, title, body, data)
        VALUES (v_res.client_id, 'event_reminder_15m',
          '⏰ Tu evento empieza en 15 min',
          '¿Ya llegó tu grupo? Está por comenzar.',
          jsonb_build_object('reservation_id', v_res.id, 'screen', 'LiveEvent'));
      END IF;
      IF v_res.owner_id IS NOT NULL THEN
        INSERT INTO public.notifications (user_id, type, title, body, data)
        VALUES (v_res.owner_id, 'event_reminder_15m',
          '⏰ Tu evento empieza en 15 min',
          '¿Ya están en el lugar? Prepárense para iniciar.',
          jsonb_build_object('reservation_id', v_res.id, 'screen', 'LiveEvent'));
      END IF;

      -- [422] Integrantes permanentes + invitados a ESTE evento (intacto)
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
          '¿Ya están en el lugar? Prepárense para iniciar.',
          jsonb_build_object('reservation_id', v_res.id, 'screen', 'LiveEvent')
        );
      END LOOP;
    END IF;

  END LOOP;
END;
$function$;

-- ── 4. send_event_reminders_2h — 2 horas antes en la zona del EVENTO ─
CREATE OR REPLACE FUNCTION public.send_event_reminders_2h()
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_res        RECORD;
  v_member     RECORD;
  v_event_ts   TIMESTAMPTZ;
  v_bad_rows   INT := 0;
  v_sent_rows  INT := 0;
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
      r.event_tz,   -- [643]
      g.owner_id,
      g.name AS group_name
    FROM  public.reservations r
    JOIN  public.groups       g ON g.id = r.group_id
    WHERE r.status IN ('confirmed', 'accepted')   -- [485] pagadas viven en 'accepted'
      AND r.event_started_at  IS NULL
      AND r.event_ended_at    IS NULL
      AND r.event_time        IS NOT NULL
      AND r.event_date BETWEEN CURRENT_DATE AND CURRENT_DATE + 1
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
      )::TIMESTAMP AT TIME ZONE COALESCE(v_res.event_tz, 'America/Mexico_City');  -- [643] antes: 'America/Mexico_City' fijo
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

    -- [422] Integrantes permanentes + invitados a ESTE evento
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
$function$;

-- ── 5. Limpieza: cron duplicado (mismo trabajo, 2 horarios distintos) ─
SELECT cron.unschedule(62);  -- 'event-reminder-2h' (*/15 min) — duplica a jobid 78 'send-event-reminders-2h' (*/10 min)

COMMIT;

-- ── VERIFICACIÓN ────────────────────────────────────────────
SELECT proname,
  pg_get_functiondef(oid) ILIKE '%event_tz%' AS usa_event_tz
FROM pg_proc
WHERE proname IN ('notify_today_events','notify_upcoming_events','send_event_reminders','send_event_reminders_2h');
-- Esperado: 4 filas, todas usa_event_tz = true

SELECT jobid, jobname FROM cron.job WHERE command ILIKE '%send_event_reminders_2h%';
-- Esperado: 1 fila (jobid 78)

SELECT '643_reminder_notifications_use_event_tz.sql ejecutado ✅' AS status;
