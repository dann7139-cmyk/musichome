-- ============================================================
-- sql/243_event_reminder_cron.sql
--
-- Recordatorio 2h antes del evento para grupo + integrantes + cliente.
--
-- Comportamiento:
--   La RPC send_event_reminders_2h() busca reservas cuyo inicio
--   caiga en la ventana [NOW+110min, NOW+130min].
--   Con el cron cada 15 min, al menos un disparo cae en esa ventana.
--   Idempotencia: NOT EXISTS sobre notifications con type='event_reminder_2h'
--   garantiza que nunca se duplique la notificación.
--
-- Soporta: reservas programadas y express (mismo schema).
-- No toca: pagos, Stripe, timers, RLS existente.
-- ============================================================

-- ── 1. RPC: send_event_reminders_2h ──────────────────────────────────────────

CREATE OR REPLACE FUNCTION public.send_event_reminders_2h()
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_res    RECORD;
  v_member RECORD;
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
    WHERE r.status          = 'confirmed'
      AND r.event_started_at IS NULL
      AND r.event_ended_at   IS NULL
      AND r.event_time        IS NOT NULL
      -- Ventana: entre 1h50m y 2h10m desde ahora (cubre holgura de cron cada 15 min)
      -- LEFT(..., 5) recorta HH:MM:SS → HH:MM porque event_time es tipo TIME en Postgres
      AND (r.event_date::text || 'T' || LEFT(r.event_time::text, 5) || ':00-06:00')::TIMESTAMPTZ
          BETWEEN NOW() + INTERVAL '110 minutes'
              AND NOW() + INTERVAL '130 minutes'
      -- Idempotencia: omitir si ya se envió el recordatorio para esta reserva
      AND NOT EXISTS (
        SELECT 1
        FROM   public.notifications n
        WHERE  n.data->>'reservation_id' = r.id::text
          AND  n.type = 'event_reminder_2h'
        LIMIT 1
      )
  LOOP
    -- Notificar al cliente
    IF v_res.client_id IS NOT NULL THEN
      INSERT INTO public.notifications (user_id, type, title, body, data)
      VALUES (
        v_res.client_id,
        'event_reminder_2h',
        '🎵 Tu evento comienza en 2 horas',
        'Tu grupo estará llegando pronto. Asegúrate de que el lugar esté listo para recibirlos.',
        jsonb_build_object(
          'reservation_id', v_res.id,
          'screen',         'LiveEvent'
        )
      );
    END IF;

    -- Notificar al owner del grupo
    IF v_res.owner_id IS NOT NULL THEN
      INSERT INTO public.notifications (user_id, type, title, body, data)
      VALUES (
        v_res.owner_id,
        'event_reminder_2h',
        '⏰ Evento en 2 horas — salgan con tiempo',
        'Recuerden llegar antes del inicio para preparar sonido y logística.',
        jsonb_build_object(
          'reservation_id', v_res.id,
          'screen',         'LiveEvent'
        )
      );
    END IF;

    -- Notificar a integrantes aceptados (excluyendo al owner, ya notificado)
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
        'event_reminder_2h',
        '⏰ Evento en 2 horas — salgan con tiempo',
        'Recuerden llegar antes del inicio para preparar sonido y logística.',
        jsonb_build_object(
          'reservation_id', v_res.id,
          'screen',         'LiveEvent'
        )
      );
    END LOOP;

  END LOOP;
END;
$$;

GRANT EXECUTE ON FUNCTION public.send_event_reminders_2h() TO service_role;

-- ── 2. pg_cron: cada 15 minutos ──────────────────────────────────────────────
-- Eliminar job anterior si existe (idempotente al re-ejecutar este SQL)
DO $$
BEGIN
  PERFORM cron.unschedule('event-reminder-2h');
EXCEPTION WHEN OTHERS THEN NULL;
END;
$$;

SELECT cron.schedule(
  'event-reminder-2h',
  '*/15 * * * *',
  $$SELECT public.send_event_reminders_2h();$$
);

-- ── Verificación ──────────────────────────────────────────────────────────────
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'event-reminder-2h') THEN
    RAISE NOTICE '[243] Cron event-reminder-2h registrado correctamente ✅';
  ELSE
    RAISE WARNING '[243] ALERTA: cron event-reminder-2h NO encontrado';
  END IF;
END;
$$;

SELECT '243_event_reminder_cron.sql: recordatorio 2h antes del evento configurado ✅' AS status;
