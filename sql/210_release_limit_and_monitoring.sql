-- 210_release_limit_and_monitoring.sql
-- 1. release_all_eligible_payments con LIMIT 500 (evita timeout con muchos eventos)
-- 2. RPCs de monitoreo financiero para admin
-- Requiere: 205a, 205d aplicados.

-- ══════════════════════════════════════════════════════════════════════════════
-- 1. release_all_eligible_payments v3 — LIMIT 500 + batch logging
-- ══════════════════════════════════════════════════════════════════════════════
-- Problema anterior: iteraba TODOS los registros held sin límite.
-- Con 10k eventos simultáneos la función superaba el timeout de 30s de Postgres.
-- Solución: procesar máximo 500 por ejecución, el cron horario hace el resto.

-- Drop versiones previas para evitar conflictos de firma o return type
DROP FUNCTION IF EXISTS public.release_all_eligible_payments();
DROP FUNCTION IF EXISTS public.check_wallet_integrity();
DROP FUNCTION IF EXISTS public.get_held_events_pending_release();
DROP FUNCTION IF EXISTS public.get_payment_mismatches(INT);

CREATE OR REPLACE FUNCTION public.release_all_eligible_payments(
  p_limit INT DEFAULT 500
)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_row      RECORD;
  v_released INT := 0;
  v_skipped  INT := 0;
  v_errors   INT := 0;
  v_result   JSONB;
  v_cutoff   TIMESTAMPTZ;
  v_start    TIMESTAMPTZ := clock_timestamp();
BEGIN
  FOR v_row IN
    SELECT r.id, r.event_date, r.event_time
    FROM reservations r
    WHERE r.payment_status IN ('paid', 'fully_paid', 'deposit_paid')
      AND r.payout_status = 'held'
      AND r.event_date IS NOT NULL
      AND NOT EXISTS (
        SELECT 1 FROM disputes d
        WHERE d.reservation_id = r.id AND d.status IN ('open', 'under_review')
      )
    ORDER BY r.event_date ASC   -- liberar los más antiguos primero
    LIMIT p_limit
    FOR UPDATE SKIP LOCKED
  LOOP
    v_cutoff := (
      (v_row.event_date::TEXT || ' ' ||
       COALESCE(v_row.event_time::TEXT, '23:59:59'))::TIMESTAMP
      AT TIME ZONE 'America/Mexico_City'
    ) + INTERVAL '12 hours';

    IF v_cutoff < NOW() THEN
      BEGIN
        v_result := release_group_earnings_atomic(v_row.id, NULL);
        IF (v_result->>'ok')::BOOLEAN AND NOT (v_result->>'skipped')::BOOLEAN THEN
          v_released := v_released + 1;
        ELSE
          v_skipped := v_skipped + 1;
        END IF;
      EXCEPTION WHEN OTHERS THEN
        v_errors := v_errors + 1;
        RAISE WARNING '[release_all] Error en reserva %: %', v_row.id, SQLERRM;
      END;
    END IF;
  END LOOP;

  RAISE NOTICE '[release_all] released=% skipped=% errors=% duration_ms=%',
    v_released, v_skipped, v_errors,
    EXTRACT(EPOCH FROM (clock_timestamp() - v_start)) * 1000;

  RETURN jsonb_build_object(
    'ok',        true,
    'released',  v_released,
    'skipped',   v_skipped,
    'errors',    v_errors,
    'limit_used', p_limit,
    'duration_ms', ROUND(EXTRACT(EPOCH FROM (clock_timestamp() - v_start)) * 1000)
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.release_all_eligible_payments(INT) TO service_role;

-- ══════════════════════════════════════════════════════════════════════════════
-- 2. check_wallet_integrity — detecta inconsistencias financieras
-- ══════════════════════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION public.check_wallet_integrity()
RETURNS TABLE (
  issue_type   TEXT,
  group_id     UUID,
  wallet_id    UUID,
  detail       TEXT,
  amount       NUMERIC
)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
BEGIN
  -- A) Wallets con balance negativo
  RETURN QUERY
  SELECT
    'negative_balance'::TEXT,
    gw.group_id,
    gw.id,
    format('pending=%.2f available=%.2f', gw.pending_balance, gw.available_balance),
    LEAST(gw.pending_balance, gw.available_balance)
  FROM group_wallets gw
  WHERE gw.pending_balance < 0 OR gw.available_balance < 0;

  -- B) Reservas paid sin wallet credit (payout_status='held' pero sin wallet_transaction)
  RETURN QUERY
  SELECT
    'paid_no_wallet_credit'::TEXT,
    r.group_id,
    NULL::UUID,
    format('reservation=%s payment_status=%s held_at=%s', r.id, r.payment_status, r.held_at),
    r.group_earnings
  FROM reservations r
  WHERE r.payment_status IN ('paid', 'fully_paid', 'deposit_paid')
    AND r.payout_status = 'held'
    AND NOT EXISTS (
      SELECT 1 FROM wallet_transactions wt
      WHERE wt.reservation_id = r.id AND wt.type = 'credit_pending'
    );

  -- C) Wallet released pero payout_status sigue 'held'
  RETURN QUERY
  SELECT
    'released_but_held'::TEXT,
    r.group_id,
    NULL::UUID,
    format('reservation=%s released_at=%s payout_status=%s', r.id, r.released_at, r.payout_status),
    r.group_earnings
  FROM reservations r
  WHERE r.released_at IS NOT NULL
    AND r.payout_status = 'held';

  -- D) Doble crédito (más de un credit_pending por reserva)
  RETURN QUERY
  SELECT
    'double_credit'::TEXT,
    r.group_id,
    NULL::UUID,
    format('reservation=%s credit_count=%s', r.id, COUNT(wt.id)),
    SUM(wt.amount)
  FROM wallet_transactions wt
  JOIN reservations r ON r.id = wt.reservation_id
  WHERE wt.type = 'credit_pending'
  GROUP BY r.id, r.group_id
  HAVING COUNT(wt.id) > 1;

  -- E) available_balance > total_earned (imposible aritméticamente)
  RETURN QUERY
  SELECT
    'available_exceeds_total'::TEXT,
    gw.group_id,
    gw.id,
    format('available=%.2f total_earned=%.2f', gw.available_balance, gw.total_earned),
    gw.available_balance - gw.total_earned
  FROM group_wallets gw
  WHERE gw.available_balance > gw.total_earned + 1; -- +1 por rounding
END;
$$;

GRANT EXECUTE ON FUNCTION public.check_wallet_integrity TO authenticated;

-- ══════════════════════════════════════════════════════════════════════════════
-- 3. get_held_events_pending_release — cola de eventos listos para liberar
-- ══════════════════════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION public.get_held_events_pending_release()
RETURNS TABLE (
  reservation_id  UUID,
  group_id        UUID,
  group_name      TEXT,
  event_date      DATE,
  event_time      TIME,
  group_earnings  NUMERIC,
  held_at         TIMESTAMPTZ,
  release_eligible_at TIMESTAMPTZ,
  hours_until_release NUMERIC
)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
BEGIN
  RETURN QUERY
  SELECT
    r.id,
    r.group_id,
    g.name::TEXT,
    r.event_date::DATE,
    r.event_time::TIME,
    r.group_earnings,
    r.held_at,
    (
      (r.event_date::TEXT || ' ' || COALESCE(r.event_time::TEXT, '23:59:59'))::TIMESTAMP
      AT TIME ZONE 'America/Mexico_City'
    ) + INTERVAL '12 hours' AS release_eligible_at,
    ROUND(
      EXTRACT(EPOCH FROM (
        (
          (r.event_date::TEXT || ' ' || COALESCE(r.event_time::TEXT, '23:59:59'))::TIMESTAMP
          AT TIME ZONE 'America/Mexico_City'
        ) + INTERVAL '12 hours' - NOW()
      )) / 3600.0,
      1
    ) AS hours_until_release
  FROM reservations r
  JOIN groups g ON g.id = r.group_id
  WHERE r.payment_status IN ('paid', 'fully_paid', 'deposit_paid')
    AND r.payout_status = 'held'
    AND r.event_date IS NOT NULL
  ORDER BY release_eligible_at ASC;
END;
$$;

GRANT EXECUTE ON FUNCTION public.get_held_events_pending_release TO authenticated;

-- ══════════════════════════════════════════════════════════════════════════════
-- 4. get_payment_mismatches — pagos con monto diferente al esperado
-- ══════════════════════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION public.get_payment_mismatches(
  p_days INT DEFAULT 30
)
RETURNS TABLE (
  reservation_id   UUID,
  mp_payment_id    TEXT,
  expected_amount  NUMERIC,
  actual_amount    NUMERIC,
  difference       NUMERIC,
  created_at       TIMESTAMPTZ
)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
BEGIN
  RETURN QUERY
  SELECT
    pel.reservation_id,
    pel.mp_payment_id,
    pel.expected_amount,
    pel.mp_amount,
    ABS(pel.mp_amount - pel.expected_amount),
    pel.created_at
  FROM payment_event_logs pel
  WHERE pel.is_mismatch = TRUE
    AND pel.created_at >= NOW() - (p_days || ' days')::INTERVAL
  ORDER BY pel.created_at DESC;
END;
$$;

GRANT EXECUTE ON FUNCTION public.get_payment_mismatches TO authenticated;

-- ══════════════════════════════════════════════════════════════════════════════
-- 5. Índice para acelerar release_all_eligible_payments
-- ══════════════════════════════════════════════════════════════════════════════
-- Sin este índice, con 100k reservas el WHERE hace full table scan cada hora.

CREATE INDEX IF NOT EXISTS idx_res_release_eligible
  ON reservations(event_date ASC)
  WHERE payout_status = 'held'
    AND payment_status IN ('paid', 'fully_paid', 'deposit_paid')
    AND event_date IS NOT NULL;

SELECT '210_release_limit_and_monitoring.sql ejecutado ✅' AS status;
