-- ════════════════════════════════════════════════════════════════════
-- 56_fix_notifications_quote_types.sql
-- Agrega los tipos de cotización al constraint de notifications.
-- Sin esto, cualquier INSERT de notificación de cotización falla
-- silenciosamente con violación de constraint.
-- ════════════════════════════════════════════════════════════════════

-- Eliminar constraint restrictivo anterior
ALTER TABLE public.notifications
  DROP CONSTRAINT IF EXISTS notifications_type_check;

-- Nuevo constraint con TODOS los tipos del sistema
ALTER TABLE public.notifications
  ADD CONSTRAINT notifications_type_check
  CHECK (type IN (
    -- Tipos legacy
    'reservation', 'payment', 'review', 'verification', 'system',
    -- Flujo de reservas
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
    -- Cotizaciones ← estaban faltando, causaban fallo silencioso
    'new_quote_request',
    'quote_received',
    'quote_accepted',
    'quote_cancelled'
  ));

SELECT '56_fix_notifications_quote_types: OK ✅' AS status;
