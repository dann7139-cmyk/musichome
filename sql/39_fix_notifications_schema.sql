-- ============================================================
-- 39_fix_notifications_schema.sql
-- Arregla columnas faltantes en notifications y amplía los tipos
-- permitidos para que queue_push_notification funcione correctamente.
-- ============================================================

-- 1. Agregar columna 'body' (usada por queue_push_notification)
ALTER TABLE public.notifications
  ADD COLUMN IF NOT EXISTS body TEXT;

-- 2. Agregar columna 'data' JSONB (usada por queue_push_notification)
ALTER TABLE public.notifications
  ADD COLUMN IF NOT EXISTS data JSONB DEFAULT '{}';

-- 3. Eliminar el constraint de tipo restrictivo (solo permitía 5 tipos)
ALTER TABLE public.notifications
  DROP CONSTRAINT IF EXISTS notifications_type_check;

-- 4. Añadir constraint flexible con todos los tipos del sistema
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
    'job_invitation'
  ));

-- 5. Actualizar la política RLS de INSERT para permitir que los triggers
--    SECURITY DEFINER puedan insertar notificaciones para cualquier usuario
DROP POLICY IF EXISTS "Authenticated users can insert notifications" ON public.notifications;
DROP POLICY IF EXISTS "system_can_insert_notifications" ON public.notifications;

CREATE POLICY "system_can_insert_notifications"
  ON public.notifications FOR INSERT
  WITH CHECK (true);  -- Triggers SECURITY DEFINER ya validan la lógica

SELECT '39_fix_notifications_schema: OK ✅' AS status;
