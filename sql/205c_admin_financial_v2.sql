-- 205c_admin_financial_v2.sql
-- Dashboard financiero admin v2 + validaciones de integridad de wallets.
-- Requiere: 205a, 205b aplicados.

-- ── 1. admin_financial_dashboard ─────────────────────────────────────────────
-- Métricas completas: GMV, held, released, refunds, disputas, strikes, top states/groups.

CREATE OR REPLACE FUNCTION public.admin_financial_dashboard(
  p_from DATE DEFAULT (CURRENT_DATE - INTERVAL '30 days')::DATE,
  p_to   DATE DEFAULT CURRENT_DATE
)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_caller_id UUID := auth.uid();
  v_result    JSONB;
BEGIN
  IF v_caller_id IS NULL THEN RAISE EXCEPTION 'unauthorized'; END IF;
  IF NOT EXISTS (SELECT 1 FROM profiles WHERE id = v_caller_id AND role = 'admin') THEN
    RAISE EXCEPTION 'unauthorized: solo admins';
  END IF;

  SELECT jsonb_build_object(
    'period',       jsonb_build_object('from', p_from, 'to', p_to),
    'financial',    (
      SELECT jsonb_build_object(
        'total_reservations', COUNT(*),
        'gmv',                COALESCE(SUM(total_price)  FILTER (WHERE payment_status IN ('paid','fully_paid')), 0),
        'platform_earnings',  COALESCE(SUM(total_price - COALESCE(base_price, total_price * 0.9))
                                FILTER (WHERE payment_status IN ('paid','fully_paid')), 0),
        'group_earnings',     COALESCE(SUM(COALESCE(base_price, total_price * 0.9))
                                FILTER (WHERE payment_status IN ('paid','fully_paid')), 0),
        'held_money',         COALESCE(SUM(total_price)  FILTER (WHERE payout_status = 'held'), 0),
        'released_money',     COALESCE(SUM(COALESCE(base_price, total_price * 0.9))
                                FILTER (WHERE payout_status = 'released'), 0),
        'refund_total',       COALESCE(SUM(total_price)  FILTER (WHERE payment_status = 'refunded'), 0),
        'failed_payments',    COUNT(*)                   FILTER (WHERE payment_status = 'payment_failed'),
        'cancelled_count',    COUNT(*)                   FILTER (WHERE status = 'cancelled')
      )
      FROM reservations
      WHERE created_at BETWEEN p_from AND p_to + INTERVAL '1 day'
    ),
    'wallets',      (
      SELECT jsonb_build_object(
        'total_pending_balance',   COALESCE(SUM(pending_balance), 0),
        'total_available_balance', COALESCE(SUM(available_balance), 0),
        'total_lifetime_earned',   COALESCE(SUM(total_earned), 0)
      ) FROM group_wallets
    ),
    'disputes',     (
      SELECT jsonb_build_object(
        'open',            COUNT(*) FILTER (WHERE status IN ('open','under_review')),
        'resolved_client', COUNT(*) FILTER (WHERE status = 'resolved_client'),
        'resolved_group',  COUNT(*) FILTER (WHERE status = 'resolved_group')
      ) FROM disputes
      WHERE created_at BETWEEN p_from AND p_to + INTERVAL '1 day'
    ),
    'mismatches',   (
      SELECT COUNT(*) FROM payment_event_logs
      WHERE is_mismatch = TRUE
        AND created_at BETWEEN p_from AND p_to + INTERVAL '1 day'
    ),
    'strikes',      (
      SELECT jsonb_build_object(
        'total_period',       COUNT(*),
        'groups_with_strikes', COUNT(DISTINCT group_id)
      ) FROM group_strikes
      WHERE created_at BETWEEN p_from AND p_to + INTERVAL '1 day'
    ),
    'suspended_groups', (
      SELECT COUNT(*) FROM groups WHERE suspended_at IS NOT NULL
    ),
    'fraud_alerts', (
      SELECT COUNT(*) FROM profiles WHERE risk_score >= 70
    ),
    'pending_payouts', (
      SELECT jsonb_build_object(
        'count',  COUNT(*),
        'amount', COALESCE(SUM(amount), 0)
      ) FROM payout_requests WHERE status = 'pending'
    ),
    'top_states',   (
      SELECT COALESCE(jsonb_agg(row ORDER BY row.revenue DESC), '[]')
      FROM (
        SELECT
          COALESCE(g.state, 'Desconocido') AS state,
          COUNT(*)                         AS reservations,
          COALESCE(SUM(r.total_price), 0)  AS revenue
        FROM reservations r
        JOIN groups g ON g.id = r.group_id
        WHERE r.payment_status IN ('paid','fully_paid')
          AND r.created_at BETWEEN p_from AND p_to + INTERVAL '1 day'
        GROUP BY g.state
        ORDER BY revenue DESC LIMIT 5
      ) row
    ),
    'top_groups',   (
      SELECT COALESCE(jsonb_agg(row ORDER BY row.earnings DESC), '[]')
      FROM (
        SELECT
          g.id, g.name,
          COUNT(*)                                   AS reservations,
          COALESCE(SUM(r.base_price), 0)             AS earnings,
          COALESCE(AVG(r.base_price), 0)             AS avg_booking
        FROM reservations r
        JOIN groups g ON g.id = r.group_id
        WHERE r.payment_status IN ('paid','fully_paid')
          AND r.created_at BETWEEN p_from AND p_to + INTERVAL '1 day'
        GROUP BY g.id, g.name
        ORDER BY earnings DESC LIMIT 10
      ) row
    )
  ) INTO v_result;

  RETURN v_result;
END;
$$;

GRANT EXECUTE ON FUNCTION public.admin_financial_dashboard TO authenticated;

-- ── 2. admin_held_reservations ────────────────────────────────────────────────
-- Lista reservas con pago retenido (pending release), ordenadas por evento más próximo.

CREATE OR REPLACE FUNCTION public.admin_held_reservations(
  p_limit INT DEFAULT 50
)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_caller_id UUID := auth.uid();
BEGIN
  IF NOT EXISTS (SELECT 1 FROM profiles WHERE id = v_caller_id AND role = 'admin') THEN
    RAISE EXCEPTION 'unauthorized';
  END IF;

  RETURN (
    SELECT COALESCE(jsonb_agg(row ORDER BY row.event_date ASC), '[]')
    FROM (
      SELECT
        r.id,
        r.event_date,
        r.total_price,
        r.base_price,
        r.payout_status,
        r.held_at,
        r.payment_status,
        r.mp_payment_id,
        r.cancellation_type,
        g.name  AS group_name,
        g.id    AS group_id,
        ROUND(EXTRACT(EPOCH FROM (NOW() - r.event_date::TIMESTAMPTZ)) / 3600, 1)
                AS hours_since_event,
        EXISTS (
          SELECT 1 FROM disputes d
          WHERE d.reservation_id = r.id AND d.status IN ('open','under_review')
        )       AS has_open_dispute
      FROM reservations r
      LEFT JOIN groups g ON g.id = r.group_id
      WHERE r.payout_status = 'held'
        AND r.payment_status IN ('paid','fully_paid','deposit_paid')
      ORDER BY r.event_date ASC
      LIMIT p_limit
    ) row
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.admin_held_reservations TO authenticated;

-- ── 3. admin_release_reservation (release manual) ────────────────────────────

CREATE OR REPLACE FUNCTION public.admin_release_reservation(
  p_reservation_id UUID
)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_caller_id UUID := auth.uid();
BEGIN
  IF v_caller_id IS NULL THEN RAISE EXCEPTION 'unauthorized'; END IF;
  IF NOT EXISTS (SELECT 1 FROM profiles WHERE id = v_caller_id AND role = 'admin') THEN
    RAISE EXCEPTION 'unauthorized: solo admins';
  END IF;

  RETURN release_group_earnings_atomic(p_reservation_id, v_caller_id);
END;
$$;

GRANT EXECUTE ON FUNCTION public.admin_release_reservation TO authenticated;

-- ── 4. admin_group_strikes_summary ───────────────────────────────────────────

CREATE OR REPLACE FUNCTION public.admin_group_strikes_summary(
  p_group_id UUID DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_caller_id UUID := auth.uid();
BEGIN
  IF NOT EXISTS (SELECT 1 FROM profiles WHERE id = v_caller_id AND role = 'admin') THEN
    RAISE EXCEPTION 'unauthorized';
  END IF;

  RETURN (
    SELECT COALESCE(jsonb_agg(row ORDER BY row.created_at DESC), '[]')
    FROM (
      SELECT
        gs.id, gs.group_id, gs.strike_type, gs.note,
        gs.auto_suspended, gs.created_at,
        gs.reservation_id,
        g.name AS group_name, g.strike_count, g.suspended_at
      FROM group_strikes gs
      JOIN groups g ON g.id = gs.group_id
      WHERE (p_group_id IS NULL OR gs.group_id = p_group_id)
      ORDER BY gs.created_at DESC
      LIMIT 100
    ) row
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.admin_group_strikes_summary TO authenticated;

-- ── 5. check_wallet_integrity ─────────────────────────────────────────────────
-- Detecta wallets con saldo negativo. Llamar periódicamente para auditoría.

CREATE OR REPLACE FUNCTION public.check_wallet_integrity()
RETURNS TABLE (
  group_id    UUID,
  group_name  TEXT,
  issue       TEXT,
  pending_bal NUMERIC,
  avail_bal   NUMERIC
)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
BEGIN
  -- Wallets con balance negativo
  RETURN QUERY
  SELECT
    gw.group_id,
    g.name,
    'negative_balance'::TEXT,
    gw.pending_balance,
    gw.available_balance
  FROM group_wallets gw
  JOIN groups g ON g.id = gw.group_id
  WHERE gw.pending_balance < 0 OR gw.available_balance < 0;

  -- Wallets donde pending > total pagado (inconsistencia)
  RETURN QUERY
  SELECT
    gw.group_id,
    g.name,
    'pending_exceeds_paid'::TEXT,
    gw.pending_balance,
    gw.available_balance
  FROM group_wallets gw
  JOIN groups g ON g.id = gw.group_id
  WHERE gw.pending_balance > (
    SELECT COALESCE(SUM(COALESCE(r.base_price, r.total_price * 0.9)), 0)
    FROM reservations r
    WHERE r.group_id = gw.group_id
      AND r.payout_status = 'held'
      AND r.payment_status IN ('paid','fully_paid')
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.check_wallet_integrity TO authenticated;

-- ── 6. admin_financial_audit_log ──────────────────────────────────────────────

CREATE OR REPLACE FUNCTION public.admin_financial_audit_log(
  p_entity_id   UUID    DEFAULT NULL,
  p_action      TEXT    DEFAULT NULL,
  p_limit       INT     DEFAULT 100,
  p_offset      INT     DEFAULT 0
)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_caller_id UUID := auth.uid();
  v_rows      JSONB;
  v_total     INT;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM profiles WHERE id = v_caller_id AND role = 'admin') THEN
    RAISE EXCEPTION 'unauthorized';
  END IF;

  SELECT COUNT(*) INTO v_total FROM financial_audit_logs
  WHERE (p_entity_id IS NULL OR entity_id = p_entity_id)
    AND (p_action    IS NULL OR action    = p_action);

  SELECT COALESCE(jsonb_agg(row ORDER BY row.created_at DESC), '[]') INTO v_rows
  FROM (
    SELECT id, entity_type, entity_id, action, actor_id, actor_role,
           amount, notes, created_at
    FROM financial_audit_logs
    WHERE (p_entity_id IS NULL OR entity_id = p_entity_id)
      AND (p_action    IS NULL OR action    = p_action)
    ORDER BY created_at DESC
    LIMIT p_limit OFFSET p_offset
  ) row;

  RETURN jsonb_build_object('total', v_total, 'rows', v_rows);
END;
$$;

GRANT EXECUTE ON FUNCTION public.admin_financial_audit_log TO authenticated;

SELECT '205c_admin_financial_v2.sql ejecutado ✅' AS status;
