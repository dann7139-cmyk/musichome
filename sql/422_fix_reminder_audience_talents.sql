-- ============================================================
-- sql/422_fix_reminder_audience_talents.sql
-- FIX de audiencia en recordatorios: integrantes + invitados a ESTE evento
--
-- BUG: send_event_reminders_2h (sql/339) y el bloque de 15 min de
--   send_event_reminders (sql/411) notifican a TODOS los
--   job_invitations aceptados del grupo, sin filtrar por evento:
--   · un talento invitado a OTRO evento del grupo recibe recordatorios
--     de eventos ajenos (spam / confusión)
--
-- REGLA NUEVA (misma que sql/421):
--   integrantes permanentes (invitación aceptada sin evento asociado)
--   + talentos invitados y aceptados a ESTE evento
--     (ji.event_id = r.event_id  O  ji.event_request_id = r.event_request_id)
--
-- Solo cambia el SELECT del loop de miembros (+2 columnas en el query
-- principal). Ventanas, textos, idempotencia y crons: intactos.
-- ============================================================


-- ══════════════════════════════════════════════════════════════
-- 1. send_event_reminders_2h (base sql/339, cron */15)
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


-- ══════════════════════════════════════════════════════════════
-- 2. send_event_reminders (base sql/411, cron */10)
--    Bloques morning/1h intactos; solo el loop del 15m cambia.
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

    -- Recordatorio matutino: día del evento, antes de las 10 AM
    IF v_event_ts::DATE = CURRENT_DATE
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

-- ── Verificación: ambas funciones usan la regla nueva de audiencia ────────────
SELECT
  (SELECT routine_definition LIKE '%ji.event_id IS NULL AND ji.event_request_id IS NULL%'
   FROM information_schema.routines
   WHERE routine_schema='public' AND routine_name='send_event_reminders_2h') AS fix_2h,
  (SELECT routine_definition LIKE '%ji.event_id IS NULL AND ji.event_request_id IS NULL%'
   FROM information_schema.routines
   WHERE routine_schema='public' AND routine_name='send_event_reminders')    AS fix_15m;
-- Esperado: true | true

SELECT '422_fix_reminder_audience_talents.sql ejecutado ✅' AS status;
