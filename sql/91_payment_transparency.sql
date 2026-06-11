-- ═══════════════════════════════════════════════════════════════════════════════
-- 91_payment_transparency.sql
-- Transparencia financiera: event_financial_summary + payment_transactions
-- ═══════════════════════════════════════════════════════════════════════════════

-- ── 1. event_financial_summary ───────────────────────────────────────────────
-- Un registro por reserva completada con el desglose real de dinero.
-- stripe_fee es una estimación (3.6% + $3 MXN — tarifa Stripe México).
-- mercadopago_fee empieza en 0 y se actualiza al procesar retiro SPEI.

CREATE TABLE IF NOT EXISTS event_financial_summary (
  id                  UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  reservation_id      UUID        UNIQUE REFERENCES reservations(id) ON DELETE CASCADE,
  event_total         NUMERIC     NOT NULL DEFAULT 0,
  platform_fee        NUMERIC     NOT NULL DEFAULT 0,   -- comisión cobrada (commission_amount)
  stripe_fee          NUMERIC     NOT NULL DEFAULT 0,   -- estimado: total * 3.6% + $3
  mercadopago_fee     NUMERIC     NOT NULL DEFAULT 0,   -- fee SPEI (se actualiza al retirar)
  artists_payout      NUMERIC     NOT NULL DEFAULT 0,   -- lo que van los artistas (group_earnings)
  net_platform_profit NUMERIC     GENERATED ALWAYS AS
                        (platform_fee - stripe_fee - mercadopago_fee) STORED,
  created_at          TIMESTAMPTZ DEFAULT now()
);

ALTER TABLE event_financial_summary ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "efs_admin_all" ON event_financial_summary;
CREATE POLICY "efs_admin_all" ON event_financial_summary
  FOR ALL TO authenticated
  USING (EXISTS (
    SELECT 1 FROM profiles WHERE id = auth.uid() AND role = 'admin'
  ));

CREATE INDEX IF NOT EXISTS idx_efs_reservation
  ON event_financial_summary(reservation_id);

CREATE INDEX IF NOT EXISTS idx_efs_created_at
  ON event_financial_summary(created_at DESC);

-- ── 2. payment_transactions ──────────────────────────────────────────────────
-- Tabla de auditoría de pagos por evento (complementa financial_ledger).

CREATE TABLE IF NOT EXISTS payment_transactions (
  id              UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id         UUID        REFERENCES profiles(id),
  reservation_id  UUID        REFERENCES reservations(id) ON DELETE CASCADE,
  type            TEXT        NOT NULL CHECK (type IN ('payment','commission','payout','withdrawal')),
  amount          NUMERIC     NOT NULL DEFAULT 0,
  processor       TEXT        NOT NULL DEFAULT 'internal'
                              CHECK (processor IN ('stripe','mercadopago','internal')),
  description     TEXT,
  created_at      TIMESTAMPTZ DEFAULT now()
);

ALTER TABLE payment_transactions ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "pt_admin_all" ON payment_transactions;
DROP POLICY IF EXISTS "pt_users_own" ON payment_transactions;
CREATE POLICY "pt_admin_all" ON payment_transactions
  FOR ALL TO authenticated
  USING (EXISTS (
    SELECT 1 FROM profiles WHERE id = auth.uid() AND role = 'admin'
  ));

CREATE POLICY "pt_users_own" ON payment_transactions
  FOR SELECT TO authenticated
  USING (auth.uid() = user_id);

CREATE INDEX IF NOT EXISTS idx_pt_reservation
  ON payment_transactions(reservation_id);

CREATE INDEX IF NOT EXISTS idx_pt_created_at
  ON payment_transactions(created_at DESC);

-- ── 3. Trigger: poblar al completar evento ────────────────────────────────────

CREATE OR REPLACE FUNCTION populate_event_financial_summary()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_total       NUMERIC;
  v_stripe_fee  NUMERIC;
BEGIN
  -- Solo cuando status cambia A 'completed'
  IF NEW.status <> 'completed' OR OLD.status = 'completed' THEN
    RETURN NEW;
  END IF;

  v_total      := COALESCE(NEW.total_price, 0);
  -- Estimación Stripe México: 3.6% + $3 MXN
  v_stripe_fee := ROUND(v_total * 0.036 + 3, 2);

  -- ── Resumen financiero del evento ──────────────────────────────────────────
  INSERT INTO event_financial_summary (
    reservation_id, event_total, platform_fee, stripe_fee, mercadopago_fee, artists_payout
  ) VALUES (
    NEW.id,
    v_total,
    COALESCE(NEW.commission_amount, 0),
    v_stripe_fee,
    0,
    COALESCE(NEW.group_earnings, 0)
  )
  ON CONFLICT (reservation_id) DO UPDATE SET
    event_total    = EXCLUDED.event_total,
    platform_fee   = EXCLUDED.platform_fee,
    stripe_fee     = EXCLUDED.stripe_fee,
    artists_payout = EXCLUDED.artists_payout;

  -- ── payment_transactions: pago del cliente ─────────────────────────────────
  IF NOT EXISTS (
    SELECT 1 FROM payment_transactions
    WHERE reservation_id = NEW.id AND type = 'payment'
  ) THEN
    INSERT INTO payment_transactions (user_id, reservation_id, type, amount, processor, description)
    VALUES (NEW.client_id, NEW.id, 'payment', v_total, 'stripe', 'Pago del cliente por evento');
  END IF;

  -- ── payment_transactions: comisión plataforma ──────────────────────────────
  IF NOT EXISTS (
    SELECT 1 FROM payment_transactions
    WHERE reservation_id = NEW.id AND type = 'commission'
  ) THEN
    INSERT INTO payment_transactions (user_id, reservation_id, type, amount, processor, description)
    VALUES (NULL, NEW.id, 'commission', COALESCE(NEW.commission_amount, 0), 'internal', 'Comisión plataforma');
  END IF;

  -- Nota: distribute_event_earnings ya notifica a artistas y admins.
  -- Este trigger solo pobla event_financial_summary y payment_transactions.

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_populate_event_financial_summary ON reservations;
CREATE TRIGGER trg_populate_event_financial_summary
  AFTER UPDATE OF status ON reservations
  FOR EACH ROW EXECUTE FUNCTION populate_event_financial_summary();

-- ── 4. RPC: resumen financiero para admin ─────────────────────────────────────

CREATE OR REPLACE FUNCTION get_admin_financial_overview(p_days INT DEFAULT NULL)
RETURNS JSON LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_result JSON;
  v_from   TIMESTAMPTZ;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM profiles WHERE id = auth.uid() AND role = 'admin') THEN
    RAISE EXCEPTION 'Unauthorized';
  END IF;

  IF p_days IS NOT NULL THEN
    v_from := NOW() - (p_days || ' days')::INTERVAL;
  END IF;

  SELECT json_build_object(
    'total_facturado',  COALESCE(SUM(efs.event_total),         0),
    'ganancia_bruta',   COALESCE(SUM(efs.platform_fee),        0),
    'stripe_fees',      COALESCE(SUM(efs.stripe_fee),          0),
    'mercadopago_fees', COALESCE(SUM(efs.mercadopago_fee),     0),
    'ganancia_neta',    COALESCE(SUM(efs.net_platform_profit), 0),
    'artistas_payout',  COALESCE(SUM(efs.artists_payout),      0),
    'event_count',      COUNT(*)
  ) INTO v_result
  FROM event_financial_summary efs
  JOIN reservations r ON r.id = efs.reservation_id
  WHERE (v_from IS NULL OR efs.created_at >= v_from);

  RETURN v_result;
END;
$$;

-- ── 5. RPC: desglose por evento para admin ────────────────────────────────────

CREATE OR REPLACE FUNCTION get_admin_event_financials(
  p_days  INT  DEFAULT 30,
  p_limit INT  DEFAULT 50
)
RETURNS TABLE (
  reservation_id      UUID,
  event_date          DATE,
  group_name          TEXT,
  event_total         NUMERIC,
  platform_fee        NUMERIC,
  stripe_fee          NUMERIC,
  mercadopago_fee     NUMERIC,
  net_platform_profit NUMERIC,
  artists_payout      NUMERIC,
  created_at          TIMESTAMPTZ
) LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM profiles WHERE id = auth.uid() AND role = 'admin') THEN
    RAISE EXCEPTION 'Unauthorized';
  END IF;

  RETURN QUERY
  SELECT
    efs.reservation_id,
    r.event_date,
    g.name AS group_name,
    efs.event_total,
    efs.platform_fee,
    efs.stripe_fee,
    efs.mercadopago_fee,
    efs.net_platform_profit,
    efs.artists_payout,
    efs.created_at
  FROM event_financial_summary efs
  JOIN reservations r ON r.id = efs.reservation_id
  LEFT JOIN groups g ON g.id = r.group_id
  WHERE (p_days IS NULL OR efs.created_at >= NOW() - (p_days || ' days')::INTERVAL)
  ORDER BY efs.created_at DESC
  LIMIT p_limit;
END;
$$;

-- ── 6. Poblar datos históricos (ejecutar una vez) ─────────────────────────────
-- Inserta resumen para reservas completadas que ya existían antes de este trigger.
INSERT INTO event_financial_summary (
  reservation_id, event_total, platform_fee, stripe_fee, mercadopago_fee, artists_payout
)
SELECT
  r.id,
  COALESCE(r.total_price, 0),
  COALESCE(r.commission_amount, 0),
  ROUND(COALESCE(r.total_price, 0) * 0.036 + 3, 2),
  0,
  COALESCE(r.group_earnings, 0)
FROM reservations r
WHERE r.status = 'completed'
  AND NOT EXISTS (
    SELECT 1 FROM event_financial_summary efs WHERE efs.reservation_id = r.id
  );
