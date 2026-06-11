-- ============================================================
-- sql/228_fix_balance_after_nullable.sql
--
-- 227 falló porque balance_after es NOT NULL.
-- Admin no tiene un "saldo de cuenta" natural, así que lo
-- hacemos nullable y re-ejecutamos solo el backfill admin.
-- ============================================================

-- ── 1. Hacer balance_after nullable ───────────────────────────────────────
ALTER TABLE wallet_transactions
  ALTER COLUMN balance_after DROP NOT NULL;

-- ── 2. Re-ejecutar backfill admin (el grupo ya se acreditó en 227) ────────
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

  -- Asegurar que el admin tiene wallet
  INSERT INTO wallets (user_id, available_balance, pending_balance, total_earned)
  VALUES (v_admin_id, 0, 0, 0)
  ON CONFLICT (user_id) DO NOTHING;

  -- Sumar solo las reservas sin transacción platform_income
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

SELECT '228_fix_balance_after_nullable.sql ejecutado ✅' AS status;
