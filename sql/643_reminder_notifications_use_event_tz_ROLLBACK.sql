-- sql/643_reminder_notifications_use_event_tz_ROLLBACK.sql
--
-- Revierte sql/643: restaura las 4 funciones de recordatorio a su forma
-- anterior (hardcode 'America/Mexico_City' para TODOS los eventos, sin
-- importar su país/estado real) y vuelve a crear el cron job duplicado
-- que sql/643 eliminó (jobid 62, 'event-reminder-2h', cada 15 min,
-- llamando a send_event_reminders_2h — redundante con jobid 78 pero
-- inofensivo).
--
-- ÚSESE SOLO EN CASO DE EMERGENCIA DELIBERADA. Revertir esto vuelve a
-- introducir el bug real: los recordatorios de eventos en EE.UU./Canadá
-- (y en los estados fronterizos de México: Tijuana, Hermosillo, Cancún,
-- Mazatlán, Chihuahua) volverían a salir en el momento equivocado.
BEGIN;

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
    WHERE r.event_date = CURRENT_DATE
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
      g.owner_id,
      g.name AS group_name
    FROM  public.reservations r
    JOIN  public.groups g ON g.id = r.group_id
    WHERE r.status           = 'confirmed'
      AND r.event_started_at IS NULL
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
$function$;

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
      g.owner_id,
      g.name AS group_name
    FROM  public.reservations r
    JOIN  public.groups       g ON g.id = r.group_id
    WHERE r.status IN ('confirmed', 'accepted')
      AND r.event_started_at IS NULL
      AND r.event_date BETWEEN CURRENT_DATE AND CURRENT_DATE + 1
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

    IF v_event_ts::DATE = CURRENT_DATE
       AND v_now < v_event_ts
       AND EXTRACT(HOUR FROM v_now AT TIME ZONE 'America/Mexico_City') BETWEEN 7 AND 10
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
      g.owner_id,
      g.name AS group_name
    FROM  public.reservations r
    JOIN  public.groups       g ON g.id = r.group_id
    WHERE r.status IN ('confirmed', 'accepted')
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

-- Restaura el cron duplicado que sql/643 quitó (jobid nuevo, no se puede
-- recrear con el mismo id 62 — pg_cron los asigna automático).
SELECT cron.schedule('event-reminder-2h', '*/15 * * * *', 'SELECT public.send_event_reminders_2h();');

COMMIT;

SELECT '643_reminder_notifications_use_event_tz_ROLLBACK.sql ejecutado ✅' AS status;
