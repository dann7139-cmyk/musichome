-- ============================================================
-- 38_add_accepted_status.sql
-- Agrega el estado 'accepted' al constraint de reservas.
-- 'accepted' = grupo confirmó → cliente tiene 24h para pagar.
-- 'confirmed' = pago aprobado por Mercado Pago.
-- ============================================================

ALTER TABLE public.reservations
  DROP CONSTRAINT IF EXISTS reservations_status_check;

ALTER TABLE public.reservations
  ADD CONSTRAINT reservations_status_check
  CHECK (status IN (
    -- Legacy (backward compat)
    'pending',
    'in_progress',
    'rejected',
    -- Active statuses
    'pending_payment',
    'pending_provider_confirmation',
    'pending_group_confirmation',
    'accepted',          -- ← NUEVO: grupo confirmó, cliente debe pagar 50%
    'confirmed',         -- pago aprobado por MP
    'completed',
    'cancelled',
    'expired'
  ));

-- Actualizar trigger de notificaciones para 'accepted'
CREATE OR REPLACE FUNCTION public.notify_booking_events()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_group_owner_id UUID;
  v_client_name    TEXT;
  v_group_name     TEXT;
BEGIN
  SELECT g.owner_id, g.name
  INTO   v_group_owner_id, v_group_name
  FROM   public.groups g
  WHERE  g.id = NEW.group_id;

  SELECT p.full_name
  INTO   v_client_name
  FROM   public.profiles p
  WHERE  p.id = NEW.client_id;

  -- INSERT: cliente creó reserva
  IF TG_OP = 'INSERT' THEN
    PERFORM public.queue_push_notification(
      v_group_owner_id,
      'booking_received',
      'Nueva solicitud de reserva',
      COALESCE(v_client_name, 'Un cliente') || ' quiere reservar a ' ||
        COALESCE(v_group_name, 'tu grupo'),
      jsonb_build_object(
        'reservation_id', NEW.id,
        'client_id',      NEW.client_id,
        'event_date',     NEW.event_date
      )
    );
    RETURN NEW;
  END IF;

  IF TG_OP = 'UPDATE' AND (OLD.status IS DISTINCT FROM NEW.status
                          OR OLD.client_confirmed_complete IS DISTINCT FROM NEW.client_confirmed_complete)
  THEN

    -- Grupo aceptó → notificar cliente para pagar 50%
    IF NEW.status = 'accepted' AND OLD.status != 'accepted' THEN
      PERFORM public.queue_push_notification(
        NEW.client_id,
        'booking_accepted',
        '✅ ¡Reserva aceptada!',
        COALESCE(v_group_name, 'El grupo') || ' aceptó tu reserva. Tienes 24 h para pagar el anticipo del 50%.',
        jsonb_build_object('reservation_id', NEW.id)
      );

    -- Pago aprobado → 'confirmed' (webhook MP)
    ELSIF NEW.status = 'confirmed' AND OLD.status = 'accepted' THEN
      PERFORM public.queue_push_notification(
        NEW.client_id,
        'booking_confirmed',
        '🎉 ¡Pago confirmado!',
        'Tu pago fue aprobado. El evento con ' || COALESCE(v_group_name, 'el grupo') || ' está confirmado.',
        jsonb_build_object('reservation_id', NEW.id)
      );
      PERFORM public.queue_push_notification(
        v_group_owner_id,
        'deposit_received',
        '💰 Anticipo recibido',
        'El cliente pagó el anticipo. El evento del ' ||
          TO_CHAR(NEW.event_date::DATE, 'DD/MM/YYYY') || ' está confirmado.',
        jsonb_build_object('reservation_id', NEW.id)
      );

    -- Grupo rechazó
    ELSIF NEW.status = 'rejected' AND OLD.status != 'rejected' THEN
      PERFORM public.queue_push_notification(
        NEW.client_id,
        'booking_rejected',
        'Reserva no aceptada',
        COALESCE(v_group_name, 'El grupo') ||
          ' no pudo aceptar tu solicitud.',
        jsonb_build_object('reservation_id', NEW.id)
      );

    -- Auto-cancelada por falta de pago (accepted → cancelled)
    ELSIF NEW.status = 'cancelled' AND OLD.status = 'accepted' THEN
      PERFORM public.queue_push_notification(
        NEW.client_id,
        'booking_expired_no_payment',
        'Reserva cancelada',
        'No se recibió el pago en 24 horas. La reserva fue cancelada.',
        jsonb_build_object('reservation_id', NEW.id)
      );
      PERFORM public.queue_push_notification(
        v_group_owner_id,
        'booking_expired_no_payment',
        'Cliente no pagó',
        'El cliente no realizó el pago en 24 horas. La fecha quedó liberada.',
        jsonb_build_object('reservation_id', NEW.id)
      );

    -- Cliente confirmó evento completo
    ELSIF NEW.status = 'completed' AND NEW.client_confirmed_complete = TRUE
      AND OLD.client_confirmed_complete = FALSE
    THEN
      PERFORM public.queue_push_notification(
        v_group_owner_id,
        'event_completed',
        'Evento completado',
        'El cliente confirmó el evento. El pago restante ha sido liberado.',
        jsonb_build_object('reservation_id', NEW.id)
      );
      PERFORM public.queue_push_notification(
        NEW.client_id,
        'payment_released',
        'Pago liberado',
        '¡Gracias! El pago restante fue liberado a ' ||
          COALESCE(v_group_name, 'el grupo') || '.',
        jsonb_build_object('reservation_id', NEW.id)
      );

    END IF;
  END IF;

  RETURN NEW;
END;
$$;

SELECT '38_add_accepted_status: OK ✅' AS status;
