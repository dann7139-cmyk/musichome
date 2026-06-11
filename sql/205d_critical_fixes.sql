-- 205d_critical_fixes.sql
-- Fix 3: Auto-release usa zona horaria México en lugar de UTC medianoche.
-- Fix 4: process_refund_reversal acepta p_refund_amount para reembolsos parciales.
-- Requiere: 205a aplicado.

-- ── Fix 3: release_all_eligible_payments con timezone México ──────────────────
-- Antes: event_date::TIMESTAMPTZ + 12h = medianoche UTC + 12h = mediodía UTC,
--        que puede ser ANTES de que empiece el evento en México (UTC-6 / UTC-5 CDT).
-- Ahora: interpreta event_date como fecha en 'America/Mexico_City',
--        asume hora de inicio conservadora 23:59 (si no hay event_time),
--        y libera 12 horas después de eso.

CREATE OR REPLACE FUNCTION public.release_all_eligible_payments()
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_row      RECORD;
  v_released INT := 0;
  v_skipped  INT := 0;
  v_result   JSONB;
  v_cutoff   TIMESTAMPTZ;
BEGIN
  FOR v_row IN
    SELECT r.id, r.event_date, r.event_time
    FROM reservations r
    WHERE r.payment_status IN ('paid','fully_paid','deposit_paid')
      AND r.payout_status = 'held'
      AND r.event_date IS NOT NULL
      AND NOT EXISTS (
        SELECT 1 FROM disputes d
        WHERE d.reservation_id = r.id AND d.status IN ('open','under_review')
      )
    FOR UPDATE SKIP LOCKED
  LOOP
    -- Construir el timestamp del evento en zona horaria de México.
    -- Si hay event_time, lo usamos; si no, asumimos fin de día (23:59:59).
    -- El cutoff para release es 12 horas después del inicio del evento.
    v_cutoff := (
      (v_row.event_date::TEXT || ' ' ||
       COALESCE(v_row.event_time::TEXT, '23:59:59'))::TIMESTAMP
      AT TIME ZONE 'America/Mexico_City'
    ) + INTERVAL '12 hours';

    IF v_cutoff < NOW() THEN
      v_result := release_group_earnings_atomic(v_row.id, NULL);
      IF (v_result->>'ok')::BOOLEAN AND NOT (v_result->>'skipped')::BOOLEAN THEN
        v_released := v_released + 1;
      ELSE
        v_skipped := v_skipped + 1;
      END IF;
    END IF;
  END LOOP;

  RETURN jsonb_build_object('ok', true, 'released', v_released, 'skipped', v_skipped);
END;
$$;

GRANT EXECUTE ON FUNCTION public.release_all_eligible_payments TO service_role;

-- ── Fix 4: process_refund_reversal con p_refund_amount ────────────────────────
-- Antes: siempre revertía base_price completo sin importar el monto reembolsado.
-- Ahora: acepta p_refund_amount (el monto real devuelto a MP), calcula la
--        proporción correspondiente del base_price para revertir del wallet.
--
-- Lógica de cálculo proporcional:
--   Si total_price > 0:
--     wallet_reversal = base_price * (refund_amount / total_price)
--   Fallback (total_price = 0 o NULL):
--     wallet_reversal = refund_amount

-- Eliminar la versión anterior (2 params) para poder redefinir con firma nueva (3 params).
DROP FUNCTION IF EXISTS public.process_refund_reversal(UUID, TEXT);

CREATE OR REPLACE FUNCTION public.process_refund_reversal(
  p_reservation_id UUID,
  p_mp_refund_id   TEXT    DEFAULT NULL,
  p_refund_amount  NUMERIC DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_reservation RECORD;
  v_wallet      RECORD;
  v_reversal    NUMERIC;
  v_refund_pct  NUMERIC;
BEGIN
  SELECT * INTO v_reservation
  FROM reservations WHERE id = p_reservation_id FOR UPDATE;

  IF NOT FOUND THEN RETURN jsonb_build_object('ok', false, 'error', 'not_found'); END IF;

  IF v_reservation.payout_status = 'refunded' THEN
    RETURN jsonb_build_object('ok', true, 'skipped', true, 'reason', 'already_refunded');
  END IF;

  -- Calcular cuánto revertir del wallet del grupo.
  -- Si se pasó un monto parcial, calculamos la proporción relativa al total.
  IF p_refund_amount IS NOT NULL
     AND v_reservation.total_price IS NOT NULL
     AND v_reservation.total_price > 0
  THEN
    -- Revertir proporcionalmente: si se reembolsó el 50% del total, revertir 50% de base_price
    v_refund_pct := LEAST(p_refund_amount / v_reservation.total_price, 1.0);
    v_reversal   := ROUND(
      COALESCE(v_reservation.base_price, ROUND(v_reservation.total_price * 0.9, 2)) * v_refund_pct,
      2
    );
  ELSE
    -- Fallback: reembolso completo (comportamiento anterior)
    v_reversal := COALESCE(
      v_reservation.base_price,
      ROUND(v_reservation.total_price * 0.9, 2)
    );
  END IF;

  SELECT * INTO v_wallet
  FROM group_wallets WHERE group_id = v_reservation.group_id FOR UPDATE;

  IF FOUND THEN
    UPDATE group_wallets SET
      pending_balance = GREATEST(0, pending_balance - v_reversal),
      total_earned    = GREATEST(0, total_earned    - v_reversal),
      updated_at      = NOW()
    WHERE id = v_wallet.id;

    INSERT INTO wallet_transactions (
      group_wallet_id, group_id, type, amount,
      reservation_id, description, balance_after
    ) VALUES (
      v_wallet.id, v_reservation.group_id, 'debit_refund', v_reversal,
      p_reservation_id,
      format('Reversión reembolso%s — $%s de reserva %s',
        CASE WHEN p_mp_refund_id IS NOT NULL THEN format(' MP:%s', p_mp_refund_id) ELSE '' END,
        v_reversal,
        p_reservation_id),
      GREATEST(0, v_wallet.pending_balance - v_reversal)
    );
  END IF;

  -- Solo marcar como 'refunded' si el reembolso cubre el total (reembolso completo).
  -- En reembolsos parciales mantenemos el status actual para que se pueda reembolsar el resto.
  IF p_refund_amount IS NULL
     OR (v_reservation.total_price IS NOT NULL AND p_refund_amount >= v_reservation.total_price - 1)
  THEN
    UPDATE reservations SET
      payment_status = 'refunded',
      payout_status  = 'refunded',
      updated_at     = NOW()
    WHERE id = p_reservation_id;
  ELSE
    -- Reembolso parcial: actualizar solo el payout_status sin cambiar payment_status
    UPDATE reservations SET
      updated_at = NOW()
    WHERE id = p_reservation_id;
  END IF;

  INSERT INTO financial_audit_logs (
    entity_type, entity_id, action, actor_id, actor_role, amount, notes
  ) VALUES (
    'reservation', p_reservation_id, 'refund',
    NULL, 'system', v_reversal,
    format('Refund reversal — MP refund %s | client_amount=%s | wallet_reversal=%s',
      COALESCE(p_mp_refund_id, 'manual'),
      COALESCE(p_refund_amount::TEXT, 'full'),
      v_reversal)
  );

  RAISE NOTICE '[REFUND_REVERSED] reservation=% amount=% mp_refund=% partial=%',
    p_reservation_id, v_reversal, COALESCE(p_mp_refund_id, 'n/a'),
    (p_refund_amount IS NOT NULL AND p_refund_amount < v_reservation.total_price);

  RETURN jsonb_build_object('ok', true, 'reversed', v_reversal, 'partial', p_refund_amount IS NOT NULL);
END;
$$;

GRANT EXECUTE ON FUNCTION public.process_refund_reversal TO authenticated, service_role;

SELECT '205d_critical_fixes.sql ejecutado ✅' AS status;
