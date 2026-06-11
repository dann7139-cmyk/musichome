-- ─────────────────────────────────────────────────────────────────────────────
-- 186_admin_ranking.sql
-- Dashboard financiero de admin + algoritmo de ranking por estado.
--
--  1.  Vistas admin: GMV, ganancias plataforma, wallets por cobrar
--  2.  RPC admin_gmv_summary — métricas globales
--  3.  RPC admin_payout_queue — retiros pendientes con detalle de grupo
--  4.  RPC admin_dispute_overview — disputas activas
--  5.  demand_scores — tabla de demanda por ciudad/estado
--  6.  RPC update_demand_scores — calcula demanda real desde reservas
--  7.  RPC get_groups_ranked_by_demand — ranking mejorado con score
--  8.  Columna rank_boost en groups (para anuncios bid que pagaron)
--  9.  Índices
-- ─────────────────────────────────────────────────────────────────────────────

-- ── 1. admin_platform_metrics (vista protegida) ───────────────────────────────
--
-- Solo service_role (Edge Functions) o la RPC admin_gmv_summary acceden aquí.

CREATE OR REPLACE VIEW admin_platform_metrics AS
SELECT
  -- GMV total (suma de todos los pagos completados)
  COALESCE(SUM(r.total_price) FILTER (
    WHERE r.payment_status IN ('paid', 'fully_paid', 'deposit_paid')
  ), 0) AS gmv_total,

  -- Ganancia de plataforma (tarifa de servicio acumulada)
  COALESCE(SUM(r.service_fee_amount) FILTER (
    WHERE r.payment_status IN ('paid', 'fully_paid', 'deposit_paid')
  ), 0) AS platform_earnings,

  -- Pagos en retención (pending en wallets)
  COALESCE((SELECT SUM(pending_balance) FROM group_wallets), 0) AS wallets_pending,

  -- Pagos disponibles para retiro (available en wallets)
  COALESCE((SELECT SUM(available_balance) FROM group_wallets), 0) AS wallets_available,

  -- Retiros pendientes de aprobar
  COALESCE((
    SELECT SUM(amount) FROM payout_requests WHERE status = 'pending'
  ), 0) AS payouts_pending,

  -- Disputas abiertas
  (SELECT COUNT(*) FROM disputes WHERE status IN ('open','under_review')) AS disputes_open,

  -- MSI: cuántas reservas usaron meses sin intereses
  COUNT(*) FILTER (
    WHERE r.installment_months > 1 AND r.payment_status IN ('paid','fully_paid','deposit_paid')
  ) AS reservations_with_msi,

  -- Reservas totales (todos los estados)
  COUNT(*)                    AS reservations_total,
  -- Reservas pagadas
  COUNT(*) FILTER (WHERE r.payment_status IN ('paid','fully_paid','deposit_paid')) AS reservations_paid,
  -- Tasa de conversión
  ROUND(
    100.0 * COUNT(*) FILTER (WHERE r.payment_status IN ('paid','fully_paid','deposit_paid'))
    / NULLIF(COUNT(*), 0),
    1
  ) AS conversion_rate_pct,

  -- Período
  MIN(r.created_at) AS first_reservation,
  MAX(r.created_at) AS last_reservation

FROM reservations r;

REVOKE ALL ON admin_platform_metrics FROM PUBLIC;
REVOKE ALL ON admin_platform_metrics FROM authenticated;
REVOKE ALL ON admin_platform_metrics FROM anon;
GRANT  SELECT ON admin_platform_metrics TO service_role;

-- ── 2. RPC admin_gmv_summary ──────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION admin_gmv_summary(
  p_from DATE DEFAULT NULL,
  p_to   DATE DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_caller_id UUID := auth.uid();
  v_result    RECORD;
  v_gmv_period NUMERIC;
  v_fee_period NUMERIC;
BEGIN
  IF v_caller_id IS NULL THEN RAISE EXCEPTION 'unauthorized: sesión requerida'; END IF;
  IF NOT EXISTS (SELECT 1 FROM profiles WHERE id = v_caller_id AND role = 'admin') THEN
    RAISE EXCEPTION 'unauthorized: solo admins';
  END IF;

  SELECT * INTO v_result FROM admin_platform_metrics;

  -- GMV del período si se especificaron fechas
  IF p_from IS NOT NULL OR p_to IS NOT NULL THEN
    SELECT
      COALESCE(SUM(total_price), 0),
      COALESCE(SUM(service_fee_amount), 0)
    INTO v_gmv_period, v_fee_period
    FROM reservations
    WHERE payment_status IN ('paid','fully_paid','deposit_paid')
      AND (p_from IS NULL OR event_date >= p_from)
      AND (p_to   IS NULL OR event_date <= p_to);
  ELSE
    v_gmv_period := v_result.gmv_total;
    v_fee_period := v_result.platform_earnings;
  END IF;

  RETURN jsonb_build_object(
    'gmv_total',            v_result.gmv_total,
    'gmv_period',           v_gmv_period,
    'platform_earnings',    v_result.platform_earnings,
    'platform_fee_period',  v_fee_period,
    'wallets_pending',      v_result.wallets_pending,
    'wallets_available',    v_result.wallets_available,
    'payouts_pending',      v_result.payouts_pending,
    'disputes_open',        v_result.disputes_open,
    'reservations_total',   v_result.reservations_total,
    'reservations_paid',    v_result.reservations_paid,
    'conversion_rate_pct',  v_result.conversion_rate_pct,
    'reservations_with_msi', v_result.reservations_with_msi
  );
END;
$$;

-- ── 3. RPC admin_payout_queue ─────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION admin_payout_queue(
  p_status TEXT DEFAULT 'pending',
  p_limit  INT  DEFAULT 50,
  p_offset INT  DEFAULT 0
)
RETURNS TABLE (
  payout_request_id UUID,
  group_id          UUID,
  group_name        TEXT,
  owner_email       TEXT,
  amount            NUMERIC,
  payout_method     TEXT,
  clabe             TEXT,
  bank_name         TEXT,
  stripe_account_id TEXT,
  status            TEXT,
  created_at        TIMESTAMPTZ,
  approved_at       TIMESTAMPTZ
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM profiles WHERE id = auth.uid() AND role = 'admin') THEN
    RAISE EXCEPTION 'unauthorized: solo admins';
  END IF;

  RETURN QUERY
    SELECT
      pr.id,
      pr.group_id,
      g.name,
      u.email,
      pr.amount,
      pr.payout_method,
      pr.clabe,
      pr.bank_name,
      pr.stripe_account_id,
      pr.status,
      pr.created_at,
      pr.approved_at
    FROM payout_requests pr
    JOIN groups g ON g.id = pr.group_id
    JOIN auth.users u ON u.id = g.owner_id
    WHERE (p_status = 'all' OR pr.status = p_status)
    ORDER BY pr.created_at DESC
    LIMIT p_limit OFFSET p_offset;
END;
$$;

-- ── 4. RPC admin_dispute_overview ─────────────────────────────────────────────

CREATE OR REPLACE FUNCTION admin_dispute_overview(
  p_status TEXT DEFAULT 'open',
  p_limit  INT  DEFAULT 50,
  p_offset INT  DEFAULT 0
)
RETURNS TABLE (
  dispute_id     UUID,
  reservation_id UUID,
  event_date     DATE,
  total_price    NUMERIC,
  status         TEXT,
  reason         TEXT,
  opened_by      UUID,
  opener_email   TEXT,
  group_name     TEXT,
  created_at     TIMESTAMPTZ,
  updated_at     TIMESTAMPTZ
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM profiles WHERE id = auth.uid() AND role = 'admin') THEN
    RAISE EXCEPTION 'unauthorized: solo admins';
  END IF;

  RETURN QUERY
    SELECT
      d.id,
      d.reservation_id,
      r.event_date,
      r.total_price,
      d.status,
      d.reason,
      d.opened_by,
      u.email,
      g.name,
      d.created_at,
      d.updated_at
    FROM disputes d
    JOIN reservations r ON r.id = d.reservation_id
    JOIN groups g ON g.id = r.group_id
    JOIN auth.users u ON u.id = d.opened_by
    WHERE (p_status = 'all' OR d.status = p_status)
    ORDER BY d.created_at DESC
    LIMIT p_limit OFFSET p_offset;
END;
$$;

-- ── 5. demand_scores ──────────────────────────────────────────────────────────
--
-- Score de demanda por ciudad + estado. Se actualiza periódicamente.
-- score_30d: reservas en últimos 30 días.
-- score_90d: reservas en últimos 90 días.
-- trend: 'rising' | 'stable' | 'falling'

CREATE TABLE IF NOT EXISTS demand_scores (
  id          UUID        DEFAULT gen_random_uuid() PRIMARY KEY,
  city        TEXT,
  state       TEXT,
  score_30d   INT         DEFAULT 0,
  score_90d   INT         DEFAULT 0,
  trend       TEXT        DEFAULT 'stable'
    CONSTRAINT chk_ds_trend CHECK (trend IN ('rising','stable','falling')),
  calculated_at TIMESTAMPTZ DEFAULT NOW(),
  UNIQUE (city, state)
);

ALTER TABLE demand_scores ENABLE ROW LEVEL SECURITY;

-- Cualquier usuario autenticado puede leer los scores (son datos públicos)
DROP POLICY IF EXISTS ds_read ON demand_scores;
CREATE POLICY ds_read ON demand_scores FOR SELECT USING (TRUE);

DROP POLICY IF EXISTS ds_no_write ON demand_scores;
CREATE POLICY ds_no_write ON demand_scores FOR ALL USING (FALSE);

-- ── 6. RPC update_demand_scores ───────────────────────────────────────────────
--
-- Calcula la demanda real desde las reservas confirmadas.
-- Se ejecuta desde un cron diario o manualmente por el admin.

CREATE OR REPLACE FUNCTION update_demand_scores()
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_updated INT := 0;
BEGIN
  -- Upsert scores calculados desde reservas reales
  INSERT INTO demand_scores (city, state, score_30d, score_90d, trend, calculated_at)
  SELECT
    g.city,
    g.state,
    COUNT(*) FILTER (WHERE r.created_at > NOW() - INTERVAL '30 days')  AS score_30d,
    COUNT(*) FILTER (WHERE r.created_at > NOW() - INTERVAL '90 days')  AS score_90d,
    CASE
      WHEN COUNT(*) FILTER (WHERE r.created_at > NOW() - INTERVAL '30 days') >
           COUNT(*) FILTER (WHERE r.created_at > NOW() - INTERVAL '60 days'
                                              AND r.created_at <= NOW() - INTERVAL '30 days')
      THEN 'rising'
      WHEN COUNT(*) FILTER (WHERE r.created_at > NOW() - INTERVAL '30 days') <
           COUNT(*) FILTER (WHERE r.created_at > NOW() - INTERVAL '60 days'
                                              AND r.created_at <= NOW() - INTERVAL '30 days')
      THEN 'falling'
      ELSE 'stable'
    END AS trend,
    NOW()
  FROM reservations r
  JOIN groups g ON g.id = r.group_id
  WHERE r.payment_status IN ('paid','fully_paid','deposit_paid')
    AND g.city IS NOT NULL
  GROUP BY g.city, g.state
  ON CONFLICT (city, state) DO UPDATE
    SET
      score_30d     = EXCLUDED.score_30d,
      score_90d     = EXCLUDED.score_90d,
      trend         = EXCLUDED.trend,
      calculated_at = NOW();

  GET DIAGNOSTICS v_updated = ROW_COUNT;

  RETURN jsonb_build_object('ok', true, 'updated_locations', v_updated, 'calculated_at', NOW());
END;
$$;

-- ── 7. RPC get_groups_ranked_by_demand ────────────────────────────────────────
--
-- Reemplaza a get_groups_ranked_by_city pero incluye:
-- - Peso por demanda local (demand_scores)
-- - rank_boost por anuncios pagados (bid_orders activos)
-- - Verificación de grupos (verification_level)
--
-- Fórmula: base_score + demand_weight + verification_bonus + rank_boost

CREATE OR REPLACE FUNCTION get_groups_ranked_by_demand(
  p_city   TEXT    DEFAULT NULL,
  p_state  TEXT    DEFAULT NULL,
  p_limit  INT     DEFAULT 20,
  p_offset INT     DEFAULT 0
)
RETURNS TABLE (
  id                 UUID,
  name               TEXT,
  city               TEXT,
  state              TEXT,
  description        TEXT,
  price_from         NUMERIC,
  photo_url          TEXT,
  photo_status       TEXT,
  verification_level TEXT,
  rating             NUMERIC,
  total_reviews      INT,
  rank_boost         INT,
  demand_trend       TEXT,
  composite_score    NUMERIC
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  RETURN QUERY
    WITH demand AS (
      SELECT ds.city, ds.state, ds.score_30d, ds.trend
      FROM demand_scores ds
    ),
    group_ratings AS (
      SELECT
        r2.group_id,
        ROUND(AVG(r2.rating)::NUMERIC, 1) AS avg_rating,
        COUNT(*)::INT                      AS review_count
      FROM reviews r2
      GROUP BY r2.group_id
    ),
    active_boosts AS (
      SELECT
        bo.group_id,
        MAX(bo.boost_amount)::INT AS max_boost
      FROM bid_orders bo
      WHERE bo.status = 'active'
        AND (bo.expires_at IS NULL OR bo.expires_at > NOW())
      GROUP BY bo.group_id
    )
    SELECT
      g.id,
      g.name,
      g.city,
      g.state,
      g.description,
      g.price_from,
      g.photo_url,
      g.photo_status,
      COALESCE(g.verification_level, 'none'),
      COALESCE(gr.avg_rating, 0),
      COALESCE(gr.review_count, 0),
      COALESCE(ab.max_boost, 0),
      COALESCE(d.trend, 'stable'),
      -- Composite score: base rating + demand + verification + boost
      (
        COALESCE(gr.avg_rating, 0) * 10 +                  -- 0-50 pts por rating
        LEAST(COALESCE(d.score_30d, 0) * 2, 30) +          -- 0-30 pts por demanda local
        CASE COALESCE(g.verification_level, 'none')
          WHEN 'verified'  THEN 15
          WHEN 'enhanced'  THEN 20
          WHEN 'basic'     THEN 5
          ELSE 0
        END +                                              -- 0-20 pts por verificación
        COALESCE(ab.max_boost, 0)                          -- pts extra por bid pagado
      ) AS composite_score
    FROM groups g
    LEFT JOIN group_ratings gr  ON gr.group_id = g.id
    LEFT JOIN active_boosts ab  ON ab.group_id = g.id
    LEFT JOIN demand d
      ON d.city = g.city
     AND (d.state = g.state OR (d.state IS NULL AND g.state IS NULL))
    WHERE g.status = 'active'
      AND (p_city  IS NULL OR g.city  ILIKE p_city)
      AND (p_state IS NULL OR g.state ILIKE p_state)
    ORDER BY composite_score DESC, g.name ASC
    LIMIT p_limit OFFSET p_offset;
END;
$$;

-- ── 8. rank_boost en groups ───────────────────────────────────────────────────

ALTER TABLE groups
  ADD COLUMN IF NOT EXISTS rank_boost INT DEFAULT 0;

-- ── 9. Índices ────────────────────────────────────────────────────────────────

CREATE INDEX IF NOT EXISTS idx_demand_scores_city_state ON demand_scores(city, state);
CREATE INDEX IF NOT EXISTS idx_groups_city_state_status ON groups(city, state, status)
  WHERE status = 'active';
CREATE INDEX IF NOT EXISTS idx_reservations_event_date ON reservations(event_date);
CREATE INDEX IF NOT EXISTS idx_reservations_created_at ON reservations(created_at DESC);
CREATE INDEX IF NOT EXISTS idx_disputes_created_at ON disputes(created_at DESC);
CREATE INDEX IF NOT EXISTS idx_pr_created_at ON payout_requests(created_at DESC);
