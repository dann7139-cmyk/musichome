-- ============================================================
-- sql/222_express_dispatch_push_trigger.sql
-- Trigger: notifica al dueño del grupo cuando le llega un
-- dispatch express, incluyendo dispatchId para deep-link
-- directo a IncomingExpressScreen desde la push notification.
--
-- Por qué: la notificación de zona (notify_groups_in_zone)
-- llega ANTES de que existan dispatches, por lo que no puede
-- incluir dispatchId. Este trigger dispara UNA notificación
-- por dispatch, ya con el ID, para que la app enrute directo.
--
-- Payload resultante (data column):
--   { type: 'express_dispatch', dispatchId: '...', screen: 'IncomingExpress' }
--
-- Ejecutar en: Supabase Dashboard → SQL Editor
-- ============================================================

CREATE OR REPLACE FUNCTION public.notify_group_on_express_dispatch()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_owner_id  uuid;
  v_genre     text;
  v_city      text;
BEGIN
  -- Solo para dispatches nuevos listos para mostrar
  IF NEW.status <> 'pending_broadcast' THEN
    RETURN NEW;
  END IF;

  SELECT g.owner_id, g.genre, g.city
    INTO v_owner_id, v_genre, v_city
    FROM public.groups g
   WHERE g.id = NEW.group_id;

  IF v_owner_id IS NULL THEN
    RETURN NEW;
  END IF;

  INSERT INTO public.notifications (user_id, type, title, body, data)
  VALUES (
    v_owner_id,
    'express_dispatch',
    '⚡ Solicitud Express para ti',
    'Tienes una solicitud de ' || COALESCE(v_genre, 'música') ||
      ' en ' || COALESCE(v_city, 'tu zona') || '. ¡Responde rápido!',
    jsonb_build_object(
      'type',       'express_dispatch',
      'dispatchId', NEW.id::TEXT,
      'screen',     'IncomingExpress'
    )
  );

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_notify_group_on_express_dispatch ON public.express_dispatches;
CREATE TRIGGER trg_notify_group_on_express_dispatch
  AFTER INSERT ON public.express_dispatches
  FOR EACH ROW
  EXECUTE FUNCTION public.notify_group_on_express_dispatch();

-- Verificación: debe existir el trigger
SELECT tgname FROM pg_trigger WHERE tgname = 'trg_notify_group_on_express_dispatch';

SELECT '222_express_dispatch_push_trigger.sql ejecutado ✅' AS status;
