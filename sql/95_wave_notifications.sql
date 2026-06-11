-- ═══════════════════════════════════════════════════════════════════════════════
-- 95_wave_notifications.sql
-- Sistema de olas de notificación para solicitudes express
--
-- 1. Columnas de tracking en event_requests (waves, coords, notified_count)
-- 2. notify_wave_1() — top 5 por ranking + proximidad
-- 3. process_notification_waves() — cron: envía wave 2 y 3 según timeouts
-- 4. get_request_competition() — cuántos grupos están viendo la solicitud
-- 5. pg_cron: cada 2 min para procesar olas pendientes
--
-- FLUJO DE OLAS:
--   Wave 1 (inmediata)  → top 5 grupos: mejor ranking + más cercanos
--   Wave 2 (+2 min)     → siguientes 10 grupos (si aún status='open')
--   Wave 3 (+5 min más) → todos los grupos restantes del radio
--
-- RANKING (wave 1 prioritario):
--   score = (ranking_score * 0.5) + (1 / (dist_km + 1) * 5 * 0.5)
--   ranking_score viene de la tabla groups (calculado por 93_reputation_system)
--
-- Ejecutar DESPUÉS de 94.
-- ═══════════════════════════════════════════════════════════════════════════════

-- ────────────────────────────────────────────────────────────────────────────
-- 1. COLUMNAS DE TRACKING EN EVENT_REQUESTS
-- ────────────────────────────────────────────────────────────────────────────

ALTER TABLE event_requests
  ADD COLUMN IF NOT EXISTS event_lat      DOUBLE PRECISION,
  ADD COLUMN IF NOT EXISTS event_lng      DOUBLE PRECISION,
  ADD COLUMN IF NOT EXISTS radius_km      DOUBLE PRECISION DEFAULT 50,
  ADD COLUMN IF NOT EXISTS current_wave   SMALLINT         DEFAULT 0,
  ADD COLUMN IF NOT EXISTS wave1_sent_at  TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS wave2_sent_at  TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS wave3_sent_at  TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS notified_count INT              DEFAULT 0;

-- Índice para el cron: solicitudes abiertas con ola pendiente
CREATE INDEX IF NOT EXISTS idx_er_wave_pending
  ON event_requests(status, current_wave, wave1_sent_at, wave2_sent_at)
  WHERE status = 'open';

-- ────────────────────────────────────────────────────────────────────────────
-- 2. FUNCIÓN INTERNA: calcula dist_km con Haversine
-- ────────────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION haversine_km(
  lat1 DOUBLE PRECISION, lng1 DOUBLE PRECISION,
  lat2 DOUBLE PRECISION, lng2 DOUBLE PRECISION
)
RETURNS DOUBLE PRECISION LANGUAGE sql IMMUTABLE AS $$
  SELECT 6371 * 2 * ASIN(SQRT(
    POWER(SIN(RADIANS((lat2 - lat1) / 2)), 2) +
    COS(RADIANS(lat1)) * COS(RADIANS(lat2)) *
    POWER(SIN(RADIANS((lng2 - lng1) / 2)), 2)
  ));
$$;

-- ────────────────────────────────────────────────────────────────────────────
-- 3. FUNCIÓN INTERNA: enviar ola a un rango de grupos ordenados por score
--    p_offset / p_limit controlan qué "página" de grupos se notifica.
--    Retorna el número de notificaciones insertadas.
-- ────────────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION _send_wave(
  p_req       RECORD,         -- registro de event_requests
  p_offset    INT,
  p_limit     INT,
  p_is_urgent BOOLEAN DEFAULT FALSE
)
RETURNS INT LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_group   RECORD;
  v_count   INT := 0;
  v_body    TEXT;
  v_title   TEXT;
BEGIN
  v_title := CASE WHEN p_is_urgent
    THEN '🔥 ¡Evento URGENTE disponible!'
    ELSE '⚡ Nueva tocada express disponible'
  END;

  v_body := 'Evento de ' || p_req.hours || 'h el ' ||
            TO_CHAR(p_req.event_date, 'DD Mon') || ' en ' ||
            COALESCE(p_req.location_city, 'tu zona') ||
            CASE WHEN p_is_urgent THEN ' · ¡Comienza en menos de 6 horas!' ELSE '. ¡Sé el primero en aceptar!' END;

  FOR v_group IN
    SELECT
      g.id            AS group_id,
      g.owner_id,
      g.name,
      COALESCE(g.ranking_score, 0) AS ranking_score,
      gl.lat,
      gl.lng,
      CASE
        WHEN gl.lat IS NOT NULL AND p_req.event_lat IS NOT NULL
          THEN haversine_km(gl.lat, gl.lng, p_req.event_lat, p_req.event_lng)
        ELSE NULL
      END AS dist_km
    FROM groups g
    LEFT JOIN group_locations gl ON gl.group_id = g.id
    WHERE g.genre     = p_req.genre
      AND g.is_active = TRUE
      AND COALESCE(g.availability, 'available') = 'available'
      AND (
        gl.lat IS NULL
        OR p_req.event_lat IS NULL
        OR haversine_km(gl.lat, gl.lng, p_req.event_lat, p_req.event_lng) <= COALESCE(p_req.radius_km, 50)
      )
      -- No notificar a grupos que ya recibieron la notificación de esta solicitud
      AND NOT EXISTS (
        SELECT 1 FROM notifications n
        WHERE n.user_id = g.owner_id
          AND n.data->>'request_id' = p_req.id::TEXT
      )
    ORDER BY
      -- Score combinado: 50% ranking, 50% proximidad (normalizada)
      (COALESCE(g.ranking_score, 0) * 0.5) +
      (CASE WHEN gl.lat IS NOT NULL AND p_req.event_lat IS NOT NULL
        THEN (1.0 / (haversine_km(gl.lat, gl.lng, p_req.event_lat, p_req.event_lng) + 1.0)) * 5.0 * 0.5
        ELSE 0
       END) DESC,
      g.created_at ASC
    OFFSET p_offset LIMIT p_limit
  LOOP
    INSERT INTO notifications (user_id, type, title, body, data)
    VALUES (
      v_group.owner_id,
      'booking',
      v_title,
      v_body,
      jsonb_build_object(
        'request_id', p_req.id,
        'screen',     'OpenRequests',
        'dist_km',    ROUND(v_group.dist_km::NUMERIC, 1),
        'is_urgent',  p_is_urgent
      )
    );
    v_count := v_count + 1;
  END LOOP;

  RETURN v_count;
END;
$$;

-- ────────────────────────────────────────────────────────────────────────────
-- 4. notify_wave_1()
--    Llamar inmediatamente después de crear una solicitud express.
--    Notifica los top-5 por score (ranking + proximidad).
--    Guarda event_lat/lng para que el cron procese las olas siguientes.
-- ────────────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION public.notify_wave_1(
  p_request_id UUID,
  p_event_lat  DOUBLE PRECISION DEFAULT NULL,
  p_event_lng  DOUBLE PRECISION DEFAULT NULL,
  p_radius_km  DOUBLE PRECISION DEFAULT 50
)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_req     RECORD;
  v_sent    INT;
  v_urgent  BOOLEAN;
BEGIN
  SELECT * INTO v_req
  FROM event_requests
  WHERE id = p_request_id;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'request_not_found');
  END IF;

  IF v_req.current_wave > 0 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'wave_already_started');
  END IF;

  -- Detectar evento urgente (< 6 horas desde ahora)
  v_urgent := (
    v_req.event_date::TIMESTAMP +
    COALESCE((v_req.event_time)::INTERVAL, INTERVAL '0')
    - NOW()
  ) < INTERVAL '6 hours';

  -- Guardar coordenadas y marcar wave 1 como enviada
  UPDATE event_requests
  SET event_lat     = p_event_lat,
      event_lng     = p_event_lng,
      radius_km     = p_radius_km,
      current_wave  = 1,
      wave1_sent_at = NOW()
  WHERE id = p_request_id;

  -- Recargar con los nuevos valores
  SELECT * INTO v_req FROM event_requests WHERE id = p_request_id;

  v_sent := _send_wave(v_req, 0, 5, v_urgent);

  UPDATE event_requests
  SET notified_count = notified_count + v_sent
  WHERE id = p_request_id;

  RETURN jsonb_build_object(
    'ok',       true,
    'wave',     1,
    'notified', v_sent,
    'urgent',   v_urgent
  );

EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$$;

GRANT EXECUTE ON FUNCTION public.notify_wave_1(UUID, DOUBLE PRECISION, DOUBLE PRECISION, DOUBLE PRECISION) TO authenticated;

-- ────────────────────────────────────────────────────────────────────────────
-- 5. process_notification_waves()
--    Ejecutado por pg_cron cada 2 minutos.
--    Procesa olas 2 y 3 para solicitudes que siguen abiertas.
-- ────────────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION public.process_notification_waves()
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_req      RECORD;
  v_sent     INT;
  v_urgent   BOOLEAN;
  v_total    INT := 0;
BEGIN
  FOR v_req IN
    SELECT * FROM event_requests
    WHERE status = 'open'
      AND expires_at > NOW()
      AND (
        -- Wave 1 enviada hace +2 min → enviar wave 2
        (current_wave = 1 AND wave1_sent_at < NOW() - INTERVAL '2 minutes')
        OR
        -- Wave 2 enviada hace +5 min → enviar wave 3
        (current_wave = 2 AND wave2_sent_at < NOW() - INTERVAL '5 minutes')
      )
    FOR UPDATE SKIP LOCKED
  LOOP
    v_urgent := (
      v_req.event_date::TIMESTAMP +
      COALESCE((v_req.event_time)::INTERVAL, INTERVAL '0')
      - NOW()
    ) < INTERVAL '6 hours';

    IF v_req.current_wave = 1 THEN
      -- Enviar wave 2: grupos 6-15 por score
      v_sent := _send_wave(v_req, 5, 10, v_urgent);
      UPDATE event_requests
      SET current_wave  = 2,
          wave2_sent_at = NOW(),
          notified_count = notified_count + v_sent
      WHERE id = v_req.id;

    ELSIF v_req.current_wave = 2 THEN
      -- Enviar wave 3: todos los restantes (sin límite)
      v_sent := _send_wave(v_req, 15, 1000, v_urgent);
      UPDATE event_requests
      SET current_wave  = 3,
          wave3_sent_at = NOW(),
          notified_count = notified_count + v_sent
      WHERE id = v_req.id;
    END IF;

    v_total := v_total + v_sent;
  END LOOP;

  RETURN jsonb_build_object('ok', true, 'processed', v_total);

EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$$;

-- Solo service_role puede ejecutar el cron
GRANT EXECUTE ON FUNCTION public.process_notification_waves() TO service_role;

-- ────────────────────────────────────────────────────────────────────────────
-- 6. get_request_competition()
--    RPC que el grupo llama al abrir una solicitud para ver cuántos
--    grupos la están viendo (cuántas notificaciones se enviaron).
-- ────────────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION public.get_request_competition(p_request_id UUID)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_count INT;
  v_wave  SMALLINT;
BEGIN
  SELECT notified_count, current_wave
  INTO v_count, v_wave
  FROM event_requests
  WHERE id = p_request_id;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_found');
  END IF;

  RETURN jsonb_build_object(
    'ok',            true,
    'viewers',       COALESCE(v_count, 0),
    'current_wave',  COALESCE(v_wave, 0)
  );

EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$$;

GRANT EXECUTE ON FUNCTION public.get_request_competition(UUID) TO authenticated;

-- ────────────────────────────────────────────────────────────────────────────
-- 7. pg_cron: procesar olas cada 2 minutos
-- ────────────────────────────────────────────────────────────────────────────

-- Eliminar el job si ya existe (ignora error si no existe)
DO $$
BEGIN
  PERFORM cron.unschedule('process-express-waves');
EXCEPTION WHEN OTHERS THEN
  NULL;
END;
$$;

SELECT cron.schedule(
  'process-express-waves',
  '*/2 * * * *',
  $$ SELECT public.process_notification_waves(); $$
);

SELECT '95_wave_notifications: olas de notificación + ranking + urgente ✅' AS status;
