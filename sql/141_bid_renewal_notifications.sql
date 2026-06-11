-- ════════════════════════════════════════════════════════════════════════════
-- 141_bid_renewal_notifications.sql
-- Recordatorios de renovación de puja:
--   • notify_expiring_bids(): inserta notificación 24h antes de expirar
--   • pg_cron: ejecuta cada hora
--
-- Ejecutar DESPUÉS de 140_pricing_update.sql
-- ════════════════════════════════════════════════════════════════════════════


-- ── 1. Agregar tipo 'bid_expiry_reminder' al constraint ───────────────────

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
    -- Nuevos: renovación de puja
    'bid_expiry_reminder'   -- recordatorio 24h antes de que expire la puja
  )) NOT VALID;


-- ── 2. Función notify_expiring_bids ──────────────────────────────────────
-- Inserta una notificación para cada grupo cuya puja expira
-- en las próximas 24 horas y aún no ha recibido este aviso hoy.

DROP FUNCTION IF EXISTS public.notify_expiring_bids();
CREATE OR REPLACE FUNCTION public.notify_expiring_bids()
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
      g.id        AS group_id,
      g.owner_id  AS user_id,
      g.name      AS group_name,
      g.bid_amount,
      g.bid_ends_at,
      EXTRACT(EPOCH FROM (g.bid_ends_at - now())) / 3600 AS hours_left
    FROM public.groups g
    WHERE g.bid_amount  > 0
      AND g.bid_ends_at IS NOT NULL
      AND g.bid_ends_at  > now()
      AND g.bid_ends_at  < now() + INTERVAL '25 hours'  -- ventana 0-25h
      -- evitar duplicado: no enviar si ya existe una notif de hoy
      AND NOT EXISTS (
        SELECT 1 FROM public.notifications n
        WHERE n.user_id  = g.owner_id
          AND n.type     = 'bid_expiry_reminder'
          AND n.created_at > now() - INTERVAL '20 hours'
      )
  LOOP
    INSERT INTO public.notifications (user_id, type, title, body, data)
    VALUES (
      rec.user_id,
      'bid_expiry_reminder',
      '⏳ Tu promoción está por terminar',
      'No pierdas tu visibilidad. Si no renuevas, otro grupo puede tomar tu lugar.',
      jsonb_build_object(
        'group_id',    rec.group_id,
        'group_name',  rec.group_name,
        'bid_amount',  rec.bid_amount,
        'bid_ends_at', rec.bid_ends_at,
        'hours_left',  ROUND(rec.hours_left::NUMERIC, 1)
      )
    );
  END LOOP;
END;
$$;

GRANT EXECUTE ON FUNCTION public.notify_expiring_bids() TO service_role;


-- ── 3. pg_cron: ejecutar cada hora ───────────────────────────────────────

SELECT cron.unschedule('notify-expiring-bids') WHERE EXISTS (
  SELECT 1 FROM cron.job WHERE jobname = 'notify-expiring-bids'
);

SELECT cron.schedule(
  'notify-expiring-bids',
  '0 * * * *',
  $$SELECT public.notify_expiring_bids()$$
);


SELECT '141_bid_renewal_notifications.sql ejecutado ✅' AS status;
SELECT 'Cron: notify-expiring-bids → cada hora → notify_expiring_bids()' AS cron;
SELECT 'Tipo agregado: bid_expiry_reminder' AS new_type;
