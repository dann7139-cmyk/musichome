-- ============================================================
-- sql/509_finance_hardening_beta.sql
-- 🔒 CORRECCIONES DE ALTA PRIORIDAD (auditoría financiera 2026-07-18)
--
--  1. confirm_full_payment_and_credit_wallet: GUARD de canceladas —
--     un pago que llega DESPUÉS de cancelar ya NO acredita al grupo:
--     queda payment_status='paid' + payout_status='blocked' y avisa
--     al admin para reembolsar. (Cierra el hueco: cancelada pagada
--     tarde → cron la liberaba.)
--  2. calculate_final_price: UN SOLO modelo de comisión en toda la
--     app — markup 20% (igual que cotizaciones, triggers sql/402 y
--     el RPC de pago). Antes la reserva directa cobraba 7-10%.
--     Mismas llaves JSON: el frontend no cambia.
--  3. admin_alerts + admin_financial_dashboard: el contador de
--     retiros pendientes ahora lee withdrawals (la tabla REAL).
--  4. Retiro del camino legacy: payout_requests verificado SIN
--     dependencias activas (la app usa withdrawals desde sql/460;
--     admin_complete_payout unificado en sql/468/469; el dashboard
--     del grupo v3 usa withdrawals desde sql/508). Se eliminan sus
--     RPCs muertos y la tabla.
--
--  La separación grupo/plataforma NO se toca: el grupo sigue viendo
--  solo "tu ganancia".
-- ============================================================

BEGIN;

-- ════════════════════════════════════════════════════════════
-- 1. Acreditación con guard de canceladas (base = sql/459 intacta)
-- ════════════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION public.confirm_full_payment_and_credit_wallet(
  p_reservation_id UUID,
  p_mp_payment_id  TEXT,
  p_amount_paid    NUMERIC DEFAULT NULL,
  p_stripe_fee     NUMERIC DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_reservation  RECORD;
  v_wallet_id    UUID;
  v_earnings     NUMERIC;
  v_service_fee  NUMERIC;
  v_msi_fee      NUMERIC;
  v_admin_bruto  NUMERIC;
  v_stripe_fee   NUMERIC;
  v_admin_neto   NUMERIC;
  v_admin_id     UUID;
  v_currency     TEXT;
BEGIN
  SELECT * INTO v_reservation
  FROM reservations WHERE id = p_reservation_id FOR UPDATE;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'reservation_not_found');
  END IF;

  IF v_reservation.payment_status IN ('paid','fully_paid') THEN
    RETURN jsonb_build_object('ok', true, 'skipped', true, 'reason', 'already_paid');
  END IF;

  -- 🚫 GUARD NUEVO [509]: pago tardío de una reserva ya cancelada/terminal.
  -- NO se acredita al grupo. Se registra el pago BLOQUEADO y se avisa al
  -- admin para reembolsar al cliente.
  IF v_reservation.status IN ('cancelled', 'rejected', 'expired') THEN
    UPDATE reservations SET
      payment_status = 'paid',
      payout_status  = 'blocked',
      mp_payment_id  = p_mp_payment_id,
      stripe_fee_amount = COALESCE(p_stripe_fee, stripe_fee_amount),
      updated_at     = NOW()
    WHERE id = p_reservation_id;

    INSERT INTO financial_audit_logs
      (entity_type, entity_id, action, actor_id, actor_role, amount, notes)
    VALUES ('reservation', p_reservation_id, 'late_payment_blocked', NULL, 'system',
      COALESCE(v_reservation.total_price, 0),
      format('Pago recibido con reserva en estado %s — NO acreditado; requiere reembolso. pago=%s',
        v_reservation.status, p_mp_payment_id));

    INSERT INTO notifications (user_id, type, title, body, data)
    SELECT p.id, 'reservation',
      '🚨 Pago recibido de reserva cancelada',
      format('La reserva %s estaba %s cuando llegó el pago. El dinero quedó BLOQUEADO (no se acreditó al grupo). Procesa el reembolso al cliente.',
        COALESCE(v_reservation.folio, p_reservation_id::TEXT), v_reservation.status),
      jsonb_build_object('reservation_id', p_reservation_id, 'screen', 'AdminFinancial')
    FROM profiles p WHERE p.role = 'admin';

    RETURN jsonb_build_object('ok', false, 'blocked', true,
      'reason', 'reservation_' || v_reservation.status);
  END IF;

  v_currency    := COALESCE(v_reservation.currency_code, 'MXN');

  -- Modelo markup 20%: grupo recibe base_price (su neto).
  -- Fallback cuando base_price no está guardado: total_price / 1.20.
  v_earnings    := COALESCE(v_reservation.base_price,
                     ROUND(v_reservation.total_price / 1.20, 2));
  v_service_fee := COALESCE(v_reservation.service_fee_amount,
                     v_reservation.total_price - ROUND(v_reservation.total_price / 1.20, 2));
  v_msi_fee     := COALESCE(v_reservation.msi_fee_amount, 0);
  v_admin_bruto := v_service_fee + v_msi_fee;
  v_stripe_fee  := COALESCE(
                     p_stripe_fee,
                     COALESCE(v_reservation.stripe_fee_amount,
                       ROUND((v_reservation.total_price + v_msi_fee) * 0.036 + 3, 2))
                   );
  v_admin_neto  := GREATEST(0, v_admin_bruto - v_stripe_fee);

  PERFORM ensure_group_wallet(v_reservation.group_id);
  SELECT id INTO v_wallet_id FROM group_wallets WHERE group_id = v_reservation.group_id;

  IF v_currency = 'USD' THEN
    UPDATE group_wallets SET
      pending_balance_usd = pending_balance_usd + v_earnings,
      total_earned_usd    = total_earned_usd    + v_earnings,
      updated_at          = NOW()
    WHERE id = v_wallet_id;
  ELSE
    UPDATE group_wallets SET
      pending_balance = pending_balance + v_earnings,
      total_earned    = total_earned    + v_earnings,
      updated_at      = NOW()
    WHERE id = v_wallet_id;
  END IF;

  UPDATE reservations SET
    payment_status     = 'paid',
    payout_status      = 'held',
    held_at            = NOW(),
    mp_payment_id      = p_mp_payment_id,
    stripe_fee_amount  = COALESCE(p_stripe_fee, stripe_fee_amount),
    service_fee_amount = v_service_fee,
    group_earnings     = v_earnings,
    updated_at         = NOW()
  WHERE id = p_reservation_id;

  INSERT INTO wallet_transactions (
    group_wallet_id, group_id, type, amount,
    reservation_id, description, balance_after, currency_code
  )
  SELECT gw.id, gw.group_id, 'credit_pending', v_earnings,
    p_reservation_id,
    format('Pago confirmado — reserva %s', p_reservation_id),
    CASE WHEN v_currency = 'USD' THEN gw.pending_balance_usd ELSE gw.pending_balance END,
    v_currency
  FROM group_wallets gw WHERE gw.id = v_wallet_id;

  SELECT id INTO v_admin_id FROM profiles WHERE role = 'admin' ORDER BY created_at LIMIT 1;
  IF v_admin_id IS NOT NULL THEN
    INSERT INTO wallets (user_id, available_balance, pending_balance, total_earned)
    VALUES (v_admin_id, 0, 0, 0)
    ON CONFLICT (user_id) DO NOTHING;

    IF v_currency = 'USD' THEN
      UPDATE wallets SET
        available_balance_usd = available_balance_usd + v_admin_neto,
        total_earned_usd      = COALESCE(total_earned_usd, 0) + v_admin_neto,
        updated_at            = NOW()
      WHERE user_id = v_admin_id;
    ELSE
      UPDATE wallets SET
        available_balance = available_balance + v_admin_neto,
        total_earned      = COALESCE(total_earned, 0) + v_admin_neto,
        updated_at        = NOW()
      WHERE user_id = v_admin_id;
    END IF;

    INSERT INTO wallet_transactions (user_id, type, amount, reservation_id, description, currency_code)
    VALUES (v_admin_id, 'platform_income', v_admin_neto, p_reservation_id,
      format('Comisión $%s + MSI $%s − Stripe $%s = $%s neto — reserva %s',
        v_service_fee::TEXT, v_msi_fee::TEXT,
        v_stripe_fee::TEXT, v_admin_neto::TEXT,
        p_reservation_id),
      v_currency);
  END IF;

  INSERT INTO financial_audit_logs
    (entity_type, entity_id, action, actor_id, actor_role, amount, notes)
  VALUES ('reservation', p_reservation_id, 'hold', NULL, 'system', v_earnings,
    format('currency=%s group=%s svc=%s msi=%s stripe=%s admin_neto=%s',
      v_currency, v_earnings, v_service_fee, v_msi_fee, v_stripe_fee, v_admin_neto));

  INSERT INTO notifications (user_id, type, title, body, data)
  SELECT g.owner_id, 'payment',
    '💰 Pago confirmado — retenido hasta el evento',
    format('El cliente pagó tu evento del %s. $%s MXN quedaron reservados y se liberan cuando el grupo llegue y al terminar el evento.',
      v_reservation.event_date::TEXT,
      to_char(v_earnings, 'FM999,999,990')),
    jsonb_build_object('reservation_id', p_reservation_id, 'amount', v_earnings, 'screen', 'Wallet')
  FROM groups g
  WHERE g.id = v_reservation.group_id AND g.owner_id IS NOT NULL;

  RETURN jsonb_build_object(
    'ok',             true,
    'currency',       v_currency,
    'group_earnings', v_earnings,
    'service_fee',    v_service_fee,
    'msi_fee',        v_msi_fee,
    'admin_bruto',    v_admin_bruto,
    'stripe_fee',     v_stripe_fee,
    'admin_neto',     v_admin_neto
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.confirm_full_payment_and_credit_wallet(UUID, TEXT, NUMERIC, NUMERIC)
  TO authenticated, service_role;

-- ════════════════════════════════════════════════════════════
-- 2. UN solo modelo de comisión: markup 20% (mismas llaves JSON)
-- ════════════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION public.calculate_final_price(
  p_base_price NUMERIC,
  p_is_express BOOLEAN DEFAULT FALSE,
  p_state      TEXT    DEFAULT NULL,
  p_city       TEXT    DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_commission  NUMERIC(12,2);
  v_final       NUMERIC(12,2);
BEGIN
  IF p_base_price IS NULL OR p_base_price < 0 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_base_price');
  END IF;

  -- 🎯 MODELO ÚNICO [509]: markup 20% en TODA la app (igual que
  -- cotizaciones, propuestas, triggers sql/402 y el RPC de pago).
  -- Antes esta ruta (reserva directa) cobraba 7-10% con
  -- get_commission_rate — dos márgenes distintos conviviendo.
  v_commission := ROUND(p_base_price * 0.20, 2);
  v_final      := p_base_price + v_commission;

  RETURN jsonb_build_object(
    'ok',                true,
    'base_price',        p_base_price,
    'commission_rate',   20,
    'commission_amount', v_commission,
    'final_price',       v_final,
    'group_earnings',    p_base_price,
    'multiplier',        1.0,
    'is_express',        COALESCE(p_is_express, false)
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.calculate_final_price(NUMERIC, BOOLEAN, TEXT, TEXT)
  TO authenticated, anon;

-- ════════════════════════════════════════════════════════════
-- 3a. admin_alerts: retiros pendientes desde withdrawals (tabla REAL)
-- ════════════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION public.admin_alerts()
RETURNS JSONB LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM profiles WHERE id = auth.uid() AND role = 'admin') THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_admin');
  END IF;

  RETURN jsonb_build_object(
    'ok', true,
    -- 💸 FIX [509]: withdrawals, no payout_requests (huérfana)
    'retiros_pendientes', (
      SELECT COUNT(*) FROM withdrawals WHERE status = 'pending'),
    'fees_no_capturados', (
      SELECT COUNT(*) FROM reservations
      WHERE payment_status IN ('paid','fully_paid','deposit_paid')
        AND stripe_fee_amount IS NULL),
    'sin_pais', (
      (SELECT COUNT(*) FROM groups WHERE country IS NULL)
      + (SELECT COUNT(*) FROM profiles WHERE role = 'talent' AND country IS NULL)),
    'grupos_suspendidos', (
      SELECT COUNT(*) FROM groups WHERE suspended_at IS NOT NULL),
    'disputas_abiertas', (
      SELECT COUNT(*) FROM disputes WHERE status IN ('open', 'under_review')),
    'reembolsos_pendientes', (
      SELECT COUNT(*) FROM manual_refunds WHERE status = 'pending'),
    'eventos_sin_cerrar', (
      SELECT COUNT(*) FROM reservations
      WHERE status = 'in_progress'
        AND event_date < (NOW() AT TIME ZONE 'America/Mexico_City')::date),
    'pagos_retenidos_viejos', (
      SELECT COUNT(*) FROM reservations
      WHERE payout_status = 'held'
        AND payment_status IN ('paid','fully_paid','deposit_paid')
        AND status = 'completed'
        AND held_at IS NOT NULL
        AND held_at < NOW() - INTERVAL '3 days')
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.admin_alerts() TO authenticated;

-- ════════════════════════════════════════════════════════════
-- 3b. admin_financial_dashboard: pending_payouts desde withdrawals
--     (cuerpo íntegro de sql/205c; SOLO cambia esa subconsulta)
-- ════════════════════════════════════════════════════════════
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
    -- 💸 FIX [509]: withdrawals, no payout_requests (huérfana)
    'pending_payouts', (
      SELECT jsonb_build_object(
        'count',  COUNT(*),
        'amount', COALESCE(SUM(amount), 0)
      ) FROM withdrawals WHERE status = 'pending'
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

-- ════════════════════════════════════════════════════════════
-- 4. Retirar el camino legacy payout_requests
--    VERIFICADO sin dependencias activas:
--    · App/EFs: cero referencias (solo un comentario viejo)
--    · request_withdrawal escribe withdrawals (sql/460)
--    · admin_complete_payout opera withdrawals (sql/468/469)
--    · group_performance_dashboard v3 lee withdrawals (sql/508)
--    · admin_alerts y admin_financial_dashboard corregidos arriba
-- ════════════════════════════════════════════════════════════
DROP FUNCTION IF EXISTS public.request_payout(NUMERIC, TEXT, TEXT);
DROP FUNCTION IF EXISTS public.request_payout(NUMERIC, TEXT, TEXT, TEXT);
DROP FUNCTION IF EXISTS public.approve_payout(UUID, TEXT);
DROP FUNCTION IF EXISTS public.approve_payout(UUID, TEXT, TEXT);
DROP FUNCTION IF EXISTS public.admin_payout_queue(TEXT);
DROP TABLE IF EXISTS public.payout_requests CASCADE;

COMMIT;

-- ── VERIFICACIÓN ──────────────────────────────────────────────────────────────
SELECT prosrc LIKE '%late_payment_blocked%' AS guard_canceladas
FROM pg_proc WHERE proname = 'confirm_full_payment_and_credit_wallet';
-- Esperado: true

SELECT (calculate_final_price(1000)->>'final_price')::NUMERIC AS precio_1000;
-- Esperado: 1200 (markup 20% único)

SELECT prosrc LIKE '%FROM withdrawals%' AS alertas_withdrawals
FROM pg_proc WHERE proname = 'admin_alerts';
-- Esperado: true

SELECT COUNT(*) AS payout_requests_restante
FROM information_schema.tables WHERE table_name = 'payout_requests';
-- Esperado: 0

SELECT '509_finance_hardening_beta.sql ejecutado ✅' AS status;
