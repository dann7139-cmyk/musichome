-- ════════════════════════════════════════════════════════════════════════════
-- 147_fix_notification_body.sql
-- Corrige el bug crítico: notificaciones push llegan vacías porque las
-- funciones antiguas insertan en `message` pero send-push-notification lee `body`.
--
-- SOLUCIÓN:
--   1. Backfill: copiar message → body en filas existentes con body NULL
--   2. Trigger auto-sync: al INSERT, si body IS NULL, copiar message → body
--   3. Re-crear las funciones más críticas usando `body` en lugar de `message`
--
-- Las funciones 26, 37, 42, 44, 45, 46, 92, 93 quedan cubiertas
-- por el trigger hasta que cada archivo sea re-ejecutado manualmente.
--
-- Ejecutar DESPUÉS de 146_smart_notifications.sql
-- ════════════════════════════════════════════════════════════════════════════


-- ── 1. Backfill: filas existentes con body NULL ───────────────────────────────

UPDATE public.notifications
SET    body = message
WHERE  body IS NULL
  AND  message IS NOT NULL
  AND  message <> '';

-- Confirmación
DO $$
DECLARE v_count INT;
BEGIN
  SELECT COUNT(*) INTO v_count FROM public.notifications WHERE body IS NULL AND message IS NOT NULL;
  RAISE NOTICE '147: % filas con body NULL y message NOT NULL pendientes (deberían ser 0)', v_count;
END;
$$;


-- ── 2. Trigger auto-sync message → body ──────────────────────────────────────
-- Cubre TODAS las funciones antiguas sin necesidad de modificarlas una a una.

CREATE OR REPLACE FUNCTION public.sync_notification_body()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  -- Si body viene vacío/null pero message tiene valor, usar message
  IF (NEW.body IS NULL OR NEW.body = '') AND (NEW.message IS NOT NULL AND NEW.message <> '') THEN
    NEW.body := NEW.message;
  END IF;
  -- Garantizar que data nunca sea NULL (send-push-notification lo usa para deep-link)
  IF NEW.data IS NULL THEN
    NEW.data := '{}'::JSONB;
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_sync_notification_body ON public.notifications;
CREATE TRIGGER trg_sync_notification_body
  BEFORE INSERT OR UPDATE ON public.notifications
  FOR EACH ROW EXECUTE FUNCTION public.sync_notification_body();


-- ── 3. Re-crear función notify_booking_status_change con `body` ───────────────
-- Esta es la más crítica: notifica al cliente y al grupo en cada cambio de estado.
-- La versión original (archivo 44) usaba `message`.

CREATE OR REPLACE FUNCTION public.notify_booking_status_change()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_client_id UUID;
  v_owner_id  UUID;
  v_group_name TEXT;
BEGIN
  -- Obtener datos de la reserva
  SELECT r.client_id, g.owner_id, g.name
  INTO   v_client_id, v_owner_id, v_group_name
  FROM   public.reservations r
  JOIN   public.groups g ON g.id = r.group_id
  WHERE  r.id = NEW.id;

  -- ── Notificar según nuevo estado ─────────────────────────────────────────
  IF NEW.status = 'accepted' AND OLD.status IS DISTINCT FROM 'accepted' THEN
    -- Cliente: grupo aceptó → pagar anticipo
    IF v_client_id IS NOT NULL THEN
      INSERT INTO public.notifications (user_id, type, title, body, reference_id, data)
      VALUES (
        v_client_id,
        'booking_accepted',
        '✅ ' || COALESCE(v_group_name, 'Tu grupo') || ' aceptó tu solicitud',
        'Completa el pago del anticipo para confirmar la reserva.',
        NEW.id,
        jsonb_build_object('reservation_id', NEW.id, 'screen', 'ClientReservations')
      );
    END IF;

  ELSIF NEW.status = 'confirmed' AND OLD.status IS DISTINCT FROM 'confirmed' THEN
    -- Cliente: reserva confirmada
    IF v_client_id IS NOT NULL THEN
      INSERT INTO public.notifications (user_id, type, title, body, reference_id, data)
      VALUES (
        v_client_id,
        'booking_confirmed',
        '🎉 Reserva confirmada',
        '¡Tu evento está confirmado! ' || COALESCE(v_group_name, 'El grupo') || ' estará presente.',
        NEW.id,
        jsonb_build_object('reservation_id', NEW.id, 'screen', 'ClientReservations')
      );
    END IF;
    -- Grupo: recibió anticipo
    IF v_owner_id IS NOT NULL THEN
      INSERT INTO public.notifications (user_id, type, title, body, reference_id, data)
      VALUES (
        v_owner_id,
        'deposit_received',
        '💰 Anticipo recibido',
        'El cliente pagó el anticipo. La reserva está confirmada.',
        NEW.id,
        jsonb_build_object('reservation_id', NEW.id, 'screen', 'GroupReservations')
      );
    END IF;

  ELSIF NEW.status = 'rejected' AND OLD.status IS DISTINCT FROM 'rejected' THEN
    IF v_client_id IS NOT NULL THEN
      INSERT INTO public.notifications (user_id, type, title, body, reference_id, data)
      VALUES (
        v_client_id,
        'booking_rejected',
        '❌ Solicitud rechazada',
        COALESCE(v_group_name, 'El grupo') || ' no pudo aceptar tu solicitud. Puedes buscar otro grupo.',
        NEW.id,
        jsonb_build_object('reservation_id', NEW.id, 'screen', 'ClientReservations')
      );
    END IF;

  ELSIF NEW.status = 'cancelled' AND OLD.status IS DISTINCT FROM 'cancelled' THEN
    -- Notificar a cliente
    IF v_client_id IS NOT NULL THEN
      INSERT INTO public.notifications (user_id, type, title, body, reference_id, data)
      VALUES (
        v_client_id,
        'booking_cancelled',
        '🚫 Reserva cancelada',
        'Tu reserva con ' || COALESCE(v_group_name, 'el grupo') || ' fue cancelada.',
        NEW.id,
        jsonb_build_object('reservation_id', NEW.id, 'screen', 'ClientReservations')
      );
    END IF;
    -- Notificar al grupo
    IF v_owner_id IS NOT NULL THEN
      INSERT INTO public.notifications (user_id, type, title, body, reference_id, data)
      VALUES (
        v_owner_id,
        'booking_cancelled',
        '🚫 Reserva cancelada por el cliente',
        'El cliente canceló la reserva.',
        NEW.id,
        jsonb_build_object('reservation_id', NEW.id, 'screen', 'GroupReservations')
      );
    END IF;
  END IF;

  RETURN NEW;
END;
$$;

-- Nota: el trigger que llama a esta función ya existe en archivos anteriores.
-- Si no existe, crear con:
-- DROP TRIGGER IF EXISTS trg_notify_booking_status ON public.reservations;
-- CREATE TRIGGER trg_notify_booking_status
--   AFTER UPDATE OF status ON public.reservations
--   FOR EACH ROW EXECUTE FUNCTION public.notify_booking_status_change();


-- ── 4. Re-crear notify_new_booking_received con `body` ───────────────────────
-- Notifica al dueño del grupo cuando recibe una nueva solicitud de reserva.

CREATE OR REPLACE FUNCTION public.notify_new_booking_received()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_owner_id   UUID;
  v_client_name TEXT;
BEGIN
  SELECT g.owner_id, p.full_name
  INTO   v_owner_id, v_client_name
  FROM   public.groups g
  JOIN   public.profiles p ON p.id = NEW.client_id
  WHERE  g.id = NEW.group_id;

  IF v_owner_id IS NOT NULL THEN
    INSERT INTO public.notifications (user_id, type, title, body, reference_id, data)
    VALUES (
      v_owner_id,
      'booking_received',
      '🎉 Nueva solicitud de reserva',
      COALESCE(v_client_name, 'Un cliente') || ' quiere contratarte. Revisa los detalles y responde pronto.',
      NEW.id,
      jsonb_build_object('reservation_id', NEW.id, 'screen', 'GroupReservations')
    );
  END IF;

  RETURN NEW;
END;
$$;


SELECT '147_fix_notification_body.sql ejecutado ✅' AS status;
SELECT 'Backfill: message → body en filas existentes' AS info;
SELECT 'Trigger trg_sync_notification_body activo (cubre todas las funciones antiguas)' AS info;
SELECT 'Funciones notify_booking_status_change y notify_new_booking_received actualizadas' AS info;
