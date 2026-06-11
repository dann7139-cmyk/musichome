-- ════════════════════════════════════════════════════════════════════
-- 197_fix_zone_notif_availability.sql
--
-- PROBLEMA: notify_groups_in_zone() (116) notificaba a todos los
--   grupos de la ciudad sin verificar su disponibilidad. Un grupo
--   con availability = 'offline' (Express OFF) recibía notificaciones
--   de eventos express igual.
--
-- FIX: Agregar filtros de is_active y availability = 'available'
--   a la query del trigger, igual que _send_wave() lo hace.
-- ════════════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION public.notify_groups_in_zone()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_city        TEXT;
  v_event_type  TEXT;
  v_total_today INT;
  rec           RECORD;
BEGIN
  IF TG_OP <> 'INSERT' THEN RETURN NEW; END IF;

  v_city       := NEW.city;
  v_event_type := COALESCE(NEW.event_type, 'evento');

  IF v_city IS NULL OR v_city = '' THEN RETURN NEW; END IF;

  SELECT COUNT(*)::INT INTO v_total_today
  FROM public.event_requests
  WHERE city   = v_city
    AND status IN ('open', 'pending', 'en_negociacion')
    AND created_at >= NOW() - INTERVAL '24 hours';

  FOR rec IN
    SELECT DISTINCT g.owner_id
    FROM public.groups g
    WHERE LOWER(TRIM(g.city)) = LOWER(TRIM(v_city))
      AND g.owner_id IS NOT NULL
      AND g.is_active = TRUE                                  -- grupo activo
      AND COALESCE(g.availability, 'available') = 'available' -- Express ON
      AND g.owner_id <> NEW.client_id
      AND NOT EXISTS (
        SELECT 1 FROM public.notifications n
        WHERE n.user_id = g.owner_id
          AND n.type    = 'zone_demand'
          AND n.data->>'city' = v_city
          AND n.created_at > NOW() - INTERVAL '6 hours'
      )
  LOOP
    INSERT INTO public.notifications (user_id, type, title, body, data)
    VALUES (
      rec.owner_id,
      'zone_demand',
      '📍 Demanda activa en ' || v_city,
      CASE
        WHEN v_total_today >= 5 THEN
          'Hay ' || v_total_today || ' solicitudes de ' || v_event_type || ' en ' || v_city || ' hoy. ¡Activa Express para responder!'
        WHEN v_total_today >= 2 THEN
          'Hay ' || v_total_today || ' solicitudes activas en ' || v_city || '. Revisa las solicitudes express.'
        ELSE
          'Nuevo cliente buscando grupo para ' || v_event_type || ' en ' || v_city || '. ¡Responde rápido!'
      END,
      jsonb_build_object(
        'screen',     'OpenRequests',
        'city',       v_city,
        'count',      v_total_today,
        'type',       'express_request'
      )
    );
  END LOOP;

  RETURN NEW;
END;
$$;

-- Recrear trigger
DROP TRIGGER IF EXISTS trg_notify_zone_on_request ON public.event_requests;
CREATE TRIGGER trg_notify_zone_on_request
  AFTER INSERT ON public.event_requests
  FOR EACH ROW
  EXECUTE FUNCTION public.notify_groups_in_zone();

SELECT '197_fix_zone_notif_availability.sql ejecutado ✅' AS status;
SELECT 'notify_groups_in_zone ahora respeta availability = available' AS fix;
