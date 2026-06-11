-- ══════════════════════════════════════════════════════════════════════════════
-- Tabla: notifications
-- ══════════════════════════════════════════════════════════════════════════════

CREATE TABLE IF NOT EXISTS public.notifications (
  id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id      UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  type         TEXT NOT NULL CHECK (type IN ('reservation', 'payment', 'review', 'verification', 'system')),
  title        TEXT NOT NULL,
  message      TEXT NOT NULL,
  reference_id UUID,  -- ID de reserva, grupo, etc. según el contexto
  is_read      BOOLEAN NOT NULL DEFAULT false,
  created_at   TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW()
);

-- Índices para mejor rendimiento
CREATE INDEX IF NOT EXISTS idx_notifications_user_id ON public.notifications(user_id);
CREATE INDEX IF NOT EXISTS idx_notifications_created_at ON public.notifications(created_at DESC);
CREATE INDEX IF NOT EXISTS idx_notifications_user_unread ON public.notifications(user_id, is_read) WHERE is_read = false;

-- ══════════════════════════════════════════════════════════════════════════════
-- RLS Policies
-- ══════════════════════════════════════════════════════════════════════════════

ALTER TABLE public.notifications ENABLE ROW LEVEL SECURITY;

-- Los usuarios solo pueden ver sus propias notificaciones
CREATE POLICY "Users can view their own notifications"
ON public.notifications
FOR SELECT
USING (auth.uid() = user_id);

-- Los usuarios solo pueden actualizar (marcar como leídas) sus propias notificaciones
CREATE POLICY "Users can update their own notifications"
ON public.notifications
FOR UPDATE
USING (auth.uid() = user_id)
WITH CHECK (auth.uid() = user_id);

-- Solo el sistema (backend/triggers) puede insertar notificaciones
-- Por ahora permitimos inserts autenticados para testing
CREATE POLICY "Authenticated users can insert notifications"
ON public.notifications
FOR INSERT
WITH CHECK (auth.uid() = user_id);

-- Los usuarios pueden eliminar sus propias notificaciones (opcional)
CREATE POLICY "Users can delete their own notifications"
ON public.notifications
FOR DELETE
USING (auth.uid() = user_id);

-- ══════════════════════════════════════════════════════════════════════════════
-- Función helper para crear notificaciones (opcional, para testing)
-- ══════════════════════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION create_notification(
  p_user_id UUID,
  p_type TEXT,
  p_title TEXT,
  p_message TEXT,
  p_reference_id UUID DEFAULT NULL
)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_notification_id UUID;
BEGIN
  INSERT INTO public.notifications (user_id, type, title, message, reference_id)
  VALUES (p_user_id, p_type, p_title, p_message, p_reference_id)
  RETURNING id INTO v_notification_id;

  RETURN v_notification_id;
END;
$$;

-- ══════════════════════════════════════════════════════════════════════════════
-- Ejemplo de trigger: notificar cuando se crea una reserva
-- ══════════════════════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION notify_reservation_created()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_group_owner_id UUID;
  v_group_name TEXT;
  v_client_name TEXT;
BEGIN
  -- Obtener owner del grupo
  SELECT owner_id, name INTO v_group_owner_id, v_group_name
  FROM groups WHERE id = NEW.group_id;

  -- Obtener nombre del cliente
  SELECT full_name INTO v_client_name
  FROM profiles WHERE id = NEW.client_id;

  -- Crear notificación para el grupo
  IF v_group_owner_id IS NOT NULL THEN
    INSERT INTO notifications (user_id, type, title, message, reference_id)
    VALUES (
      v_group_owner_id,
      'reservation',
      '🎉 Nueva reserva recibida',
      v_client_name || ' solicitó una reserva para el ' || TO_CHAR(NEW.event_date, 'DD/MM/YYYY') || '.',
      NEW.id
    );
  END IF;

  RETURN NEW;
END;
$$;

-- Activar trigger
DROP TRIGGER IF EXISTS trigger_notify_reservation_created ON reservations;
CREATE TRIGGER trigger_notify_reservation_created
AFTER INSERT ON reservations
FOR EACH ROW
EXECUTE FUNCTION notify_reservation_created();

-- ══════════════════════════════════════════════════════════════════════════════
-- Comentarios
-- ══════════════════════════════════════════════════════════════════════════════

COMMENT ON TABLE notifications IS 'Sistema de notificaciones para usuarios';
COMMENT ON COLUMN notifications.type IS 'Tipo: reservation, payment, review, verification, system';
COMMENT ON COLUMN notifications.reference_id IS 'ID del recurso relacionado (reserva, grupo, etc)';
COMMENT ON COLUMN notifications.is_read IS 'Si la notificación ha sido leída';
