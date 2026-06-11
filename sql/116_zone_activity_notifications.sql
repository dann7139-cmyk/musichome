-- ════════════════════════════════════════════════════════════════════════════
-- 116_zone_activity_notifications.sql
-- Notificaciones push de actividad por zona a grupos.
-- Cuando un cliente publica una solicitud expres en una ciudad, los grupos
-- de esa ciudad reciben una notificación para que respondan rápido.
--
-- IMPLEMENTA:
--   1. notify_groups_in_zone() — trigger AFTER INSERT en event_requests
--      → envía notif a grupos verificados de la misma ciudad
--      → rate-limit: 1 notif por grupo por ciudad cada 6 horas
--   2. get_zone_demand(p_city) — RPC: cuántas solicitudes activas hay en la zona
--   3. get_my_zone_stats()    — RPC para grupos: actividad de su ciudad hoy
--
-- Ejecutar DESPUÉS de 115_client_loyalty.sql
-- ════════════════════════════════════════════════════════════════════════════


-- ── 1. Trigger: notificar grupos de la zona ──────────────────────────────────

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
  -- Solo cuando se crea una solicitud nueva y activa
  IF TG_OP <> 'INSERT' THEN RETURN NEW; END IF;

  v_city       := NEW.city;
  v_event_type := COALESCE(NEW.event_type, 'evento');

  IF v_city IS NULL OR v_city = '' THEN RETURN NEW; END IF;

  -- Cuántas solicitudes activas hay hoy en esta ciudad
  SELECT COUNT(*)::INT INTO v_total_today
  FROM public.event_requests
  WHERE city   = v_city
    AND status IN ('pending', 'en_negociacion')
    AND created_at >= NOW() - INTERVAL '24 hours';

  -- Notificar a cada grupo activo en esa ciudad (owner_id)
  -- Rate-limit: no notificar si ya se envió una notif de zona en las últimas 6 h
  FOR rec IN
    SELECT DISTINCT g.owner_id
    FROM public.groups g
    WHERE LOWER(TRIM(g.city)) = LOWER(TRIM(v_city))
      AND g.owner_id IS NOT NULL
      AND g.owner_id <> NEW.client_id    -- no notificar si coincide (edge case)
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
          'Hay ' || v_total_today || ' solicitudes de ' || v_event_type || ' en ' || v_city || ' hoy. ¡Es un buen momento para estar disponible!'
        WHEN v_total_today >= 2 THEN
          'Hay ' || v_total_today || ' solicitudes activas en ' || v_city || '. Revisa las solicitudes express.'
        ELSE
          'Nuevo cliente buscando grupo para ' || v_event_type || ' en ' || v_city || '. ¡Responde rápido!'
      END,
      jsonb_build_object(
        'screen', 'OpenRequests',
        'city',   v_city,
        'count',  v_total_today
      )
    );
  END LOOP;

  RETURN NEW;
END;
$$;

-- Crear o reemplazar el trigger
DROP TRIGGER IF EXISTS trg_notify_zone_on_request ON public.event_requests;
CREATE TRIGGER trg_notify_zone_on_request
  AFTER INSERT ON public.event_requests
  FOR EACH ROW
  EXECUTE FUNCTION public.notify_groups_in_zone();


-- ── 2. RPC: get_zone_demand(p_city) ──────────────────────────────────────────
-- Grupos pueden consultar cuánta demanda activa hay en su ciudad.

DROP FUNCTION IF EXISTS public.get_zone_demand(TEXT);
CREATE OR REPLACE FUNCTION public.get_zone_demand(p_city TEXT)
RETURNS TABLE (
  city             TEXT,
  active_requests  BIGINT,
  requests_today   BIGINT,
  top_event_type   TEXT,
  groups_in_zone   BIGINT
)
LANGUAGE plpgsql
SECURITY DEFINER STABLE
SET search_path = public
AS $$
BEGIN
  RETURN QUERY
  SELECT
    p_city                                                      AS city,
    COUNT(*) FILTER (WHERE er.status IN ('pending','en_negociacion'))
                                                                AS active_requests,
    COUNT(*) FILTER (WHERE er.created_at >= NOW() - INTERVAL '24 hours'
                       AND er.status IN ('pending','en_negociacion'))
                                                                AS requests_today,
    (
      SELECT er2.event_type
      FROM public.event_requests er2
      WHERE LOWER(TRIM(er2.city)) = LOWER(TRIM(p_city))
        AND er2.created_at >= NOW() - INTERVAL '7 days'
        AND er2.event_type IS NOT NULL
      GROUP BY er2.event_type
      ORDER BY COUNT(*) DESC
      LIMIT 1
    )                                                           AS top_event_type,
    (
      SELECT COUNT(*)
      FROM public.groups g
      WHERE LOWER(TRIM(g.city)) = LOWER(TRIM(p_city))
    )                                                           AS groups_in_zone
  FROM public.event_requests er
  WHERE LOWER(TRIM(er.city)) = LOWER(TRIM(p_city));
END;
$$;

GRANT EXECUTE ON FUNCTION public.get_zone_demand(TEXT) TO authenticated;


-- ── 3. RPC: get_my_zone_stats() ───────────────────────────────────────────────
-- Para grupos: métricas de actividad en su ciudad.

DROP FUNCTION IF EXISTS public.get_my_zone_stats();
CREATE OR REPLACE FUNCTION public.get_my_zone_stats()
RETURNS TABLE (
  city              TEXT,
  active_requests   BIGINT,
  my_open_requests  BIGINT,  -- solicitudes abiertas que aún no han respondido
  competitors       BIGINT,  -- otros grupos en la misma ciudad
  demand_trend      TEXT     -- 'up' | 'flat' | 'down'
)
LANGUAGE plpgsql
SECURITY DEFINER STABLE
SET search_path = public
AS $$
DECLARE
  v_group_id  UUID;
  v_city      TEXT;
  v_last7     BIGINT;
  v_prev7     BIGINT;
BEGIN
  -- Obtener el grupo del usuario autenticado
  SELECT g.id, g.city INTO v_group_id, v_city
  FROM public.groups g
  WHERE g.owner_id = auth.uid()
  LIMIT 1;

  IF v_group_id IS NULL THEN RETURN; END IF;
  IF v_city IS NULL OR v_city = '' THEN RETURN; END IF;

  -- Solicitudes últimos 7 días vs 7 días anteriores (tendencia)
  SELECT COUNT(*) INTO v_last7
  FROM public.event_requests
  WHERE LOWER(TRIM(city)) = LOWER(TRIM(v_city))
    AND created_at >= NOW() - INTERVAL '7 days';

  SELECT COUNT(*) INTO v_prev7
  FROM public.event_requests
  WHERE LOWER(TRIM(city)) = LOWER(TRIM(v_city))
    AND created_at BETWEEN NOW() - INTERVAL '14 days' AND NOW() - INTERVAL '7 days';

  RETURN QUERY
  SELECT
    v_city,
    -- Solicitudes activas en la ciudad
    (SELECT COUNT(*) FROM public.event_requests er
     WHERE LOWER(TRIM(er.city)) = LOWER(TRIM(v_city))
       AND er.status IN ('pending', 'en_negociacion')),
    -- Solicitudes abiertas en la ciudad sin respuesta del grupo actual
    (SELECT COUNT(*) FROM public.event_requests er
     WHERE LOWER(TRIM(er.city)) = LOWER(TRIM(v_city))
       AND er.status = 'pending'
       AND NOT EXISTS (
         SELECT 1 FROM public.event_request_groups erg
         WHERE erg.event_request_id = er.id
           AND erg.group_id = v_group_id
       )),
    -- Competidores en la ciudad
    (SELECT COUNT(*) FROM public.groups g
     WHERE LOWER(TRIM(g.city)) = LOWER(TRIM(v_city))
       AND g.id <> v_group_id),
    -- Tendencia
    CASE
      WHEN v_prev7 = 0      THEN 'up'
      WHEN v_last7 > v_prev7 * 1.2 THEN 'up'
      WHEN v_last7 < v_prev7 * 0.8 THEN 'down'
      ELSE 'flat'
    END::TEXT;
END;
$$;

GRANT EXECUTE ON FUNCTION public.get_my_zone_stats() TO authenticated;


SELECT '116_zone_activity_notifications.sql ejecutado ✅' AS status;
SELECT 'Notificaciones de zona activas. Rate-limit: 1 por grupo cada 6 horas.' AS info;
