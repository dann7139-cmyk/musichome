-- ════════════════════════════════════════════════════════════════════════════
-- 114_platform_protection.sql
-- Protección de plataforma: activos de datos exclusivos, historial de clientes,
-- recomendaciones personalizadas, brechas de mercado y analytics admin.
--
-- ESTADO PREVIO (ya implementado — NO se reimplementa):
--   93/104 → ranking_score, badges, recalculate_group_reputation()
--   105    → demand_heatmap (coordenadas + hora + género)
--   106    → get_client_past_groups(), get_similar_groups(), track_group_view()
--   107    → calculate_group_reliability(), get_group_trust_profile()
--   109    → get_city_stats(), get_platform_demand_map()
--   113    → referral_code, get_discovery_sections()
--
-- LO QUE IMPLEMENTA ESTE ARCHIVO:
--   1. platform_analytics_snapshots — snapshots diarios de métricas agregadas
--      take_platform_snapshot()     — agrega y almacena métricas del día
--      Cron diario 3 AM
--   2. recent_completions en groups — columna actualizada diariamente
--      update_recent_completions()  — cron diario para mostrar "X eventos/mes"
--   3. get_client_preferences()     — historial + preferencias del cliente
--   4. get_personalized_recommendations() — recomendaciones usando datos reales
--   5. get_platform_gaps()          — ciudades/géneros con demanda > oferta
--   6. get_admin_platform_stats()   — panel de control admin completo
--
-- No modifica el flujo de reservas ni pagos.
-- Ejecutar DESPUÉS de 113_network_effects.sql
-- ════════════════════════════════════════════════════════════════════════════


-- ── 1. ACTIVOS DE DATOS: platform_analytics_snapshots ────────────────────────
-- Snapshot diario de métricas por ciudad y género.
-- Se acumula con el tiempo → ventaja competitiva que no existe fuera de la plataforma.

CREATE TABLE IF NOT EXISTS public.platform_analytics_snapshots (
  id               UUID         PRIMARY KEY DEFAULT gen_random_uuid(),
  snapshot_date    DATE         NOT NULL DEFAULT CURRENT_DATE,
  city             TEXT         NOT NULL,
  genre            TEXT,                          -- NULL = agregado de todos los géneros
  event_requests   INT          NOT NULL DEFAULT 0,
  reservations_new INT          NOT NULL DEFAULT 0,
  completions      INT          NOT NULL DEFAULT 0,
  cancellations    INT          NOT NULL DEFAULT 0,
  active_groups    INT          NOT NULL DEFAULT 0,
  avg_response_min NUMERIC(8,2),                  -- minutos promedio de respuesta
  acceptance_rate  NUMERIC(5,4),                  -- 0–1
  peak_hour        SMALLINT,                      -- hora con más solicitudes (0–23)
  total_revenue    NUMERIC(14,2) NOT NULL DEFAULT 0,
  created_at       TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
  UNIQUE (snapshot_date, city, genre)
);

CREATE INDEX IF NOT EXISTS idx_pas_date       ON public.platform_analytics_snapshots(snapshot_date DESC);
CREATE INDEX IF NOT EXISTS idx_pas_city       ON public.platform_analytics_snapshots(city);
CREATE INDEX IF NOT EXISTS idx_pas_genre      ON public.platform_analytics_snapshots(genre);

ALTER TABLE public.platform_analytics_snapshots ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "pas_admin_all"    ON public.platform_analytics_snapshots;
DROP POLICY IF EXISTS "pas_service_all" ON public.platform_analytics_snapshots;

CREATE POLICY "pas_admin_all" ON public.platform_analytics_snapshots
  FOR ALL TO authenticated
  USING (EXISTS (SELECT 1 FROM public.profiles WHERE id = auth.uid() AND role = 'admin'));

CREATE POLICY "pas_service_all" ON public.platform_analytics_snapshots
  FOR ALL TO service_role USING (true);


-- ── take_platform_snapshot() — agrega métricas del día anterior ──────────────

CREATE OR REPLACE FUNCTION public.take_platform_snapshot()
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_yesterday  DATE := CURRENT_DATE - 1;
  v_city_row   RECORD;
  v_genre_row  RECORD;
  v_rows       INT := 0;
BEGIN
  -- Iterar por ciudad × género con actividad en los últimos 7 días (ventana móvil)
  FOR v_city_row IN
    SELECT DISTINCT LOWER(TRIM(location_city)) AS city
    FROM public.event_requests
    WHERE created_at >= NOW() - INTERVAL '7 days'
      AND location_city IS NOT NULL
  LOOP
    FOR v_genre_row IN
      SELECT DISTINCT LOWER(TRIM(genre)) AS genre
      FROM public.event_requests
      WHERE LOWER(TRIM(location_city)) = v_city_row.city
        AND created_at >= NOW() - INTERVAL '7 days'
        AND genre IS NOT NULL
    LOOP
      INSERT INTO public.platform_analytics_snapshots (
        snapshot_date, city, genre,
        event_requests, reservations_new, completions, cancellations,
        active_groups, avg_response_min, acceptance_rate, peak_hour, total_revenue
      )
      SELECT
        v_yesterday,
        v_city_row.city,
        v_genre_row.genre,
        -- Solicitudes creadas ayer en esta ciudad/género
        (SELECT COUNT(*) FROM public.event_requests
         WHERE LOWER(TRIM(location_city)) = v_city_row.city
           AND LOWER(TRIM(genre)) = v_genre_row.genre
           AND created_at::DATE = v_yesterday),
        -- Reservas nuevas ayer
        (SELECT COUNT(*) FROM public.reservations r
         JOIN public.groups g ON g.id = r.group_id
         WHERE LOWER(TRIM(g.city)) = v_city_row.city
           AND LOWER(TRIM(g.genre)) = v_genre_row.genre
           AND r.created_at::DATE = v_yesterday),
        -- Completadas ayer
        (SELECT COUNT(*) FROM public.reservations r
         JOIN public.groups g ON g.id = r.group_id
         WHERE LOWER(TRIM(g.city)) = v_city_row.city
           AND LOWER(TRIM(g.genre)) = v_genre_row.genre
           AND r.status = 'completed'
           AND r.event_date = v_yesterday),
        -- Canceladas ayer
        (SELECT COUNT(*) FROM public.reservations r
         JOIN public.groups g ON g.id = r.group_id
         WHERE LOWER(TRIM(g.city)) = v_city_row.city
           AND LOWER(TRIM(g.genre)) = v_genre_row.genre
           AND r.status = 'cancelled'
           AND r.event_date = v_yesterday),
        -- Grupos activos en ciudad/género
        (SELECT COUNT(*) FROM public.groups
         WHERE LOWER(TRIM(city)) = v_city_row.city
           AND LOWER(TRIM(genre)) = v_genre_row.genre
           AND is_active = TRUE),
        -- Tiempo promedio de respuesta (minutos) — solicitudes de ayer
        (SELECT ROUND(AVG(EXTRACT(EPOCH FROM (pl.proposed_at - er.created_at)) / 60)::NUMERIC, 2)
         FROM public.proposal_logs pl
         JOIN public.event_requests er ON er.id = pl.request_id
         JOIN public.groups g ON g.id = pl.group_id
         WHERE LOWER(TRIM(g.city)) = v_city_row.city
           AND LOWER(TRIM(er.genre)) = v_genre_row.genre
           AND pl.proposed_at::DATE = v_yesterday),
        -- Tasa de aceptación (solicitudes con status accepted/completed / total)
        (SELECT CASE WHEN COUNT(*) = 0 THEN NULL
                     ELSE COUNT(*) FILTER (WHERE status IN ('accepted','completed'))
                          ::NUMERIC / COUNT(*)
                END
         FROM public.event_requests
         WHERE LOWER(TRIM(location_city)) = v_city_row.city
           AND LOWER(TRIM(genre)) = v_genre_row.genre
           AND created_at::DATE = v_yesterday),
        -- Hora pico (más solicitudes en esa hora)
        (SELECT EXTRACT(HOUR FROM created_at)::SMALLINT
         FROM public.event_requests
         WHERE LOWER(TRIM(location_city)) = v_city_row.city
           AND LOWER(TRIM(genre)) = v_genre_row.genre
           AND created_at::DATE = v_yesterday
         GROUP BY 1 ORDER BY COUNT(*) DESC LIMIT 1),
        -- Ingresos totales (reservas completadas ayer)
        (SELECT COALESCE(SUM(r.total_price), 0)
         FROM public.reservations r
         JOIN public.groups g ON g.id = r.group_id
         WHERE LOWER(TRIM(g.city)) = v_city_row.city
           AND LOWER(TRIM(g.genre)) = v_genre_row.genre
           AND r.status = 'completed'
           AND r.event_date = v_yesterday)
      ON CONFLICT (snapshot_date, city, genre) DO UPDATE
        SET event_requests   = EXCLUDED.event_requests,
            reservations_new = EXCLUDED.reservations_new,
            completions      = EXCLUDED.completions,
            cancellations    = EXCLUDED.cancellations,
            active_groups    = EXCLUDED.active_groups,
            avg_response_min = EXCLUDED.avg_response_min,
            acceptance_rate  = EXCLUDED.acceptance_rate,
            peak_hour        = EXCLUDED.peak_hour,
            total_revenue    = EXCLUDED.total_revenue;

      v_rows := v_rows + 1;
    END LOOP;
  END LOOP;

  RETURN jsonb_build_object('ok', true, 'snapshot_date', v_yesterday, 'rows_upserted', v_rows);

EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$$;

GRANT EXECUTE ON FUNCTION public.take_platform_snapshot() TO service_role;


-- ── 2. recent_completions en groups ──────────────────────────────────────────
-- Columna que guarda eventos completados en los últimos 30 días.
-- Se actualiza diariamente por cron → el frontend puede leerla sin joins costosos.
-- Alimenta el indicador "X eventos este mes" en las tarjetas de grupo.

ALTER TABLE public.groups
  ADD COLUMN IF NOT EXISTS recent_completions INT NOT NULL DEFAULT 0;

COMMENT ON COLUMN public.groups.recent_completions IS
  'Reservas completadas en los últimos 30 días. Actualizado diariamente por cron.';

CREATE OR REPLACE FUNCTION public.update_recent_completions()
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_updated INT;
BEGIN
  UPDATE public.groups g
  SET recent_completions = (
    SELECT COUNT(*)
    FROM public.reservations r
    WHERE r.group_id   = g.id
      AND r.status     = 'completed'
      AND r.event_date >= CURRENT_DATE - INTERVAL '30 days'
  )
  WHERE g.is_active = TRUE;

  GET DIAGNOSTICS v_updated = ROW_COUNT;

  RETURN jsonb_build_object('ok', true, 'groups_updated', v_updated);

EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$$;

GRANT EXECUTE ON FUNCTION public.update_recent_completions() TO service_role;

-- Backfill inicial
SELECT public.update_recent_completions();


-- ── 3. get_client_preferences() — historial y preferencias del cliente ────────
-- Analiza todas las reservas y solicitudes del cliente autenticado.
-- Devuelve: géneros favoritos, ciudades frecuentes, gasto promedio, hora típica.
-- Alimenta las recomendaciones personalizadas y la UX de la pantalla de inicio.

CREATE OR REPLACE FUNCTION public.get_client_preferences()
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid         UUID := auth.uid();
  v_genres      JSONB;
  v_cities      JSONB;
  v_avg_spend   NUMERIC;
  v_peak_hour   SMALLINT;
  v_total_events INT;
BEGIN
  -- Géneros más contratados (top 3)
  SELECT jsonb_agg(genre ORDER BY cnt DESC)
  INTO v_genres
  FROM (
    SELECT COALESCE(g.genre, er.genre) AS genre, COUNT(*) AS cnt
    FROM public.reservations r
    LEFT JOIN public.groups g ON g.id = r.group_id
    LEFT JOIN public.event_requests er ON er.id = r.event_request_id
    WHERE r.client_id = v_uid
      AND r.status IN ('completed', 'confirmed', 'deposit_paid')
      AND COALESCE(g.genre, er.genre) IS NOT NULL
    GROUP BY 1
    ORDER BY cnt DESC
    LIMIT 3
  ) t;

  -- Ciudades donde más contrata
  SELECT jsonb_agg(city ORDER BY cnt DESC)
  INTO v_cities
  FROM (
    SELECT COALESCE(g.city, er.location_city) AS city, COUNT(*) AS cnt
    FROM public.reservations r
    LEFT JOIN public.groups g ON g.id = r.group_id
    LEFT JOIN public.event_requests er ON er.id = r.event_request_id
    WHERE r.client_id = v_uid
      AND COALESCE(g.city, er.location_city) IS NOT NULL
    GROUP BY 1
    ORDER BY cnt DESC
    LIMIT 3
  ) t;

  -- Gasto promedio por evento
  SELECT ROUND(AVG(total_price)::NUMERIC, 0)
  INTO v_avg_spend
  FROM public.reservations
  WHERE client_id = v_uid
    AND status = 'completed'
    AND total_price > 0;

  -- Hora típica de eventos (moda)
  SELECT EXTRACT(HOUR FROM event_time::TIMETZ)::SMALLINT
  INTO v_peak_hour
  FROM public.reservations
  WHERE client_id  = v_uid
    AND event_time IS NOT NULL
  GROUP BY 1
  ORDER BY COUNT(*) DESC
  LIMIT 1;

  -- Total de eventos realizados
  SELECT COUNT(*) INTO v_total_events
  FROM public.reservations
  WHERE client_id = v_uid
    AND status = 'completed';

  RETURN jsonb_build_object(
    'ok',            true,
    'total_events',  v_total_events,
    'top_genres',    COALESCE(v_genres,  '[]'),
    'top_cities',    COALESCE(v_cities,  '[]'),
    'avg_spend',     COALESCE(v_avg_spend, 0),
    'typical_hour',  v_peak_hour
  );

EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$$;

GRANT EXECUTE ON FUNCTION public.get_client_preferences() TO authenticated;


-- ── 4. get_personalized_recommendations() — recomendaciones con datos reales ──
-- Combina historial del cliente (géneros/ciudades preferidas) +
-- performance real de grupos (ranking_score, reliability, recent_completions)
-- para devolver grupos rankeados con motivo de recomendación.

CREATE OR REPLACE FUNCTION public.get_personalized_recommendations(
  p_genre TEXT    DEFAULT NULL,  -- override del género si el cliente lo especifica
  p_city  TEXT    DEFAULT NULL,  -- override de ciudad
  p_limit INT     DEFAULT 10
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid      UUID := auth.uid();
  v_genre    TEXT;
  v_city     TEXT;
  v_results  JSONB;
BEGIN
  -- Resolver género preferido si no se especificó
  IF p_genre IS NULL THEN
    SELECT COALESCE(g.genre, er.genre)
    INTO v_genre
    FROM public.reservations r
    LEFT JOIN public.groups g  ON g.id = r.group_id
    LEFT JOIN public.event_requests er ON er.id = r.event_request_id
    WHERE r.client_id = v_uid
      AND r.status IN ('completed', 'confirmed', 'deposit_paid')
      AND COALESCE(g.genre, er.genre) IS NOT NULL
    GROUP BY 1
    ORDER BY COUNT(*) DESC
    LIMIT 1;
  ELSE
    v_genre := p_genre;
  END IF;

  -- Resolver ciudad preferida si no se especificó
  IF p_city IS NULL THEN
    SELECT COALESCE(g.city, er.location_city)
    INTO v_city
    FROM public.reservations r
    LEFT JOIN public.groups g  ON g.id = r.group_id
    LEFT JOIN public.event_requests er ON er.id = r.event_request_id
    WHERE r.client_id = v_uid
    GROUP BY 1
    ORDER BY COUNT(*) DESC
    LIMIT 1;
  ELSE
    v_city := p_city;
  END IF;

  -- Score de recomendación:
  --   genre_match   × 40 → +40 si coincide el género
  --   city_match    × 20 → +20 si coincide la ciudad
  --   ranking_score × 20 → normalizado 0–5 → 0–20
  --   reliability   ×  10 → normalizado 0–100 → 0–10
  --   recent_events × 10 → min(completions,10)/10 × 10
  --   not_booked_before × 5 → +5 si el cliente nunca lo contrató (descubrimiento)

  SELECT jsonb_agg(row_to_json(r) ORDER BY r.rec_score DESC)
  INTO v_results
  FROM (
    SELECT
      g.id, g.name, g.genre, g.city, g.profile_image, g.is_verified,
      g.average_rating, g.total_reviews, g.ranking_score, g.reliability_score,
      g.recent_completions, g.badges, g.available_now, g.price_from, g.nivel,
      -- Motivo principal de recomendación
      CASE
        WHEN LOWER(TRIM(g.genre)) = LOWER(TRIM(v_genre))
         AND LOWER(TRIM(g.city))  = LOWER(TRIM(v_city))  THEN 'Tu género favorito cerca de ti'
        WHEN LOWER(TRIM(g.genre)) = LOWER(TRIM(v_genre))  THEN 'Basado en tu historial'
        WHEN LOWER(TRIM(g.city))  = LOWER(TRIM(v_city))   THEN 'Popular en tu ciudad'
        WHEN g.recent_completions  >= 5                    THEN 'Muy activo este mes'
        ELSE 'Recomendado para ti'
      END AS rec_reason,
      -- Score numérico
      ROUND((
        CASE WHEN LOWER(TRIM(g.genre)) = LOWER(TRIM(v_genre)) THEN 40 ELSE 0 END
        + CASE WHEN LOWER(TRIM(g.city))  = LOWER(TRIM(v_city))  THEN 20 ELSE 0 END
        + (LEAST(COALESCE(g.ranking_score, 0), 5) / 5.0 * 20)
        + (LEAST(COALESCE(g.reliability_score, 0), 100) / 100.0 * 10)
        + (LEAST(COALESCE(g.recent_completions, 0), 10) / 10.0 * 10)
        + CASE WHEN NOT EXISTS (
                 SELECT 1 FROM public.reservations r2
                 WHERE r2.client_id = v_uid AND r2.group_id = g.id
               ) THEN 5 ELSE 0 END
      )::NUMERIC, 1) AS rec_score
    FROM public.groups g
    WHERE g.is_active = TRUE
      AND (
        -- Grupos del mismo género O misma ciudad O bien rankeados
        LOWER(TRIM(g.genre)) = LOWER(TRIM(v_genre))
        OR LOWER(TRIM(g.city))  = LOWER(TRIM(v_city))
        OR COALESCE(g.ranking_score, 0) >= 3.5
      )
    ORDER BY rec_score DESC
    LIMIT p_limit
  ) r;

  RETURN jsonb_build_object(
    'ok',              true,
    'genre_used',      v_genre,
    'city_used',       v_city,
    'recommendations', COALESCE(v_results, '[]')
  );

EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$$;

GRANT EXECUTE ON FUNCTION public.get_personalized_recommendations(TEXT, TEXT, INT) TO authenticated;


-- ── 5. get_platform_gaps() — zonas con demanda > oferta ──────────────────────
-- Identifica ciudades y géneros donde hay muchas solicitudes pero pocos grupos.
-- Usado por admin para campañas de reclutamiento de artistas.
-- También sirve para enviar boosts internos a grupos que se unan a esas zonas.

CREATE OR REPLACE FUNCTION public.get_platform_gaps(
  p_days_back INT DEFAULT 30,
  p_limit     INT DEFAULT 20
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_gaps JSONB;
BEGIN
  SELECT jsonb_agg(row_to_json(r) ORDER BY r.gap_score DESC)
  INTO v_gaps
  FROM (
    SELECT
      LOWER(TRIM(er.location_city))  AS city,
      LOWER(TRIM(er.genre))          AS genre,
      COUNT(er.id)                   AS demand_requests,
      COALESCE(gs.active_groups, 0)  AS supply_groups,
      -- Gap score: cuánta demanda hay por grupo disponible (mayor = mayor brecha)
      CASE WHEN COALESCE(gs.active_groups, 0) = 0
           THEN COUNT(er.id) * 2.0   -- sin grupos = brecha máxima
           ELSE COUNT(er.id)::NUMERIC / gs.active_groups
      END                            AS gap_score,
      CASE WHEN COALESCE(gs.active_groups, 0) = 0 THEN 'sin_grupos'
           WHEN COUNT(er.id)::NUMERIC / gs.active_groups > 5 THEN 'critica'
           WHEN COUNT(er.id)::NUMERIC / gs.active_groups > 2 THEN 'alta'
           ELSE 'moderada'
      END                            AS gap_level
    FROM public.event_requests er
    LEFT JOIN (
      SELECT LOWER(TRIM(city)) AS city, LOWER(TRIM(genre)) AS genre,
             COUNT(*) AS active_groups
      FROM public.groups
      WHERE is_active = TRUE
      GROUP BY 1, 2
    ) gs ON gs.city = LOWER(TRIM(er.location_city))
         AND gs.genre = LOWER(TRIM(er.genre))
    WHERE er.created_at >= NOW() - (p_days_back || ' days')::INTERVAL
      AND er.location_city IS NOT NULL
      AND er.genre IS NOT NULL
    GROUP BY 1, 2, gs.active_groups
    HAVING COUNT(er.id) >= 2
    ORDER BY gap_score DESC
    LIMIT p_limit
  ) r;

  RETURN jsonb_build_object(
    'ok',       true,
    'days_back', p_days_back,
    'gaps',     COALESCE(v_gaps, '[]')
  );

EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$$;

GRANT EXECUTE ON FUNCTION public.get_platform_gaps(INT, INT) TO authenticated;


-- ── 6. get_admin_platform_stats() — panel de control admin completo ───────────
-- Combina ingresos, reservas, grupos, express y tendencias en una sola consulta.
-- Optimizado para el AdminDashboard.

CREATE OR REPLACE FUNCTION public.get_admin_platform_stats(
  p_days_back INT DEFAULT 30
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_cutoff         TIMESTAMPTZ := NOW() - (p_days_back || ' days')::INTERVAL;
  v_total_revenue  NUMERIC;
  v_new_reservations INT;
  v_completions    INT;
  v_cancellations  INT;
  v_express_req    INT;
  v_express_conv   NUMERIC;     -- tasa de conversión express
  v_new_groups     INT;
  v_active_groups  INT;
  v_new_clients    INT;
  v_top_cities     JSONB;
  v_top_genres     JSONB;
  v_revenue_trend  JSONB;       -- ingresos por semana (últimas 4)
BEGIN
  -- ── Ingresos totales ──────────────────────────────────────────────────────
  SELECT COALESCE(SUM(total_price), 0) INTO v_total_revenue
  FROM public.reservations
  WHERE status = 'completed' AND event_date >= v_cutoff::DATE;

  -- ── Reservas ──────────────────────────────────────────────────────────────
  SELECT COUNT(*) INTO v_new_reservations
  FROM public.reservations
  WHERE created_at >= v_cutoff;

  SELECT COUNT(*) INTO v_completions
  FROM public.reservations
  WHERE status = 'completed' AND event_date >= v_cutoff::DATE;

  SELECT COUNT(*) INTO v_cancellations
  FROM public.reservations
  WHERE status = 'cancelled' AND created_at >= v_cutoff;

  -- ── Solicitudes express ───────────────────────────────────────────────────
  SELECT COUNT(*) INTO v_express_req
  FROM public.event_requests
  WHERE created_at >= v_cutoff;

  SELECT CASE WHEN v_express_req = 0 THEN 0
              ELSE COUNT(*) FILTER (WHERE status IN ('accepted','completed'))
                   ::NUMERIC / v_express_req
         END
  INTO v_express_conv
  FROM public.event_requests
  WHERE created_at >= v_cutoff;

  -- ── Grupos ───────────────────────────────────────────────────────────────
  SELECT COUNT(*) INTO v_new_groups
  FROM public.groups
  WHERE created_at >= v_cutoff AND is_active = TRUE;

  SELECT COUNT(*) INTO v_active_groups
  FROM public.groups
  WHERE is_active = TRUE;

  -- ── Clientes nuevos ───────────────────────────────────────────────────────
  SELECT COUNT(*) INTO v_new_clients
  FROM public.profiles
  WHERE role = 'client' AND created_at >= v_cutoff;

  -- ── Top ciudades por ingresos ─────────────────────────────────────────────
  SELECT jsonb_agg(row_to_json(r) ORDER BY r.revenue DESC)
  INTO v_top_cities
  FROM (
    SELECT COALESCE(g.city, 'Sin ciudad') AS city,
           COUNT(r.id)                    AS reservations,
           COALESCE(SUM(r.total_price), 0) AS revenue
    FROM public.reservations r
    LEFT JOIN public.groups g ON g.id = r.group_id
    WHERE r.status = 'completed' AND r.event_date >= v_cutoff::DATE
    GROUP BY 1
    ORDER BY revenue DESC
    LIMIT 10
  ) r;

  -- ── Top géneros por demanda ───────────────────────────────────────────────
  SELECT jsonb_agg(row_to_json(r) ORDER BY r.requests DESC)
  INTO v_top_genres
  FROM (
    SELECT COALESCE(genre, 'Sin género') AS genre,
           COUNT(*)                      AS requests,
           COUNT(*) FILTER (WHERE status IN ('accepted','completed')) AS accepted
    FROM public.event_requests
    WHERE created_at >= v_cutoff
    GROUP BY 1
    ORDER BY requests DESC
    LIMIT 8
  ) r;

  -- ── Tendencia de ingresos (últimas 4 semanas) ────────────────────────────
  SELECT jsonb_agg(row_to_json(r) ORDER BY r.week_start)
  INTO v_revenue_trend
  FROM (
    SELECT DATE_TRUNC('week', event_date::TIMESTAMPTZ)::DATE AS week_start,
           COALESCE(SUM(total_price), 0) AS revenue,
           COUNT(*) AS completions
    FROM public.reservations
    WHERE status = 'completed'
      AND event_date >= CURRENT_DATE - INTERVAL '28 days'
    GROUP BY 1
    ORDER BY 1
  ) r;

  RETURN jsonb_build_object(
    'ok',               true,
    'period_days',      p_days_back,
    'total_revenue',    v_total_revenue,
    'new_reservations', v_new_reservations,
    'completions',      v_completions,
    'cancellations',    v_cancellations,
    'express_requests', v_express_req,
    'express_conversion', ROUND(COALESCE(v_express_conv, 0)::NUMERIC * 100, 1),
    'new_groups',       v_new_groups,
    'active_groups',    v_active_groups,
    'new_clients',      v_new_clients,
    'top_cities',       COALESCE(v_top_cities,  '[]'),
    'top_genres',       COALESCE(v_top_genres,  '[]'),
    'revenue_trend',    COALESCE(v_revenue_trend,'[]')
  );

EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$$;

GRANT EXECUTE ON FUNCTION public.get_admin_platform_stats(INT) TO authenticated;


-- ── Cron jobs ─────────────────────────────────────────────────────────────────

DO $$
BEGIN
  BEGIN PERFORM cron.unschedule('platform-snapshot');        EXCEPTION WHEN OTHERS THEN NULL; END;
  BEGIN PERFORM cron.unschedule('update-recent-completions'); EXCEPTION WHEN OTHERS THEN NULL; END;

  -- Snapshot diario a las 3:00 AM
  PERFORM cron.schedule(
    'platform-snapshot',
    '0 3 * * *',
    'SELECT public.take_platform_snapshot()'
  );

  -- Actualizar recent_completions diariamente a las 3:30 AM
  PERFORM cron.schedule(
    'update-recent-completions',
    '30 3 * * *',
    'SELECT public.update_recent_completions()'
  );

EXCEPTION WHEN OTHERS THEN
  RAISE NOTICE 'pg_cron no disponible. Activar en Dashboard → Extensions → pg_cron.';
END;
$$;


SELECT '114_platform_protection: analytics + recent_completions + preferencias + recomendaciones + brechas + admin stats ✅' AS status;
