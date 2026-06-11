-- ════════════════════════════════════════════════════════════════════
-- 200_fix_neighborhood_city_matching.sql
--
-- PROBLEMA:
--   El cliente escribe su colonia/barrio como ciudad (ej. "Valle de los
--   Molinos") pero el grupo tiene registrada la ciudad principal
--   (ej. "Zapopan"). El trigger hace match exacto → nunca coinciden.
--
-- FIX:
--   notify_groups_in_zone() ahora busca grupos cuya ciudad coincida con:
--     1. La ciudad exacta del request (city / location_city), O
--     2. El municipio del request (location_municipio)
--   Así "Valle de los Molinos" en Zapopan notifica a grupos de Zapopan.
-- ════════════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION public.notify_groups_in_zone()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_city        TEXT;
  v_municipio   TEXT;
  v_genre       TEXT;
  v_event_type  TEXT;
  v_total_today INT;
  rec           RECORD;
BEGIN
  IF TG_OP <> 'INSERT' THEN RETURN NEW; END IF;

  v_city       := LOWER(TRIM(COALESCE(NEW.city, NEW.location_city)));
  v_municipio  := LOWER(TRIM(COALESCE(NEW.location_municipio, '')));
  v_genre      := NEW.genre;
  v_event_type := COALESCE(NEW.event_type, 'evento');

  IF v_city IS NULL OR v_city = '' THEN RETURN NEW; END IF;
  IF v_genre IS NULL OR v_genre = '' THEN RETURN NEW; END IF;

  -- Cuántas solicitudes activas del mismo género hay hoy
  -- (busca por city O por municipio para contar correctamente)
  SELECT COUNT(*)::INT INTO v_total_today
  FROM public.event_requests
  WHERE genre  = v_genre
    AND status IN ('open', 'pending', 'en_negociacion')
    AND created_at >= NOW() - INTERVAL '24 hours'
    AND (
      LOWER(TRIM(COALESCE(city, location_city))) = v_city
      OR (v_municipio <> '' AND LOWER(TRIM(COALESCE(city, location_city))) = v_municipio)
      OR (v_municipio <> '' AND LOWER(TRIM(COALESCE(location_municipio, ''))) = v_municipio)
    );

  FOR rec IN
    SELECT DISTINCT g.owner_id, g.city AS grp_city
    FROM public.groups g
    WHERE g.owner_id IS NOT NULL
      AND g.is_active = TRUE
      AND COALESCE(g.availability, 'available') = 'available'
      AND g.genre = v_genre
      AND g.owner_id <> NEW.client_id
      -- Coincide si la ciudad del grupo es igual a la ciudad del request
      -- O a su municipio (colonia → municipio parent)
      AND (
        LOWER(TRIM(g.city)) = v_city
        OR (v_municipio <> '' AND LOWER(TRIM(g.city)) = v_municipio)
      )
      AND NOT EXISTS (
        SELECT 1 FROM public.notifications n
        WHERE n.user_id = g.owner_id
          AND n.type    = 'zone_demand'
          AND (n.data->>'city' = v_city OR n.data->>'city' = v_municipio)
          AND n.data->>'genre' = v_genre
          AND n.created_at > NOW() - INTERVAL '6 hours'
      )
  LOOP
    -- Usar el nombre de ciudad del grupo para el texto (más familiar para el grupo)
    INSERT INTO public.notifications (user_id, type, title, body, data)
    VALUES (
      rec.owner_id,
      'zone_demand',
      '⚡ Solicitud de ' || v_genre || ' en ' || rec.grp_city,
      CASE
        WHEN v_total_today >= 5 THEN
          'Hay ' || v_total_today || ' solicitudes de ' || v_genre || ' en tu zona hoy. ¡Responde rápido!'
        WHEN v_total_today >= 2 THEN
          'Hay ' || v_total_today || ' solicitudes activas de ' || v_genre || ' en tu zona.'
        ELSE
          'Nuevo cliente busca grupo de ' || v_genre || ' cerca de ' || rec.grp_city || '. ¡Sé el primero!'
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

SELECT '200_fix_neighborhood_city_matching.sql ejecutado ✅' AS status;
SELECT 'Trigger ahora acepta colonia → municipio: "Valle de los Molinos" → "Zapopan"' AS fix;
