-- ============================================================
-- sql/442_restore_mx_date_filter_reminders.sql
-- REGRESIÓN: sql/441 (mensajes por rol) rebasó send_event_reminders
-- sobre una base que usaba CURRENT_DATE (UTC) en el pre-filtro de
-- fecha — deshaciendo el fix de sql/417.
--
-- BUG (revive el de 417): CURRENT_DATE es la fecha UTC de la sesión.
-- Después de las ~6 PM CDMX (medianoche UTC) CURRENT_DATE ya es el día
-- SIGUIENTE, así que `event_date BETWEEN CURRENT_DATE AND CURRENT_DATE+1`
-- EXCLUYE los eventos de la tarde-noche de hoy → sin recordatorio de
-- 15 min ni de inicio para eventos ≥ 18:00.
--
-- FIX: volver a la fecha LOCAL MX (v_today_mx), idéntico a 417/422_2h.
-- Se conservan los mensajes POR ROL de 441 (cliente vs grupo) y el loop
-- de integrantes/talentos. send_event_reminders_2h NO se toca (en prod
-- ya conserva el fix MX — verificado).
--
-- Nota: México es UTC-6 fijo (sin horario de verano desde 2022), así que
-- AT TIME ZONE 'America/Mexico_City' resuelve -06 siempre.
-- ============================================================

BEGIN;

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
  v_today_mx DATE := (NOW() AT TIME ZONE 'America/Mexico_City')::date;  -- [442] fecha LOCAL
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
      -- [442] Pre-filtro por fecha LOCAL MX (antes: CURRENT_DATE, UTC — regresión de 441)
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

    -- ── Recordatorio matutino: día del evento, antes de las 10 AM ──────
    IF v_event_ts::DATE = v_today_mx
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

      -- Integrantes permanentes + invitados a ESTE evento (regla 422)
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

COMMIT;

-- ── VERIFICACIÓN ──────────────────────────────────────────────────────────────
SELECT
  routine_definition LIKE '%v_today_mx%'                          AS usa_fecha_MX,
  routine_definition LIKE '%event_date BETWEEN CURRENT_DATE%'      AS usa_UTC_regresion,
  routine_definition LIKE '%¡En 1 hora es tu evento!%'            AS conserva_msg_por_rol
FROM information_schema.routines
WHERE routine_schema = 'public' AND routine_name = 'send_event_reminders';
-- Esperado: true | false | true

SELECT '442_restore_mx_date_filter_reminders.sql ejecutado ✅' AS status;
