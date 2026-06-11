-- ============================================================
-- DARICEFY - 35_stats_avanzadas.sql
-- RPCs para estadísticas avanzadas: Grupo, Talento, Admin
-- Ejecutar en Supabase SQL Editor
-- ============================================================

-- ─────────────────────────────────────────────────────────────
-- 0. Asegurar que la columna commission_amount existe
-- ─────────────────────────────────────────────────────────────
ALTER TABLE public.reservations
  ADD COLUMN IF NOT EXISTS commission_amount NUMERIC(10,2) DEFAULT 0;

-- ─────────────────────────────────────────────────────────────
-- 1. Ingresos mensuales del grupo (últimos N meses)
-- ─────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION get_group_monthly_earnings(
  p_group_id UUID,
  p_months   INT DEFAULT 6
)
RETURNS TABLE(period TEXT, earnings NUMERIC, events BIGINT)
LANGUAGE sql SECURITY DEFINER AS $$
  SELECT
    TO_CHAR(DATE_TRUNC('month', event_date::date), 'Mon') AS period,
    COALESCE(SUM(group_earnings), 0)                      AS earnings,
    COUNT(*)                                               AS events
  FROM reservations
  WHERE group_id = p_group_id
    AND status = 'completed'
    AND event_date::date >= (CURRENT_DATE - (p_months || ' months')::INTERVAL)
  GROUP BY DATE_TRUNC('month', event_date::date)
  ORDER BY DATE_TRUNC('month', event_date::date);
$$;

-- ─────────────────────────────────────────────────────────────
-- 2. Estadísticas mensuales de toda la plataforma (admin)
-- ─────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION get_platform_monthly_stats(
  p_months INT DEFAULT 6
)
RETURNS TABLE(period TEXT, revenue NUMERIC, commission NUMERIC, events BIGINT)
LANGUAGE sql SECURITY DEFINER AS $$
  SELECT
    TO_CHAR(DATE_TRUNC('month', event_date::date), 'Mon') AS period,
    COALESCE(SUM(total_price), 0)                         AS revenue,
    COALESCE(SUM(commission_amount), 0)                   AS commission,
    COUNT(*)                                               AS events
  FROM reservations
  WHERE status = 'completed'
    AND event_date::date >= (CURRENT_DATE - (p_months || ' months')::INTERVAL)
  GROUP BY DATE_TRUNC('month', event_date::date)
  ORDER BY DATE_TRUNC('month', event_date::date);
$$;

-- ─────────────────────────────────────────────────────────────
-- 3. Top grupos por ingresos (admin)
-- ─────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION get_top_groups_earnings(
  p_limit INT DEFAULT 5
)
RETURNS TABLE(group_name TEXT, total_earnings NUMERIC, event_count BIGINT)
LANGUAGE sql SECURITY DEFINER AS $$
  SELECT
    g.name                                   AS group_name,
    COALESCE(SUM(r.group_earnings), 0)       AS total_earnings,
    COUNT(r.id)                              AS event_count
  FROM groups g
  LEFT JOIN reservations r
    ON r.group_id = g.id AND r.status = 'completed'
  GROUP BY g.id, g.name
  ORDER BY total_earnings DESC
  LIMIT p_limit;
$$;

-- ─────────────────────────────────────────────────────────────
-- 4. Grupos con más cancelaciones (admin - riesgo)
-- ─────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION get_risk_groups(
  p_limit INT DEFAULT 5
)
RETURNS TABLE(group_name TEXT, cancellation_count BIGINT)
LANGUAGE sql SECURITY DEFINER AS $$
  SELECT
    g.name            AS group_name,
    COUNT(r.id)       AS cancellation_count
  FROM groups g
  JOIN reservations r
    ON r.group_id = g.id AND r.status IN ('cancelled', 'rejected')
  GROUP BY g.id, g.name
  ORDER BY cancellation_count DESC
  LIMIT p_limit;
$$;

-- ─────────────────────────────────────────────────────────────
-- 5. Eventos por ciudad de grupo (admin)
-- ─────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION get_events_by_city(
  p_limit INT DEFAULT 5
)
RETURNS TABLE(city TEXT, event_count BIGINT)
LANGUAGE sql SECURITY DEFINER AS $$
  SELECT
    COALESCE(g.city, 'Sin ciudad') AS city,
    COUNT(r.id)                    AS event_count
  FROM reservations r
  JOIN groups g ON g.id = r.group_id
  WHERE r.status = 'completed'
  GROUP BY g.city
  ORDER BY event_count DESC
  LIMIT p_limit;
$$;

SELECT 'RPCs de estadísticas avanzadas creados correctamente ✅' AS status;
