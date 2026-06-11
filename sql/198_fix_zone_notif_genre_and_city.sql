-- ════════════════════════════════════════════════════════════════════
-- 198_fix_zone_notif_genre_and_city.sql
--
-- PROBLEMA (persiste después de 197):
--   notify_groups_in_zone() notificaba a TODOS los grupos de la ciudad
--   sin importar su género. Un grupo de Mariachi recibía notificaciones
--   de solicitudes de Norteño, etc.
--   También: el conteo usaba solo la columna 'city' y podía quedar en 0
--   si el registro solo tenía 'location_city'.
--
-- FIX:
--   1. Agregar filtro g.genre = NEW.genre al FOR loop
--   2. Asegurar que la columna 'city' existe (para retrocompatibilidad)
--   3. Sincronizar city = location_city en registros donde city es NULL
--   4. Corregir el conteo usando COALESCE(city, location_city)
-- ════════════════════════════════════════════════════════════════════

-- ── 1. Asegurar que la columna 'city' existe en event_requests ───────────────
ALTER TABLE public.event_requests
  ADD COLUMN IF NOT EXISTS city TEXT;

-- Rellenar city desde location_city donde esté vacío
UPDATE public.event_requests
SET    city = location_city
WHERE  city IS NULL AND location_city IS NOT NULL;

-- ── 2. Reescribir notify_groups_in_zone() con género y filtros completos ─────
CREATE OR REPLACE FUNCTION public.notify_groups_in_zone()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_city        TEXT;
  v_genre       TEXT;
  v_event_type  TEXT;
  v_total_today INT;
  rec           RECORD;
BEGIN
  IF TG_OP <> 'INSERT' THEN RETURN NEW; END IF;

  v_city       := COALESCE(NEW.city, NEW.location_city);
  v_genre      := NEW.genre;
  v_event_type := COALESCE(NEW.event_type, 'evento');

  IF v_city IS NULL OR v_city = '' THEN RETURN NEW; END IF;
  IF v_genre IS NULL OR v_genre = '' THEN RETURN NEW; END IF;

  -- Cuántas solicitudes de este género hay en la ciudad hoy
  SELECT COUNT(*)::INT INTO v_total_today
  FROM public.event_requests
  WHERE LOWER(TRIM(COALESCE(city, location_city))) = LOWER(TRIM(v_city))
    AND genre  = v_genre
    AND status IN ('open', 'pending', 'en_negociacion')
    AND created_at >= NOW() - INTERVAL '24 hours';

  FOR rec IN
    SELECT DISTINCT g.owner_id
    FROM public.groups g
    WHERE LOWER(TRIM(g.city)) = LOWER(TRIM(v_city))
      AND g.owner_id IS NOT NULL
      AND g.is_active = TRUE                                   -- grupo activo
      AND COALESCE(g.availability, 'available') = 'available'  -- Express ON
      AND g.genre = v_genre                                    -- mismo género
      AND g.owner_id <> NEW.client_id
      AND NOT EXISTS (
        SELECT 1 FROM public.notifications n
        WHERE n.user_id = g.owner_id
          AND n.type    = 'zone_demand'
          AND n.data->>'city'  = v_city
          AND n.data->>'genre' = v_genre
          AND n.created_at > NOW() - INTERVAL '6 hours'
      )
  LOOP
    INSERT INTO public.notifications (user_id, type, title, body, data)
    VALUES (
      rec.owner_id,
      'zone_demand',
      '⚡ Solicitud de ' || v_genre || ' en ' || v_city,
      CASE
        WHEN v_total_today >= 5 THEN
          'Hay ' || v_total_today || ' solicitudes de ' || v_genre || ' en ' || v_city || ' hoy. ¡Responde rápido!'
        WHEN v_total_today >= 2 THEN
          'Hay ' || v_total_today || ' solicitudes activas de ' || v_genre || ' en ' || v_city || '.'
        ELSE
          'Nuevo cliente busca grupo de ' || v_genre || ' en ' || v_city || '. ¡Sé el primero en responder!'
      END,
      jsonb_build_object(
        'screen',           'OpenRequests',
        'city',             v_city,
        'genre',            v_genre,
        'count',            v_total_today,
        'type',             'express_request',
        'event_request_id', NEW.id::TEXT
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

SELECT '198_fix_zone_notif_genre_and_city.sql ejecutado ✅' AS status;
SELECT 'notify_groups_in_zone: filtros availability + genre + city corregidos' AS fix;
