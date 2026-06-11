-- ============================================================
-- sql/232_fix_backfill_constraint.sql
--
-- 231 falló: wallet_transactions_amount_check no permite amount < 0.
-- El ajuste salió negativo (-66.72) porque stripe_fee_amount es NULL
-- y el estimado ($336.72) es menor que el crédito original ($900).
--
-- Solución:
--   • Si ajuste > 0 → INSERT type='adjustment', amount=ajuste
--   • Si ajuste < 0 → INSERT type='debit_refund',  amount=ABS(ajuste)
-- La actualización de wallets.available_balance sigue usando
-- el valor con signo (suma o resta según sea).
-- ============================================================

DO $$
DECLARE
  v_row          RECORD;
  v_service_fee  NUMERIC;
  v_msi_fee      NUMERIC;
  v_admin_bruto  NUMERIC;
  v_stripe_fee   NUMERIC;
  v_admin_neto   NUMERIC;
  v_old_credit   NUMERIC;
  v_adjustment   NUMERIC;
  v_admin_id     UUID;
BEGIN
  SELECT id INTO v_admin_id FROM profiles WHERE role = 'admin' ORDER BY created_at LIMIT 1;
  IF v_admin_id IS NULL THEN
    RAISE NOTICE 'No se encontró admin, saltando corrección backfill';
    RETURN;
  END IF;

  FOR v_row IN
    SELECT r.*
    FROM reservations r
    WHERE r.payment_status IN ('paid','fully_paid')
      AND COALESCE(r.msi_fee_amount, 0) > 0
  LOOP
    v_service_fee := COALESCE(v_row.service_fee_amount, ROUND(v_row.total_price * 0.10, 2));
    v_msi_fee     := COALESCE(v_row.msi_fee_amount, 0);
    v_admin_bruto := v_service_fee + v_msi_fee;
    -- Usar fee real si está disponible; si no, estimado
    v_stripe_fee  := COALESCE(v_row.stripe_fee_amount,
                       ROUND((v_row.total_price + v_msi_fee) * 0.036 + 3, 2));
    v_admin_neto  := GREATEST(0, v_admin_bruto - v_stripe_fee);

    -- Lo que se acreditó en 229b: solo service_fee, sin MSI ni descuento Stripe
    v_old_credit  := v_service_fee;
    v_adjustment  := v_admin_neto - v_old_credit;

    -- Guardar group_earnings en la reserva (para que release_half y release_atomic lo usen)
    UPDATE reservations SET
      group_earnings     = COALESCE(group_earnings,
                             COALESCE(base_price, ROUND(total_price * 0.9, 2))),
      service_fee_amount = v_service_fee,
      updated_at         = NOW()
    WHERE id = v_row.id;

    IF v_adjustment <> 0 THEN
      -- Ajustar saldo admin wallet (signo correcto: suma si >0, resta si <0)
      UPDATE wallets SET
        available_balance = GREATEST(0, available_balance + v_adjustment),
        total_earned      = GREATEST(0, COALESCE(total_earned, 0) + v_adjustment),
        updated_at        = NOW()
      WHERE user_id = v_admin_id;

      -- INSERT siempre con amount > 0; tipo indica dirección
      INSERT INTO wallet_transactions (user_id, type, amount, reservation_id, description)
      VALUES (
        v_admin_id,
        CASE WHEN v_adjustment > 0 THEN 'adjustment' ELSE 'debit_refund' END,
        ABS(v_adjustment),
        v_row.id,
        format('[Corrección 232] bruto=$%s stripe=$%s neto=$%s ajuste=$%s — reserva %s',
          v_admin_bruto::TEXT, v_stripe_fee::TEXT,
          v_admin_neto::TEXT,  v_adjustment::TEXT,
          v_row.id)
      );

      RAISE NOTICE 'Reserva %: wallet ajustado $% (bruto=$%, stripe=$%, neto=$%)',
        v_row.id, v_adjustment, v_admin_bruto, v_stripe_fee, v_admin_neto;
    ELSE
      RAISE NOTICE 'Reserva %: sin ajuste necesario', v_row.id;
    END IF;
  END LOOP;
END;
$$;

SELECT '232_fix_backfill_constraint.sql ejecutado ✅' AS status;
