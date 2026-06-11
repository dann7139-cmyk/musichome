-- ════════════════════════════════════════════════════════════════════
-- 75_fix_notifications_booking_type.sql
-- Agrega el tipo 'booking' al constraint de notifications.
-- El flujo de solicitudes abiertas usa type='booking' pero no estaba
-- en la lista permitida, causando el error:
--   "violates check constraint notifications_type_check"
-- ════════════════════════════════════════════════════════════════════

ALTER TABLE public.notifications
  DROP CONSTRAINT IF EXISTS notifications_type_check;

ALTER TABLE public.notifications
  ADD CONSTRAINT notifications_type_check
  CHECK (type IN (
    -- Tipos legacy
    'reservation', 'payment', 'review', 'verification', 'system',
    -- Flujo de reservas
    'booking',
    'booking_received',
    'booking_accepted',
    'booking_confirmed',
    'booking_rejected',
    'booking_auto_cancelled',
    'booking_expired_no_payment',
    -- Pagos
    'deposit_received',
    'payment_released',
    -- Eventos
    'event_completed',
    'event_reminder_24h',
    -- Bolsa de trabajo
    'job_invitation',
    -- Cotizaciones
    'new_quote_request',
    'quote_received',
    'quote_accepted',
    'quote_cancelled'
  ));

SELECT '75_fix_notifications_booking_type: booking type agregado ✅' AS status;
