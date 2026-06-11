-- ════════════════════════════════════════════════════════════════════
-- 82_notify_express_gdl_by_proximity.sql
-- RPC que notifica grupos express:
--   1. Solo grupos de Guadalajara (city ILIKE '%guadalajara%')
--   2. Del mismo género que la solicitud
--   3. Ordenados por distancia al evento (más cercano primero)
--      usando la tabla group_locations (lat/lng en tiempo real).
--      Los grupos sin ubicación registrada van al final.
-- ════════════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION public.notify_express_gdl_groups(
  p_request_id UUID,
  p_event_lat  DOUBLE PRECISION DEFAULT NULL,
  p_event_lng  DOUBLE PRECISION DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_req       RECORD;
  v_group     RECORD;
  v_notifs    JSONB[] := ARRAY[]::JSONB[];
  v_count     INT := 0;
  v_dist_km   DOUBLE PRECISION;
  v_body      TEXT;
BEGIN
  -- Obtener datos de la solicitud
  SELECT * INTO v_req
  FROM public.event_requests
  WHERE id = p_request_id;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'request_not_found');
  END IF;

  -- Construir body de la notificación
  v_body := 'Evento de ' || v_req.hours || 'h el ' ||
            TO_CHAR(v_req.event_date, 'DD Mon') || ' en ' ||
            COALESCE(v_req.location_city, 'GDL') ||
            '. ¡Sé el primero en aceptar!';

  -- ── Insertar notificaciones ordenadas por proximidad ─────────────────────
  FOR v_group IN
    SELECT
      g.owner_id,
      g.name,
      gl.lat,
      gl.lng,
      CASE
        WHEN gl.lat IS NOT NULL AND p_event_lat IS NOT NULL THEN
          -- Haversine simplificado (km): suficientemente preciso para GDL
          6371 * 2 * ASIN(SQRT(
            POWER(SIN(RADIANS((gl.lat - p_event_lat) / 2)), 2) +
            COS(RADIANS(p_event_lat)) * COS(RADIANS(gl.lat)) *
            POWER(SIN(RADIANS((gl.lng - p_event_lng) / 2)), 2)
          ))
        ELSE NULL
      END AS dist_km
    FROM public.groups g
    LEFT JOIN public.group_locations gl ON gl.group_id = g.id
    WHERE g.genre    = v_req.genre
      AND g.is_active = TRUE
      AND (
        g.city ILIKE '%guadalajara%'
        OR g.city ILIKE '%gdl%'
        OR gl.city ILIKE '%guadalajara%'
      )
    ORDER BY
      dist_km ASC NULLS LAST,  -- más cercano primero; sin coords van al final
      g.created_at ASC
  LOOP
    INSERT INTO public.notifications (user_id, type, title, body, data)
    VALUES (
      v_group.owner_id,
      'booking',
      '⚡ Nueva tocada express disponible',
      v_body,
      jsonb_build_object(
        'request_id', p_request_id,
        'screen',     'OpenRequests',
        'dist_km',    ROUND(v_group.dist_km::NUMERIC, 1)
      )
    );
    v_count := v_count + 1;
  END LOOP;

  RETURN jsonb_build_object(
    'ok',      true,
    'notified', v_count
  );

EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$$;

GRANT EXECUTE ON FUNCTION public.notify_express_gdl_groups(UUID, DOUBLE PRECISION, DOUBLE PRECISION) TO authenticated;

SELECT '82_notify_express_gdl_by_proximity: notify_express_gdl_groups ✅' AS status;
