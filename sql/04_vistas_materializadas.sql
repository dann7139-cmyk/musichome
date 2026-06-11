-- ============================================================
-- DARICEFY - 04_vistas_materializadas.sql
-- Ejecutar CUARTO en Supabase SQL Editor
-- ============================================================

-- Agregar columnas faltantes a countries (por si acaso)
ALTER TABLE public.countries ADD COLUMN IF NOT EXISTS commission_rate DECIMAL(5,2) DEFAULT 15.0;
ALTER TABLE public.countries ADD COLUMN IF NOT EXISTS currency_code VARCHAR(3) DEFAULT 'MXN';
ALTER TABLE public.countries ADD COLUMN IF NOT EXISTS currency_symbol VARCHAR(5) DEFAULT '$';
ALTER TABLE public.countries ADD COLUMN IF NOT EXISTS payment_provider TEXT DEFAULT 'mercadopago';
ALTER TABLE public.countries ADD COLUMN IF NOT EXISTS code VARCHAR(3);

-- ─────────────────────────────────────────────────
-- 1. VISTA: Estadísticas del dashboard de admin
-- ─────────────────────────────────────────────────
DROP MATERIALIZED VIEW IF EXISTS admin_dashboard_stats;
CREATE MATERIALIZED VIEW admin_dashboard_stats AS
SELECT
  COUNT(*)                                          AS total_reservations,
  COUNT(*) FILTER (WHERE status = 'pending')        AS pending_reservations,
  COUNT(*) FILTER (WHERE status = 'confirmed')      AS confirmed_reservations,
  COUNT(*) FILTER (WHERE status = 'in_progress')    AS active_events,
  COUNT(*) FILTER (WHERE status = 'completed')      AS completed_reservations,
  COALESCE(SUM(total_price), 0)                     AS total_revenue,
  COALESCE(SUM(platform_commission), 0)             AS total_commission,
  COALESCE(SUM(group_earnings), 0)                  AS total_group_earnings,
  COALESCE(
    SUM(total_price) FILTER (
      WHERE created_at >= date_trunc('month', NOW())
    ), 0
  )                                                 AS monthly_revenue,
  COALESCE(
    SUM(platform_commission) FILTER (
      WHERE created_at >= date_trunc('month', NOW())
    ), 0
  )                                                 AS monthly_commission
FROM public.reservations;

-- ─────────────────────────────────────────────────
-- 2. VISTA: Top grupos por ingresos
-- ─────────────────────────────────────────────────
DROP MATERIALIZED VIEW IF EXISTS top_groups;
CREATE MATERIALIZED VIEW top_groups AS
SELECT
  g.id,
  g.name,
  g.genre,
  g.city,
  COALESCE(g.is_verified, false)          AS is_verified,
  COALESCE(g.rating, 4.5)                 AS rating,
  COUNT(r.id)                             AS total_reservations,
  COALESCE(SUM(r.group_earnings), 0)      AS total_earnings
FROM public.groups g
LEFT JOIN public.reservations r ON r.group_id = g.id AND r.status = 'completed'
WHERE COALESCE(g.is_active, true) = TRUE
GROUP BY g.id
ORDER BY total_earnings DESC
LIMIT 20;

-- ─────────────────────────────────────────────────
-- 3. VISTA: Estadísticas por país
-- ─────────────────────────────────────────────────
DROP MATERIALIZED VIEW IF EXISTS country_stats;
CREATE MATERIALIZED VIEW country_stats AS
SELECT
  c.name                                        AS country_name,
  COALESCE(c.commission_rate, 15.0)             AS commission_rate,
  COALESCE(c.currency_code, 'MXN')              AS currency_code,
  COUNT(DISTINCT g.id)                          AS total_groups,
  COUNT(DISTINCT r.id)                          AS total_reservations,
  COALESCE(SUM(r.platform_commission), 0)       AS total_commission
FROM public.countries c
LEFT JOIN public.groups g ON g.country_id = c.id
LEFT JOIN public.reservations r ON r.group_id = g.id
GROUP BY c.id, c.name, c.commission_rate, c.currency_code;

-- ─────────────────────────────────────────────────
-- 4. Índices únicos para REFRESH CONCURRENTLY
-- ─────────────────────────────────────────────────
CREATE UNIQUE INDEX IF NOT EXISTS idx_top_groups_id
  ON top_groups(id);

CREATE UNIQUE INDEX IF NOT EXISTS idx_country_stats_name
  ON country_stats(country_name);

-- ─────────────────────────────────────────────────
-- 5. Función para refrescar vistas
-- ─────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.refresh_all_materialized_views()
RETURNS void AS $$
BEGIN
  REFRESH MATERIALIZED VIEW CONCURRENTLY admin_dashboard_stats;
  REFRESH MATERIALIZED VIEW CONCURRENTLY top_groups;
  REFRESH MATERIALIZED VIEW CONCURRENTLY country_stats;
END;
$$ LANGUAGE plpgsql;

-- ─────────────────────────────────────────────────
-- 6. Permisos
-- ─────────────────────────────────────────────────
GRANT SELECT ON admin_dashboard_stats TO authenticated;
GRANT SELECT ON top_groups TO authenticated;
GRANT SELECT ON country_stats TO authenticated;

SELECT 'Vistas materializadas creadas correctamente ✅' AS status;
