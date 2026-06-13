-- ============================================================
-- sql/343_fix_cron_timezone.sql
--
-- PROBLEMA: send_event_reminders_2h usaba ':00-06:00' hardcodeado.
--   En horario de verano (abril-octubre, UTC-5) el offset correcto
--   es -05:00, no -06:00 → el cron enviaba recordatorios 1 hora tarde.
--
-- OTROS CRONS AFECTADOS: send_event_reminders (58) y notify_upcoming_events (142)
--   también construyen timestamps con '-06:00'. Este SQL los corrige.
--
-- FIX GENERAL: Usar AT TIME ZONE 'America/Mexico_City' que Postgres
--   resuelve dinámicamente según el calendario de DST.
--
-- NOTA: send_event_reminders_2h ya fue corregido en SQL 339.
--       Este archivo corrige las otras dos funciones.
-- ============================================================


-- ══════════════════════════════════════════════════════════════
-- 1. send_event_reminders (58_event_day_reminders.sql)
--    Busca reservas con ventana de mañana/hoy usando -06:00 hardcodeado
-- ══════════════════════════════════════════════════════════════

-- Verificar si la función tiene -06:00 hardcodeado:
/*
SELECT routine_definition
FROM   information_schema.routines
WHERE  routine_schema = 'public'
  AND  routine_name   = 'send_event_reminders';
*/

CREATE OR REPLACE FUNCTION public.send_event_reminders()
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_res      RECORD;
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
      g.owner_id,
      g.name AS group_name
    FROM  public.reservations r
    JOIN  public.groups       g ON g.id = r.group_id
    WHERE r.status           = 'confirmed'
      AND r.event_started_at IS NULL
      AND r.event_date BETWEEN CURRENT_DATE AND CURRENT_DATE + 1
  LOOP

    -- Parse resiliente con timezone dinámico
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

    -- Recordatorio 3 h antes
    IF v_event_ts BETWEEN v_now + INTERVAL '170 min' AND v_now + INTERVAL '190 min'
       AND NOT EXISTS (
         SELECT 1 FROM public.notifications
         WHERE data->>'reservation_id' = v_res.id::text AND type = 'event_reminder_3h'
       )
    THEN
      INSERT INTO public.notifications (user_id, type, title, body, data)
      SELECT uid, 'event_reminder_3h',
             '⏳ Tu evento comienza en 3 horas',
             'Prepara todo con tiempo. ¡El grupo está listo para llegar!',
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

  END LOOP;
END;
$$;

GRANT EXECUTE ON FUNCTION public.send_event_reminders() TO service_role;


-- ══════════════════════════════════════════════════════════════
-- 2. notify_upcoming_events (142_event_reminder_notifications.sql)
--    Notifica 24 h antes del evento
-- ══════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION public.notify_upcoming_events()
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_res      RECORD;
  v_event_ts TIMESTAMPTZ;
BEGIN
  FOR v_res IN
    SELECT
      r.id,
      r.client_id,
      r.group_id,
      r.event_date,
      r.event_time,
      g.owner_id,
      g.name AS group_name,
      p.name AS package_name
    FROM  public.reservations r
    JOIN  public.groups g ON g.id = r.group_id
    LEFT  JOIN public.packages p ON p.id = r.package_id
    WHERE r.status           = 'confirmed'
      AND r.event_started_at IS NULL
      -- Pre-filtro barato por fecha
      AND r.event_date BETWEEN CURRENT_DATE AND CURRENT_DATE + 2
      -- Idempotencia
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

    -- Ventana: entre 23 h y 25 h antes del evento
    IF v_event_ts NOT BETWEEN NOW() + INTERVAL '23 hours' AND NOW() + INTERVAL '25 hours' THEN
      CONTINUE;
    END IF;

    -- Notificar cliente
    IF v_res.client_id IS NOT NULL THEN
      INSERT INTO public.notifications (user_id, type, title, body, data)
      VALUES (
        v_res.client_id, 'event_upcoming_24h',
        '📅 Tu evento es mañana',
        'Mañana llega ' || v_res.group_name || '. ¿Ya tienes todo listo para recibirlos?',
        jsonb_build_object('reservation_id', v_res.id, 'screen', 'ClientReservations')
      );
    END IF;

    -- Notificar grupo
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


-- ── Verificación ──────────────────────────────────────────────────────────────
DO $$
BEGIN
  RAISE NOTICE '[343] send_event_reminders: -06:00 → AT TIME ZONE dinámico ✅';
  RAISE NOTICE '[343] notify_upcoming_events: -06:00 → AT TIME ZONE dinámico ✅';
  RAISE NOTICE '[343] send_event_reminders_2h: corregido en SQL 339 ✅';
  RAISE NOTICE '[343] Ambas funciones también son resilientes (EXCEPTION por fila) ✅';
END;
$$;

SELECT '343_fix_cron_timezone.sql ejecutado ✅' AS status;
