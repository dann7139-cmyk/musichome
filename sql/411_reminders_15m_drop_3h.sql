-- ============================================================
-- sql/411_reminders_15m_drop_3h.sql
-- A3 · Quitar ventana de 3h de send_event_reminders (redundante con 2h)
-- A4 · Agregar ventana de ~15 min (cliente + owner + integrantes)
--
-- Cadencia final del cliente: 24h → mañana → 2h → 1h → 15min
--
-- ⚠️ CAMBIO DE CRON INCLUIDO (necesario, no opcional):
--   El cron 'send-event-reminders' corre cada 30 min (sql/58). Una
--   ventana de 10-20 min antes (10 min de ancho) se PERDERÍA en ~2/3
--   de los eventos. De hecho la ventana de 1h existente (50-70 min,
--   20 min de ancho) YA se pierde hoy en ~1/3 de los eventos por esto.
--   Este archivo re-agenda el cron a cada 10 min y usa ventana de
--   8-20 min (12 min de ancho > cadencia 10 min) → disparo garantizado.
--   Las demás ventanas son idempotentes (NOT EXISTS), correr más
--   seguido NO duplica nada.
-- REQUISITO: correr sql/410 (constraint) ANTES que este archivo.
-- ============================================================

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

    -- [411] Ventana de 3h ELIMINADA — redundante con event_reminder_2h (sql/339)

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

    -- [411] Recordatorio ~15 min antes (ventana 8-20 min: 12 min de ancho
    -- > cadencia 10 min del cron → siempre cae al menos 1 disparo)
    IF v_event_ts BETWEEN v_now + INTERVAL '8 min' AND v_now + INTERVAL '20 min'
       AND NOT EXISTS (
         SELECT 1 FROM public.notifications
         WHERE data->>'reservation_id' = v_res.id::text AND type = 'event_reminder_15m'
       )
    THEN
      -- Cliente + owner
      INSERT INTO public.notifications (user_id, type, title, body, data)
      SELECT uid, 'event_reminder_15m',
             '⏰ Tu evento empieza en 15 min',
             '¿Ya están en el lugar?',
             jsonb_build_object('reservation_id', v_res.id, 'screen', 'LiveEvent')
      FROM (VALUES (v_res.client_id), (v_res.owner_id)) AS t(uid)
      WHERE uid IS NOT NULL;

      -- Integrantes aceptados (excepto owner) — mismo patrón que sql/339
      FOR v_member IN
        SELECT DISTINCT ji.invited_user_id AS user_id
        FROM   public.job_invitations ji
        WHERE  ji.group_id         = v_res.group_id
          AND  ji.status           = 'accepted'
          AND  ji.invited_user_id != v_res.owner_id
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

-- ── Re-agendar cron: */30 → */10 (ver nota del encabezado) ────────────────────
DO $$ BEGIN
  PERFORM cron.unschedule('send-event-reminders');
EXCEPTION WHEN OTHERS THEN NULL;
END; $$;

SELECT cron.schedule(
  'send-event-reminders',
  '*/10 * * * *',
  $$SELECT public.send_event_reminders()$$
);

-- ── Verificaciones ────────────────────────────────────────────────────────────
-- V1: la función ya no menciona la ventana de 3h y sí la de 15m
SELECT
  routine_definition NOT LIKE '%event_reminder_3h%' AS sin_3h,
  routine_definition LIKE '%event_reminder_15m%'    AS con_15m
FROM information_schema.routines
WHERE routine_schema = 'public' AND routine_name = 'send_event_reminders';
-- Esperado: true | true

-- V2: cron re-agendado a cada 10 min
SELECT jobname, schedule FROM cron.job WHERE jobname = 'send-event-reminders';
-- Esperado: */10 * * * *

SELECT '411_reminders_15m_drop_3h.sql ejecutado ✅' AS status;
