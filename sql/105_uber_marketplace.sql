-- ════════════════════════════════════════════════════════════════════════════
-- 105_uber_marketplace.sql
-- Optimizaciones de marketplace en tiempo real (inspiradas en Uber)
--
-- 1. Surge Pricing      — multiplier dinámico por zona según demanda/oferta
-- 2. Smart Redistribution — wave timings mejorados + fix de offset con radio exp.
--                          0-5min → 5km · 5-10min → 10km · 10-15min → 25km
-- 3. Demand Heatmap     — tabla + trigger + RPC de consulta
-- 4. Demand Prediction  — predicción por patrones históricos + push a grupos
-- 5. Quick Matching     — wave 1 ajustada a top 3 para asignación más rápida
--
-- No modifica flujo de reservas, pagos ni billeteras.
-- Ejecutar DESPUÉS de 104_growth_optimizations.sql
-- ════════════════════════════════════════════════════════════════════════════


-- ────────────────────────────────────────────────────────────────────────────
-- PARTE 1: SURGE PRICING
-- ────────────────────────────────────────────────────────────────────────────
-- Calcula un multiplicador de demanda en tiempo real.
-- NO modifica precios ni pagos — devuelve información para que:
--   • el cliente vea un aviso de alta demanda antes de crear su solicitud
--   • el grupo conozca el nivel de demanda al recibir una solicitud
--   • el sistema registre el surge en la solicitud para análisis
--
-- Fórmula:
--   ratio      = solicitudes_activas / grupos_disponibles  (en zona ≤25km)
--   multiplier = 1.0 | 1.2 | 1.5 | 1.7 | 2.0
-- ────────────────────────────────────────────────────────────────────────────

ALTER TABLE public.event_requests
  ADD COLUMN IF NOT EXISTS surge_multiplier NUMERIC(4,2) DEFAULT 1.0;

CREATE OR REPLACE FUNCTION public.get_surge_info(
  p_lat   DOUBLE PRECISION,
  p_lng   DOUBLE PRECISION,
  p_genre TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_active_requests INT;
  v_available_groups INT;
  v_ratio            NUMERIC;
  v_multiplier       NUMERIC(4,2);
  v_demand_level     TEXT;
  v_message          TEXT;
BEGIN
  -- Solicitudes express abiertas en la zona (radio 25 km)
  SELECT COUNT(*) INTO v_active_requests
  FROM public.event_requests er
  WHERE er.status     = 'open'
    AND er.expires_at > NOW()
    AND (p_genre IS NULL OR er.genre = p_genre)
    AND (
      er.event_lat IS NULL
      OR haversine_km(er.event_lat, er.event_lng, p_lat, p_lng) <= 25
    );

  -- Grupos disponibles en la zona (radio 25 km)
  SELECT COUNT(*) INTO v_available_groups
  FROM public.groups g
  LEFT JOIN public.group_locations gl ON gl.group_id = g.id
  WHERE g.is_active   = TRUE
    AND COALESCE(g.availability, 'available') = 'available'
    AND (p_genre IS NULL OR g.genre = p_genre)
    AND (
      gl.lat IS NULL
      OR haversine_km(gl.lat, gl.lng, p_lat, p_lng) <= 25
    );

  -- Calcular ratio y multiplicador
  IF v_available_groups = 0 THEN
    v_ratio := 3.0;
  ELSE
    v_ratio := v_active_requests::NUMERIC / v_available_groups;
  END IF;

  v_multiplier := CASE
    WHEN v_ratio <  0.5 THEN 1.00
    WHEN v_ratio <  1.0 THEN 1.20
    WHEN v_ratio <  1.5 THEN 1.50
    WHEN v_ratio <  2.5 THEN 1.70
    ELSE 2.00
  END;

  v_demand_level := CASE
    WHEN v_multiplier = 1.0 THEN 'normal'
    WHEN v_multiplier = 1.2 THEN 'moderate'
    WHEN v_multiplier = 1.5 THEN 'high'
    WHEN v_multiplier = 1.7 THEN 'very_high'
    ELSE 'extreme'
  END;

  -- Mensaje para mostrar al cliente (solo si hay demanda elevada)
  v_message := CASE
    WHEN v_multiplier >= 1.5
      THEN 'La demanda es alta en tu zona. Los grupos pueden cotizar precios más elevados esta noche.'
    WHEN v_multiplier >= 1.2
      THEN 'Hay varias solicitudes activas en tu zona. Te recomendamos reservar pronto.'
    ELSE NULL
  END;

  RETURN jsonb_build_object(
    'ok',               true,
    'surge_multiplier', v_multiplier,
    'demand_level',     v_demand_level,
    'active_requests',  v_active_requests,
    'available_groups', v_available_groups,
    'message',          v_message       -- NULL = no mostrar aviso al cliente
  );

EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$$;

GRANT EXECUTE ON FUNCTION public.get_surge_info(DOUBLE PRECISION, DOUBLE PRECISION, TEXT) TO authenticated, anon;

-- Guardar surge en la solicitud al momento de crearla
-- El frontend llama get_surge_info() ANTES de INSERT event_requests,
-- y pasa el surge_multiplier resultante en el INSERT.


-- ────────────────────────────────────────────────────────────────────────────
-- PARTE 2 + 5: SMART REDISTRIBUTION + QUICK MATCHING
-- ────────────────────────────────────────────────────────────────────────────
-- Cambios respecto a 103:
--   • Wave 1 → top 3 grupos (antes top 5) para matching más rápido
--   • Wave 2 → +5 min (antes +2 min), radio 10 km
--   • Wave 3 → +10 min (antes +5 min), radio 25 km
--   • Fix: cuando use_radius_expansion = TRUE, waves 2 y 3 usan offset 0
--     (el NOT EXISTS en _send_wave() evita re-notificar correctamente)
-- ────────────────────────────────────────────────────────────────────────────

-- ── notify_wave_1(): top 3 en lugar de top 5 ────────────────────────────

CREATE OR REPLACE FUNCTION public.notify_wave_1(
  p_request_id           UUID,
  p_event_lat            DOUBLE PRECISION DEFAULT NULL,
  p_event_lng            DOUBLE PRECISION DEFAULT NULL,
  p_radius_km            DOUBLE PRECISION DEFAULT 50,
  p_use_radius_expansion BOOLEAN          DEFAULT FALSE
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_req            RECORD;
  v_sent           INT;
  v_urgent         BOOLEAN;
  v_initial_radius DOUBLE PRECISION;
BEGIN
  SELECT * INTO v_req FROM public.event_requests WHERE id = p_request_id;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'request_not_found');
  END IF;

  IF v_req.current_wave > 0 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'wave_already_started');
  END IF;

  v_initial_radius := CASE WHEN p_use_radius_expansion THEN 5.0 ELSE p_radius_km END;

  v_urgent := (
    v_req.event_date::TIMESTAMP +
    COALESCE((v_req.event_time)::INTERVAL, INTERVAL '0') - NOW()
  ) < INTERVAL '6 hours';

  UPDATE public.event_requests
  SET event_lat            = p_event_lat,
      event_lng            = p_event_lng,
      radius_km            = v_initial_radius,
      use_radius_expansion = p_use_radius_expansion,
      current_wave         = 1,
      wave1_sent_at        = NOW()
  WHERE id = p_request_id;

  SELECT * INTO v_req FROM public.event_requests WHERE id = p_request_id;

  -- Top 3 (quick matching) — suficiente para primera respuesta rápida
  v_sent := _send_wave(v_req, 0, 3, v_urgent);

  UPDATE public.event_requests
  SET notified_count = notified_count + v_sent
  WHERE id = p_request_id;

  RETURN jsonb_build_object(
    'ok',                   true,
    'wave',                 1,
    'notified',             v_sent,
    'urgent',               v_urgent,
    'initial_radius_km',    v_initial_radius,
    'use_radius_expansion', p_use_radius_expansion
  );

EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$$;

GRANT EXECUTE ON FUNCTION public.notify_wave_1(UUID, DOUBLE PRECISION, DOUBLE PRECISION, DOUBLE PRECISION, BOOLEAN) TO authenticated;

-- ── process_notification_waves(): nuevos tiempos + fix de offset ─────────

CREATE OR REPLACE FUNCTION public.process_notification_waves()
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_req     RECORD;
  v_sent    INT;
  v_urgent  BOOLEAN;
  v_total   INT := 0;
  v_use_exp BOOLEAN;
BEGIN
  FOR v_req IN
    SELECT * FROM public.event_requests
    WHERE status = 'open'
      AND expires_at > NOW()
      AND (
        -- Wave 2: +5 minutos desde wave 1  (antes era +2 min)
        (current_wave = 1 AND wave1_sent_at < NOW() - INTERVAL '5 minutes')
        OR
        -- Wave 3: +10 minutos desde wave 2 (antes era +5 min)
        (current_wave = 2 AND wave2_sent_at < NOW() - INTERVAL '10 minutes')
      )
    FOR UPDATE SKIP LOCKED
  LOOP
    v_urgent := (
      v_req.event_date::TIMESTAMP +
      COALESCE((v_req.event_time)::INTERVAL, INTERVAL '0') - NOW()
    ) < INTERVAL '6 hours';

    v_use_exp := COALESCE(v_req.use_radius_expansion, FALSE);

    IF v_req.current_wave = 1 THEN
      -- Expandir radio a 10 km si está habilitado
      IF v_use_exp THEN
        UPDATE public.event_requests SET radius_km = 10 WHERE id = v_req.id;
        SELECT * INTO v_req FROM public.event_requests WHERE id = v_req.id;
      END IF;

      -- Con expansión: offset 0 (pool cambió, NOT EXISTS evita re-notificar)
      -- Sin expansión: offset 3 (grupos 4-15 por score)
      v_sent := _send_wave(v_req,
                  CASE WHEN v_use_exp THEN 0 ELSE 3  END,
                  12,
                  v_urgent);

      UPDATE public.event_requests
      SET current_wave   = 2,
          wave2_sent_at  = NOW(),
          notified_count = notified_count + v_sent
      WHERE id = v_req.id;

    ELSIF v_req.current_wave = 2 THEN
      -- Expandir radio a 25 km si está habilitado (antes era 20 km)
      IF v_use_exp THEN
        UPDATE public.event_requests SET radius_km = 25 WHERE id = v_req.id;
        SELECT * INTO v_req FROM public.event_requests WHERE id = v_req.id;
      END IF;

      -- Con expansión: offset 0 (todos los nuevos en el radio ampliado)
      -- Sin expansión: offset 15 (grupos 16+ por score)
      v_sent := _send_wave(v_req,
                  CASE WHEN v_use_exp THEN 0 ELSE 15 END,
                  1000,
                  v_urgent);

      UPDATE public.event_requests
      SET current_wave   = 3,
          wave3_sent_at  = NOW(),
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

GRANT EXECUTE ON FUNCTION public.process_notification_waves() TO service_role;


-- ────────────────────────────────────────────────────────────────────────────
-- PARTE 3: DEMAND HEATMAP
-- ────────────────────────────────────────────────────────────────────────────
-- Registra cada solicitud express en un heatmap liviano para:
--   • detectar zonas/horas de alta demanda
--   • entrenar predicciones de picos
--   • mostrar al admin un mapa de calor de actividad
-- ────────────────────────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS public.demand_heatmap (
  id          UUID         PRIMARY KEY DEFAULT gen_random_uuid(),
  lat         DOUBLE PRECISION,
  lng         DOUBLE PRECISION,
  city        TEXT,
  genre       TEXT,
  hour_of_day SMALLINT     NOT NULL,   -- 0-23 (hora local GDL = UTC-6)
  day_of_week SMALLINT     NOT NULL,   -- 0=Dom, 1=Lun, …, 6=Sáb
  created_at  TIMESTAMPTZ  DEFAULT now()
);

ALTER TABLE public.demand_heatmap ENABLE ROW LEVEL SECURITY;

-- Solo admin ve el heatmap
DROP POLICY IF EXISTS "heatmap_admin_read" ON public.demand_heatmap;
CREATE POLICY "heatmap_admin_read" ON public.demand_heatmap
  FOR SELECT TO authenticated
  USING (EXISTS (
    SELECT 1 FROM public.profiles WHERE id = auth.uid() AND role = 'admin'
  ));

CREATE INDEX IF NOT EXISTS idx_heatmap_zone
  ON public.demand_heatmap(day_of_week, hour_of_day, genre);

CREATE INDEX IF NOT EXISTS idx_heatmap_coords
  ON public.demand_heatmap(lat, lng)
  WHERE lat IS NOT NULL;

-- ── Trigger: registrar en heatmap al crear una solicitud express ──────────

CREATE OR REPLACE FUNCTION public._trg_record_demand_heatmap()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  INSERT INTO public.demand_heatmap (lat, lng, city, genre, hour_of_day, day_of_week)
  VALUES (
    NEW.event_lat,
    NEW.event_lng,
    NEW.location_city,
    NEW.genre,
    -- Hora local GDL (UTC-6)
    EXTRACT(HOUR FROM (NEW.created_at AT TIME ZONE 'America/Mexico_City'))::SMALLINT,
    EXTRACT(DOW  FROM (NEW.created_at AT TIME ZONE 'America/Mexico_City'))::SMALLINT
  );
  RETURN NEW;
EXCEPTION WHEN OTHERS THEN
  RETURN NEW;  -- No bloquear el INSERT si el heatmap falla
END;
$$;

DROP TRIGGER IF EXISTS trg_record_demand_heatmap ON public.event_requests;
CREATE TRIGGER trg_record_demand_heatmap
  AFTER INSERT ON public.event_requests
  FOR EACH ROW EXECUTE FUNCTION public._trg_record_demand_heatmap();

-- ── RPC: consultar heatmap por zona (admin / análisis) ───────────────────

CREATE OR REPLACE FUNCTION public.get_demand_heatmap(
  p_lat        DOUBLE PRECISION DEFAULT NULL,
  p_lng        DOUBLE PRECISION DEFAULT NULL,
  p_radius_km  DOUBLE PRECISION DEFAULT 25,
  p_hours_back INT              DEFAULT 168    -- última semana por defecto
)
RETURNS TABLE (
  lat         DOUBLE PRECISION,
  lng         DOUBLE PRECISION,
  city        TEXT,
  genre       TEXT,
  hour_of_day SMALLINT,
  day_of_week SMALLINT,
  request_count BIGINT
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  RETURN QUERY
  SELECT
    ROUND(h.lat::NUMERIC, 3)::DOUBLE PRECISION   AS lat,
    ROUND(h.lng::NUMERIC, 3)::DOUBLE PRECISION   AS lng,
    h.city,
    h.genre,
    h.hour_of_day,
    h.day_of_week,
    COUNT(*)                                     AS request_count
  FROM public.demand_heatmap h
  WHERE h.created_at >= NOW() - (p_hours_back || ' hours')::INTERVAL
    AND (
      p_lat IS NULL OR h.lat IS NULL
      OR haversine_km(h.lat, h.lng, p_lat, p_lng) <= p_radius_km
    )
  GROUP BY
    ROUND(h.lat::NUMERIC, 3),
    ROUND(h.lng::NUMERIC, 3),
    h.city, h.genre, h.hour_of_day, h.day_of_week
  ORDER BY request_count DESC;
END;
$$;

GRANT EXECUTE ON FUNCTION public.get_demand_heatmap(DOUBLE PRECISION, DOUBLE PRECISION, DOUBLE PRECISION, INT) TO authenticated;


-- ────────────────────────────────────────────────────────────────────────────
-- PARTE 4: DEMAND PREDICTION
-- ────────────────────────────────────────────────────────────────────────────
-- Analiza el heatmap histórico para detectar picos recurrentes y notificar
-- a los grupos cercanos antes de que lleguen.
--
-- Lógica:
--   • Cada hora revisa las próximas 3 horas
--   • Para cada franja (DOW + hora), cuenta solicitudes en las últimas 4 semanas
--   • Si hay 3+ solicitudes históricas en esa franja → "pico esperado"
--   • Notifica a grupos disponibles en esa zona para que se activen
-- ────────────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION public.send_peak_demand_predictions()
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_lookahead   INTERVAL := INTERVAL '3 hours';
  v_check_time  TIMESTAMPTZ;
  v_dow         SMALLINT;
  v_hour        SMALLINT;
  v_genre       TEXT;
  v_lat         DOUBLE PRECISION;
  v_lng         DOUBLE PRECISION;
  v_hist_count  INT;
  v_group       RECORD;
  v_sent        INT := 0;

  -- Zonas con actividad histórica (lat/lng redondeadas a ~3km)
  v_zone        RECORD;
BEGIN
  -- Revisar cada hora futura dentro de v_lookahead
  FOR v_check_time IN
    SELECT generate_series(
      date_trunc('hour', NOW()) + INTERVAL '1 hour',
      date_trunc('hour', NOW()) + v_lookahead,
      INTERVAL '1 hour'
    )
  LOOP
    v_dow  := EXTRACT(DOW  FROM (v_check_time AT TIME ZONE 'America/Mexico_City'))::SMALLINT;
    v_hour := EXTRACT(HOUR FROM (v_check_time AT TIME ZONE 'America/Mexico_City'))::SMALLINT;

    -- Encontrar zonas y géneros con patrón histórico en esta franja
    FOR v_zone IN
      SELECT
        ROUND(lat::NUMERIC, 2) AS zone_lat,
        ROUND(lng::NUMERIC, 2) AS zone_lng,
        genre,
        COUNT(*) AS hist_count
      FROM public.demand_heatmap
      WHERE day_of_week = v_dow
        AND hour_of_day = v_hour
        AND created_at >= NOW() - INTERVAL '28 days'   -- últimas 4 semanas
        AND lat IS NOT NULL
      GROUP BY ROUND(lat::NUMERIC, 2), ROUND(lng::NUMERIC, 2), genre
      HAVING COUNT(*) >= 3
    LOOP
      -- Notificar a grupos disponibles en esa zona que no estén ya activados
      FOR v_group IN
        SELECT g.id, g.owner_id, g.genre
        FROM public.groups g
        LEFT JOIN public.group_locations gl ON gl.group_id = g.id
        WHERE g.is_active   = TRUE
          AND g.genre       = v_zone.genre
          AND COALESCE(g.availability, 'available') != 'offline'
          AND COALESCE(g.available_now, FALSE) = FALSE
          AND (
            gl.lat IS NULL
            OR haversine_km(gl.lat, gl.lng, v_zone.zone_lat::DOUBLE PRECISION, v_zone.zone_lng::DOUBLE PRECISION) <= 20
          )
          -- Anti-spam: no más de una predicción por grupo en 12 horas
          AND NOT EXISTS (
            SELECT 1 FROM public.notifications n
            WHERE n.user_id = g.owner_id
              AND n.data->>'notif_key' = 'peak_prediction'
              AND n.created_at > NOW() - INTERVAL '12 hours'
          )
      LOOP
        INSERT INTO public.notifications (user_id, type, title, body, data)
        VALUES (
          v_group.owner_id,
          'system',
          '📈 Se esperan muchas solicitudes esta noche',
          'Basándonos en la actividad histórica, se esperan solicitudes de '
          || v_zone.genre || ' en tu zona alrededor de las '
          || LPAD(v_hour::TEXT, 2, '0') || ':00h. '
          || '¡Activa "Disponible ahora" para recibir eventos con prioridad! 🚀',
          jsonb_build_object(
            'screen',       'Dashboard',
            'action',       'toggle_available',
            'notif_key',    'peak_prediction',
            'peak_hour',    v_hour,
            'peak_genre',   v_zone.genre
          )
        );
        v_sent := v_sent + 1;
      END LOOP;

    END LOOP;
  END LOOP;

  RETURN jsonb_build_object('ok', true, 'sent', v_sent);

EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$$;

GRANT EXECUTE ON FUNCTION public.send_peak_demand_predictions() TO service_role;

-- ── RPC pública: surge + predicción para una ubicación ──────────────────
-- Combina get_surge_info() + predicción para los próximos 120 min.
-- El frontend lo llama desde el mapa antes de crear una solicitud.

CREATE OR REPLACE FUNCTION public.get_location_demand_snapshot(
  p_lat   DOUBLE PRECISION,
  p_lng   DOUBLE PRECISION,
  p_genre TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_surge       JSONB;
  v_upcoming    INT;
  v_peak_hours  JSONB;
BEGIN
  -- Surge actual
  v_surge := public.get_surge_info(p_lat, p_lng, p_genre);

  -- Picos esperados en las próximas 2 horas (basado en heatmap)
  SELECT COUNT(*) INTO v_upcoming
  FROM public.demand_heatmap h
  WHERE h.day_of_week = EXTRACT(DOW FROM (NOW() AT TIME ZONE 'America/Mexico_City'))::SMALLINT
    AND h.hour_of_day IN (
      EXTRACT(HOUR FROM (NOW() AT TIME ZONE 'America/Mexico_City'))::SMALLINT,
      MOD(EXTRACT(HOUR FROM (NOW() AT TIME ZONE 'America/Mexico_City'))::INT + 1, 24)::SMALLINT
    )
    AND h.created_at >= NOW() - INTERVAL '28 days'
    AND (p_genre IS NULL OR h.genre = p_genre)
    AND (
      h.lat IS NULL
      OR haversine_km(h.lat, h.lng, p_lat, p_lng) <= 20
    );

  RETURN jsonb_build_object(
    'surge',            v_surge,
    'historical_count_2h', v_upcoming,
    'is_peak_time',     v_upcoming >= 3
  );

EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$$;

GRANT EXECUTE ON FUNCTION public.get_location_demand_snapshot(DOUBLE PRECISION, DOUBLE PRECISION, TEXT) TO authenticated, anon;


-- ────────────────────────────────────────────────────────────────────────────
-- CRONS
-- ────────────────────────────────────────────────────────────────────────────

-- Predicción de demanda: cada hora (el mejor momento para avisar con anticipación)
DO $$ BEGIN PERFORM cron.unschedule('peak-demand-predictions'); EXCEPTION WHEN OTHERS THEN NULL; END; $$;
SELECT cron.schedule('peak-demand-predictions', '5 * * * *', $$ SELECT public.send_peak_demand_predictions(); $$);

-- Limpiar heatmap de más de 90 días (mantener solo datos recientes)
DO $$ BEGIN PERFORM cron.unschedule('cleanup-heatmap'); EXCEPTION WHEN OTHERS THEN NULL; END; $$;
SELECT cron.schedule(
  'cleanup-heatmap',
  '0 3 * * 0',     -- domingos a las 3am
  $$ DELETE FROM public.demand_heatmap WHERE created_at < NOW() - INTERVAL '90 days'; $$
);


-- ════════════════════════════════════════════════════════════════════════════
-- RESUMEN DE CAMBIOS RESPECTO A 103/104
-- ════════════════════════════════════════════════════════════════════════════
-- notify_wave_1()          → wave 1 envía a top 3 (antes 5)
-- process_notification_waves() → wave 2 a +5min (antes +2min)
--                               wave 3 a +10min (antes +5min)
--                               wave 3 radius → 25km (antes 20km)
--                               fix: offset=0 cuando use_radius_expansion=TRUE
-- ════════════════════════════════════════════════════════════════════════════

-- ════════════════════════════════════════════════════════════════════════════
-- USO DESDE EL FRONTEND
-- ════════════════════════════════════════════════════════════════════════════
-- 1. Antes de mostrar formulario de solicitud express:
--    supabase.rpc('get_location_demand_snapshot', { p_lat, p_lng, p_genre })
--    → { surge: { surge_multiplier, demand_level, message }, is_peak_time }
--    Si message != null → mostrar banner de alta demanda
--
-- 2. Al crear la solicitud: incluir surge_multiplier en el INSERT
--    { ..., surge_multiplier: snapshot.surge.surge_multiplier }
--
-- 3. Al grupo: mostrar surge_multiplier en la tarjeta de la solicitud:
--    "Alta demanda (x1.5) — considera cotizar acorde"
-- ════════════════════════════════════════════════════════════════════════════

SELECT '105_uber_marketplace: surge + redistribución + heatmap + predicción + quick-match ✅' AS status;
