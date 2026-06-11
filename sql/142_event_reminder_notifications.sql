-- ════════════════════════════════════════════════════════════════════════════
-- 142_event_reminder_notifications.sql
-- Recordatorio 24h antes del evento:
--   • notify_upcoming_events(): inserta notificación al cliente y al grupo
--   • pg_cron: ejecuta cada hora
--
-- Ejecutar DESPUÉS de 141_bid_renewal_notifications.sql
-- ════════════════════════════════════════════════════════════════════════════


-- ── 1. Agregar tipo 'event_reminder_24h' si no existe ────────────────────
-- Ya existe en el constraint (event_reminder_24h). Verificamos que esté.

ALTER TABLE public.notifications
  DROP CONSTRAINT IF EXISTS notifications_type_check;

ALTER TABLE public.notifications
  ADD CONSTRAINT notifications_type_check
  CHECK (type IN (
    'reservation',
    'payment',
    'review',
    'verification',
    'system',
    'financial',
    'admin_alert',
    'booking',
    'booking_received',
    'booking_accepted',
    'booking_confirmed',
    'booking_rejected',
    'booking_auto_cancelled',
    'booking_expired_no_payment',
    'booking_cancelled',
    'deposit_received',
    'payment_released',
    'event_reminder_24h',
    'event_completed',
    'event_started',
    'overtime_requested',
    'dispute_opened',
    'dispute_received',
    'job_invitation',
    'new_quote_request',
    'quote_received',
    'quote_accepted',
    'quote_cancelled',
    'bid_expiry_reminder',
    'event_reschedule'        -- nueva fecha por reprogramación del cliente
  )) NOT VALID;


-- ── 2. Función notify_upcoming_events ────────────────────────────────────
-- Notifica cliente Y grupo cuando el evento es mañana (ventana 23-25h).
-- Evita duplicados: no envía si ya existe notif en las últimas 20h.

DROP FUNCTION IF EXISTS public.notify_upcoming_events();
CREATE OR REPLACE FUNCTION public.notify_upcoming_events()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  rec RECORD;
BEGIN
  FOR rec IN
    SELECT
      r.id            AS reservation_id,
      r.client_id,
      r.event_date,
      r.event_time,
      g.owner_id      AS group_owner_id,
      g.name          AS group_name,
      r.total_price
    FROM public.reservations r
    JOIN public.groups g ON g.id = r.group_id
    WHERE r.status IN ('confirmed', 'accepted')
      AND r.payment_status IN ('deposit_paid', 'fully_paid')
      AND (r.event_date::date = (now() + INTERVAL '1 day')::date)
      -- evitar duplicado al cliente
      AND NOT EXISTS (
        SELECT 1 FROM public.notifications n
        WHERE n.user_id  = r.client_id
          AND n.type     = 'event_reminder_24h'
          AND (n.data->>'reservation_id')::text = r.id::text
          AND n.created_at > now() - INTERVAL '20 hours'
      )
  LOOP
    -- Notificación al cliente
    INSERT INTO public.notifications (user_id, type, title, body, data)
    VALUES (
      rec.client_id,
      'event_reminder_24h',
      '🎵 Tu evento es mañana',
      'Revisa los detalles de tu reserva y asegúrate de que todo esté listo.',
      jsonb_build_object(
        'reservation_id', rec.reservation_id,
        'group_name',     rec.group_name,
        'event_date',     rec.event_date,
        'event_time',     rec.event_time,
        'total_price',    rec.total_price
      )
    );

    -- Notificación al grupo
    INSERT INTO public.notifications (user_id, type, title, body, data)
    VALUES (
      rec.group_owner_id,
      'event_reminder_24h',
      '📅 Tienes un evento mañana',
      'Recuerda confirmar tu asistencia y llegar a tiempo.',
      jsonb_build_object(
        'reservation_id', rec.reservation_id,
        'event_date',     rec.event_date,
        'event_time',     rec.event_time,
        'total_price',    rec.total_price
      )
    );
  END LOOP;
END;
$$;

GRANT EXECUTE ON FUNCTION public.notify_upcoming_events() TO service_role;


-- ── 3. pg_cron: ejecutar cada hora ───────────────────────────────────────

SELECT cron.unschedule('notify-upcoming-events') WHERE EXISTS (
  SELECT 1 FROM cron.job WHERE jobname = 'notify-upcoming-events'
);

SELECT cron.schedule(
  'notify-upcoming-events',
  '30 * * * *',
  $$SELECT public.notify_upcoming_events()$$
);


SELECT '142_event_reminder_notifications.sql ejecutado ✅' AS status;
SELECT 'Cron: notify-upcoming-events → cada hora (:30) → notify_upcoming_events()' AS cron;
SELECT 'Tipos agregados/confirmados: event_reminder_24h, event_reschedule' AS types;
