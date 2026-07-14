-- ============================================================
-- sql/485_fix_reminders_accepted.sql
-- 🔔 FIX CRÍTICO: los recordatorios de evento NUNCA disparaban.
--
-- Causa (2026-07-13, evento real de las 8pm sin recordatorios):
--   send_event_reminders y send_event_reminders_2h filtran
--   r.status = 'confirmed', pero las reservas PAGADAS de la app viven
--   en 'accepted' — TERCERA aparición del mismo bug (ya corregido en
--   get_group_busy_days sql/472 y mark_abandoned_reservations sql/479).
--
-- Cambios:
--   1. Ambas funciones: status IN ('confirmed','accepted').
--      Todo lo demás intacto (textos por rol de 441, audiencia de
--      talentos de 422, ventanas e idempotencia).
--   2. cron.schedule de ambas cada 10 min con nombres canónicos —
--      por si nunca fueron agendadas (como pasó con los no-shows).
--      La idempotencia interna (NOT EXISTS por tipo) evita duplicados
--      aunque exista otro cron viejo apuntando a las mismas funciones.
-- ============================================================

BEGIN;

-- ────────────────────────────────────────────────────────────
-- 1) send_event_reminders (matutino / 1h / 15m) — base sql/441
-- ────────────────────────────────────────────────────────────
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
    WHERE r.status IN ('confirmed', 'accepted')   -- [485] pagadas viven en 'accepted'
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

    -- ── Recordatorio matutino: día del evento, antes de las 10 AM ──────
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
$$;

GRANT EXECUTE ON FUNCTION public.send_event_reminders() TO service_role;

-- ────────────────────────────────────────────────────────────
-- 2) send_event_reminders_2h — base sql/422
-- ────────────────────────────────────────────────────────────
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
$$;

GRANT EXECUTE ON FUNCTION public.send_event_reminders_2h() TO service_role;

COMMIT;

-- ────────────────────────────────────────────────────────────
-- 3) Asegurar los crons (cada 10 min) — idempotente
-- ────────────────────────────────────────────────────────────
DO $$ BEGIN
  PERFORM cron.unschedule('send-event-reminders');
EXCEPTION WHEN OTHERS THEN NULL;
END; $$;
SELECT cron.schedule('send-event-reminders', '*/10 * * * *',
  $$SELECT public.send_event_reminders();$$);

DO $$ BEGIN
  PERFORM cron.unschedule('send-event-reminders-2h');
EXCEPTION WHEN OTHERS THEN NULL;
END; $$;
SELECT cron.schedule('send-event-reminders-2h', '*/10 * * * *',
  $$SELECT public.send_event_reminders_2h();$$);

-- ── VERIFICACIÓN ──────────────────────────────────────────────────────────────
SELECT
  (SELECT prosrc LIKE '%''confirmed'', ''accepted''%' FROM pg_proc WHERE proname='send_event_reminders')    AS fix_reminders,
  (SELECT prosrc LIKE '%''confirmed'', ''accepted''%' FROM pg_proc WHERE proname='send_event_reminders_2h') AS fix_2h;
-- Esperado: true | true

SELECT jobname, schedule FROM cron.job
WHERE jobname IN ('send-event-reminders', 'send-event-reminders-2h');
-- Esperado: 2 filas, */10 * * * *

-- ¿Hay crons VIEJOS duplicados apuntando a las mismas funciones? (revisar)
SELECT jobname, schedule, command FROM cron.job
WHERE command ILIKE '%send_event_reminder%'
  AND jobname NOT IN ('send-event-reminders', 'send-event-reminders-2h');
-- Si sale alguno: avísame y te digo si conviene quitarlo (no duplican
-- notificaciones por la idempotencia interna, pero es limpieza).

SELECT '485_fix_reminders_accepted.sql ejecutado ✅' AS status;
