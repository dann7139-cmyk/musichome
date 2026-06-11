-- ============================================================
-- sql/229b_backfill_wallets.sql  ← ejecutar DESPUÉS de 229a
--
-- Solo operaciones de datos (backfill).
-- Si falla, el schema de 229a ya está comprometido y es seguro
-- corregir y re-ejecutar este archivo.
-- ============================================================

-- ── 1. Backfill group_wallets para reservas pagadas sin crédito ───────────
DO $$
DECLARE
  v_row       RECORD;
  v_earnings  NUMERIC;
  v_wallet_id UUID;
  v_count     INT := 0;
BEGIN
  FOR v_row IN
    SELECT r.id, r.group_id, r.base_price, r.total_price, r.payout_status
    FROM reservations r
    WHERE r.payment_status IN ('paid','fully_paid')
      AND NOT EXISTS (
        SELECT 1 FROM wallet_transactions wt
        WHERE wt.reservation_id = r.id
          AND wt.type IN ('credit_pending','credit_available','event_earning')
      )
  LOOP
    v_earnings := COALESCE(v_row.base_price, ROUND(v_row.total_price * 0.9, 2));

    INSERT INTO group_wallets (group_id) VALUES (v_row.group_id)
    ON CONFLICT (group_id) DO NOTHING;

    SELECT id INTO v_wallet_id FROM group_wallets WHERE group_id = v_row.group_id;

    IF v_row.payout_status IN ('held','half_released') THEN
      UPDATE group_wallets SET
        pending_balance = pending_balance + (
          CASE WHEN v_row.payout_status = 'half_released'
            THEN ROUND(v_earnings/2,2) ELSE v_earnings END),
        available_balance = available_balance + (
          CASE WHEN v_row.payout_status = 'half_released'
            THEN ROUND(v_earnings/2,2) ELSE 0 END),
        total_earned = total_earned + v_earnings,
        updated_at   = NOW()
      WHERE id = v_wallet_id;
    ELSE
      UPDATE group_wallets SET
        available_balance = available_balance + (
          CASE WHEN v_row.payout_status = 'released' THEN v_earnings ELSE 0 END),
        total_earned = total_earned + v_earnings,
        updated_at   = NOW()
      WHERE id = v_wallet_id;
    END IF;

    IF v_wallet_id IS NOT NULL THEN
      INSERT INTO wallet_transactions (
        group_wallet_id, group_id, type, amount,
        reservation_id, description, balance_after
      ) VALUES (
        v_wallet_id, v_row.group_id, 'credit_pending', v_earnings,
        v_row.id,
        format('[Backfill] Pago confirmado — reserva %s', v_row.id),
        0
      );
      v_count := v_count + 1;
    END IF;

  END LOOP;
  RAISE NOTICE 'Backfill group_wallets: % reservas procesadas', v_count;
END;
$$;

-- ── 2. Backfill admin wallet desde reservas pagadas ──────────────────────
DO $$
DECLARE
  v_admin_id  UUID;
  v_total_fee NUMERIC;
BEGIN
  SELECT id INTO v_admin_id FROM profiles WHERE role = 'admin' ORDER BY created_at LIMIT 1;
  IF v_admin_id IS NULL THEN
    RAISE NOTICE 'No se encontró admin, saltando backfill';
    RETURN;
  END IF;

  INSERT INTO wallets (user_id, available_balance, pending_balance, total_earned)
  VALUES (v_admin_id, 0, 0, 0)
  ON CONFLICT (user_id) DO NOTHING;

  SELECT COALESCE(SUM(
    COALESCE(r.service_fee_amount, ROUND(r.total_price * 0.10, 2))
  ), 0)
  INTO v_total_fee
  FROM reservations r
  WHERE r.payment_status IN ('paid','fully_paid')
    AND r.payout_status != 'refunded'
    AND NOT EXISTS (
      SELECT 1 FROM wallet_transactions wt
      WHERE wt.reservation_id = r.id
        AND wt.type = 'platform_income'
        AND wt.user_id = v_admin_id
    );

  IF v_total_fee > 0 THEN
    UPDATE wallets SET
      available_balance = available_balance + v_total_fee,
      total_earned      = COALESCE(total_earned, 0) + v_total_fee,
      updated_at        = NOW()
    WHERE user_id = v_admin_id;

    INSERT INTO wallet_transactions (user_id, type, amount, reservation_id, description)
    SELECT
      v_admin_id,
      'platform_income',
      COALESCE(r.service_fee_amount, ROUND(r.total_price * 0.10, 2)),
      r.id,
      format('[Backfill] Tarifa de servicio (10%%) — reserva %s', r.id)
    FROM reservations r
    WHERE r.payment_status IN ('paid','fully_paid')
      AND r.payout_status != 'refunded'
      AND NOT EXISTS (
        SELECT 1 FROM wallet_transactions wt
        WHERE wt.reservation_id = r.id
          AND wt.type = 'platform_income'
          AND wt.user_id = v_admin_id
      );

    RAISE NOTICE 'Admin wallet backfill: $% MXN acreditado', v_total_fee;
  ELSE
    RAISE NOTICE 'Admin wallet: ya estaba al día';
  END IF;
END;
$$;

SELECT '229b_backfill_wallets.sql ejecutado ✅' AS status;
