-- ============================================================
-- sql/231_fix_msi_commission.sql  (Opción 1)
--
-- Modelo de reparto:
--   charge_amount  = total_price + msi_fee_amount    ($9,270)
--   group_earnings = total_price * 0.90              ($8,100)  ← lo que cotizó
--   service_fee    = total_price * 0.10              ($900)    ← comisión plataforma
--   msi_fee        = msi_fee_amount                  ($270)    ← 100% plataforma
--   admin_bruto    = service_fee + msi_fee           ($1,170)
--   stripe_fee     = real (p_stripe_fee) o estimado  ($444.36)
--   admin_neto     = admin_bruto - stripe_fee        ($725.64) ← saldo en billetera
--   COMPROBACIÓN:  $8,100 + $1,170 = $9,270 ✓
--
-- Qué cambia respecto a 229a:
--   • v_service_fee sigue siendo 10% de total_price (base, sin cambio)
--   • v_msi_fee = msi_fee_amount se suma al crédito del admin
--   • Stripe fee se descuenta del crédito admin → billetera muestra neto
--   • group_earnings guardado en reservations para que release use dato correcto
--   • get_admin_financial_overview actualizado con ganancia_bruta=$1,170 / neta=$725.64
-- ============================================================

-- ── 1. confirm_full_payment_and_credit_wallet v5 ──────────────────────────
DROP FUNCTION IF EXISTS public.confirm_full_payment_and_credit_wallet(UUID, TEXT, NUMERIC, NUMERIC);

CREATE OR REPLACE FUNCTION public.confirm_full_payment_and_credit_wallet(
  p_reservation_id UUID,
  p_mp_payment_id  TEXT,
  p_amount_paid    NUMERIC DEFAULT NULL,
  p_stripe_fee     NUMERIC DEFAULT NULL   -- fee real de Stripe (balance_transaction)
)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_reservation  RECORD;
  v_wallet_id    UUID;
  v_earnings     NUMERIC;   -- 90% precio base → grupo
  v_service_fee  NUMERIC;   -- 10% precio base → plataforma
  v_msi_fee      NUMERIC;   -- recargo MSI → plataforma (100%)
  v_admin_bruto  NUMERIC;   -- service_fee + msi_fee
  v_stripe_fee   NUMERIC;   -- fee real o estimado
  v_admin_neto   NUMERIC;   -- admin_bruto - stripe_fee → lo que entra a billetera
  v_admin_id     UUID;
BEGIN
  SELECT * INTO v_reservation
  FROM reservations WHERE id = p_reservation_id FOR UPDATE;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'reservation_not_found');
  END IF;

  IF v_reservation.payment_status IN ('paid','fully_paid') THEN
    RETURN jsonb_build_object('ok', true, 'skipped', true, 'reason', 'already_paid');
  END IF;

  -- Grupo recibe exactamente lo que cotizó (base, antes de MSI)
  v_earnings    := COALESCE(v_reservation.base_price,
                     ROUND(v_reservation.total_price * 0.9, 2));
  -- Comisión plataforma: 10% del precio base
  v_service_fee := COALESCE(v_reservation.service_fee_amount,
                     ROUND(v_reservation.total_price * 0.10, 2));
  -- MSI fee: va íntegro a plataforma
  v_msi_fee     := COALESCE(v_reservation.msi_fee_amount, 0);
  v_admin_bruto := v_service_fee + v_msi_fee;
  -- Stripe fee: real desde webhook; estimado si aún no llegó
  v_stripe_fee  := COALESCE(
                     p_stripe_fee,
                     COALESCE(v_reservation.stripe_fee_amount,
                       ROUND((v_reservation.total_price + v_msi_fee) * 0.036 + 3, 2))
                   );
  v_admin_neto  := GREATEST(0, v_admin_bruto - v_stripe_fee);

  -- Acreditar wallet del grupo
  PERFORM ensure_group_wallet(v_reservation.group_id);
  SELECT id INTO v_wallet_id FROM group_wallets WHERE group_id = v_reservation.group_id;

  UPDATE group_wallets
  SET pending_balance = pending_balance + v_earnings,
      total_earned    = total_earned    + v_earnings,
      updated_at      = NOW()
  WHERE id = v_wallet_id;

  -- Guardar datos calculados en la reserva para que los RPCs de release sean consistentes
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
    reservation_id, description, balance_after
  )
  SELECT gw.id, gw.group_id, 'credit_pending', v_earnings,
    p_reservation_id,
    format('Pago confirmado — reserva %s', p_reservation_id),
    gw.pending_balance
  FROM group_wallets gw WHERE gw.id = v_wallet_id;

  -- Acreditar billetera admin con neto (bruto menos Stripe)
  SELECT id INTO v_admin_id FROM profiles WHERE role = 'admin' ORDER BY created_at LIMIT 1;
  IF v_admin_id IS NOT NULL THEN
    INSERT INTO wallets (user_id, available_balance, pending_balance, total_earned)
    VALUES (v_admin_id, 0, 0, 0)
    ON CONFLICT (user_id) DO NOTHING;

    UPDATE wallets SET
      available_balance = available_balance + v_admin_neto,
      total_earned      = COALESCE(total_earned, 0) + v_admin_neto,
      updated_at        = NOW()
    WHERE user_id = v_admin_id;

    INSERT INTO wallet_transactions (user_id, type, amount, reservation_id, description)
    VALUES (v_admin_id, 'platform_income', v_admin_neto, p_reservation_id,
      format('Comisión $%s + MSI $%s − Stripe $%s = $%s neto — reserva %s',
        v_service_fee::TEXT, v_msi_fee::TEXT,
        v_stripe_fee::TEXT, v_admin_neto::TEXT,
        p_reservation_id));
  END IF;

  INSERT INTO financial_audit_logs
    (entity_type, entity_id, action, actor_id, actor_role, amount, notes)
  VALUES ('reservation', p_reservation_id, 'hold', NULL, 'system', v_earnings,
    format('group=%s svc=%s msi=%s stripe=%s admin_neto=%s',
      v_earnings, v_service_fee, v_msi_fee, v_stripe_fee, v_admin_neto));

  RETURN jsonb_build_object(
    'ok',           true,
    'group_earnings', v_earnings,
    'service_fee',  v_service_fee,
    'msi_fee',      v_msi_fee,
    'admin_bruto',  v_admin_bruto,
    'stripe_fee',   v_stripe_fee,
    'admin_neto',   v_admin_neto
  );
END;
$$;
GRANT EXECUTE ON FUNCTION public.confirm_full_payment_and_credit_wallet(UUID, TEXT, NUMERIC, NUMERIC)
  TO authenticated, service_role;

-- ── 2. release_half_on_arrival v3 (usa group_earnings guardado) ───────────
CREATE OR REPLACE FUNCTION public.release_half_on_arrival(p_reservation_id UUID)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_reservation RECORD;
  v_wallet      RECORD;
  v_total       NUMERIC;
  v_half        NUMERIC;
BEGIN
  SELECT * INTO v_reservation FROM reservations WHERE id = p_reservation_id FOR UPDATE;
  IF NOT FOUND THEN RETURN jsonb_build_object('ok', false, 'error', 'not_found'); END IF;

  IF v_reservation.payout_status != 'held' THEN
    RETURN jsonb_build_object('ok', true, 'skipped', true, 'reason', v_reservation.payout_status);
  END IF;

  IF v_reservation.payment_status NOT IN ('paid','fully_paid','deposit_paid') THEN
    RETURN jsonb_build_object('ok', false, 'error', 'payment_not_confirmed');
  END IF;

  PERFORM ensure_group_wallet(v_reservation.group_id);
  SELECT * INTO v_wallet FROM group_wallets WHERE group_id = v_reservation.group_id FOR UPDATE;

  -- group_earnings guardado por confirm_full_payment_and_credit_wallet v5
  v_total := COALESCE(v_reservation.group_earnings,
               COALESCE(v_reservation.base_price,
                 ROUND(v_reservation.total_price * 0.9, 2)));
  v_half  := ROUND(v_total / 2, 2);

  UPDATE group_wallets SET
    pending_balance   = GREATEST(0, pending_balance - v_half),
    available_balance = available_balance + v_half,
    updated_at        = NOW()
  WHERE id = v_wallet.id;

  UPDATE reservations SET payout_status = 'half_released', updated_at = NOW()
  WHERE id = p_reservation_id;

  INSERT INTO wallet_transactions
    (group_wallet_id, group_id, type, amount, reservation_id, description, balance_after)
  VALUES (v_wallet.id, v_reservation.group_id, 'credit_available', v_half,
    p_reservation_id,
    format('50%% al llegar al evento — reserva %s', p_reservation_id),
    v_wallet.available_balance + v_half);

  INSERT INTO financial_audit_logs
    (entity_type, entity_id, action, actor_id, actor_role, amount, notes)
  VALUES ('reservation', p_reservation_id, 'partial_release', NULL, 'system', v_half, '50% on arrival');

  INSERT INTO notifications (user_id, type, title, body, data)
  SELECT g.owner_id, 'payout', '💰 50% disponible en tu wallet',
    format('$%s MXN disponibles por llegar al evento.', to_char(v_half, 'FM999,999,990')),
    jsonb_build_object('screen','Wallet','reservation_id',p_reservation_id)
  FROM groups g WHERE g.id = v_reservation.group_id;

  RETURN jsonb_build_object('ok', true, 'amount_released', v_half);
END;
$$;
GRANT EXECUTE ON FUNCTION public.release_half_on_arrival(UUID) TO authenticated, service_role;

-- ── 3. release_group_earnings_atomic v4 (usa group_earnings guardado) ─────
CREATE OR REPLACE FUNCTION public.release_group_earnings_atomic(
  p_reservation_id UUID,
  p_released_by    UUID DEFAULT NULL
)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_reservation RECORD;
  v_wallet      RECORD;
  v_total       NUMERIC;
  v_to_release  NUMERIC;
  v_actor_role  TEXT := 'system';
BEGIN
  SELECT * INTO v_reservation FROM reservations WHERE id = p_reservation_id FOR UPDATE;
  IF NOT FOUND THEN RETURN jsonb_build_object('ok', false, 'error', 'not_found'); END IF;

  IF v_reservation.payout_status = 'released' THEN
    RETURN jsonb_build_object('ok', true, 'skipped', true, 'reason', 'already_released');
  END IF;
  IF v_reservation.payout_status IN ('blocked','refunded') THEN
    RETURN jsonb_build_object('ok', false, 'error', 'payout_blocked',
      'payout_status', v_reservation.payout_status);
  END IF;
  IF v_reservation.payment_status NOT IN ('paid','fully_paid','deposit_paid') THEN
    RETURN jsonb_build_object('ok', false, 'error', 'payment_not_confirmed');
  END IF;
  IF EXISTS (
    SELECT 1 FROM disputes
    WHERE reservation_id = p_reservation_id AND status IN ('open','under_review')
  ) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'open_dispute_blocks_release');
  END IF;

  IF p_released_by IS NOT NULL THEN
    SELECT COALESCE(role,'unknown') INTO v_actor_role FROM profiles WHERE id = p_released_by;
  END IF;

  PERFORM ensure_group_wallet(v_reservation.group_id);
  SELECT * INTO v_wallet FROM group_wallets WHERE group_id = v_reservation.group_id FOR UPDATE;

  v_total := COALESCE(v_reservation.group_earnings,
               COALESCE(v_reservation.base_price,
                 ROUND(v_reservation.total_price * 0.9, 2)));
  v_to_release := CASE
    WHEN v_reservation.payout_status = 'half_released' THEN v_total - ROUND(v_total / 2, 2)
    ELSE v_total
  END;

  UPDATE group_wallets SET
    pending_balance   = GREATEST(0, pending_balance - v_to_release),
    available_balance = available_balance + v_to_release,
    updated_at        = NOW()
  WHERE id = v_wallet.id;

  UPDATE reservations SET
    payout_status = 'released', released_at = NOW(),
    released_by = p_released_by, wallet_released_at = NOW(), updated_at = NOW()
  WHERE id = p_reservation_id;

  INSERT INTO wallet_transactions
    (group_wallet_id, group_id, type, amount, reservation_id, description, balance_after)
  VALUES (v_wallet.id, v_reservation.group_id, 'credit_available', v_to_release,
    p_reservation_id,
    CASE WHEN v_reservation.payout_status = 'half_released'
      THEN format('50%% final al terminar evento — reserva %s', p_reservation_id)
      ELSE format('Ganancias liberadas post-evento — reserva %s', p_reservation_id)
    END,
    v_wallet.available_balance + v_to_release);

  INSERT INTO financial_audit_logs
    (entity_type, entity_id, action, actor_id, actor_role, before_state, after_state, amount, notes)
  VALUES ('reservation', p_reservation_id, 'release', p_released_by, v_actor_role,
    jsonb_build_object('payout_status', v_reservation.payout_status),
    jsonb_build_object('payout_status', 'released'),
    v_to_release,
    format('Released by %s (was %s)', v_actor_role, v_reservation.payout_status));

  INSERT INTO notifications (user_id, type, title, body, data)
  SELECT g.owner_id, 'payout', '💰 Ganancias liberadas',
    format('$%s MXN disponibles en tu billetera.', to_char(v_to_release, 'FM999,999,990')),
    jsonb_build_object('screen','Wallet','reservation_id',p_reservation_id)
  FROM groups g WHERE g.id = v_reservation.group_id;

  RETURN jsonb_build_object('ok', true, 'amount_released', v_to_release);
END;
$$;
GRANT EXECUTE ON FUNCTION public.release_group_earnings_atomic(UUID, UUID) TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.release_event_payment(p_reservation_id UUID)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN RETURN release_group_earnings_atomic(p_reservation_id, NULL); END;
$$;
GRANT EXECUTE ON FUNCTION public.release_event_payment TO service_role;

-- ── 4. process_refund_reversal v4 (revierte neto admin) ───────────────────
CREATE OR REPLACE FUNCTION public.process_refund_reversal(
  p_reservation_id UUID,
  p_mp_refund_id   TEXT    DEFAULT NULL,
  p_refund_amount  NUMERIC DEFAULT NULL
)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_reservation RECORD;
  v_wallet      RECORD;
  v_reversal    NUMERIC;
  v_admin_neto  NUMERIC;
  v_admin_id    UUID;
BEGIN
  SELECT * INTO v_reservation FROM reservations WHERE id = p_reservation_id FOR UPDATE;
  IF NOT FOUND THEN RETURN jsonb_build_object('ok', false, 'error', 'not_found'); END IF;
  IF v_reservation.payout_status = 'refunded' THEN
    RETURN jsonb_build_object('ok', true, 'skipped', true, 'reason', 'already_refunded');
  END IF;

  v_reversal   := COALESCE(v_reservation.group_earnings,
                   COALESCE(v_reservation.base_price, ROUND(v_reservation.total_price * 0.9, 2)));
  -- Revertir el neto que se acreditó al admin (bruto - stripe_fee)
  v_admin_neto := GREATEST(0,
    COALESCE(v_reservation.service_fee_amount, ROUND(v_reservation.total_price * 0.10, 2))
    + COALESCE(v_reservation.msi_fee_amount, 0)
    - COALESCE(v_reservation.stripe_fee_amount,
        ROUND((v_reservation.total_price + COALESCE(v_reservation.msi_fee_amount,0)) * 0.036 + 3, 2))
  );

  SELECT * INTO v_wallet FROM group_wallets WHERE group_id = v_reservation.group_id FOR UPDATE;
  IF FOUND THEN
    UPDATE group_wallets SET
      pending_balance   = GREATEST(0, pending_balance - v_reversal),
      available_balance = GREATEST(0, available_balance - (
        CASE WHEN v_reservation.payout_status IN ('half_released','released')
          THEN ROUND(v_reversal / 2, 2) ELSE 0 END)),
      total_earned = GREATEST(0, total_earned - v_reversal),
      updated_at   = NOW()
    WHERE id = v_wallet.id;

    INSERT INTO wallet_transactions
      (group_wallet_id, group_id, type, amount, reservation_id, description, balance_after)
    VALUES (v_wallet.id, v_reservation.group_id, 'debit_refund', v_reversal, p_reservation_id,
      format('Reembolso%s — reserva %s',
        CASE WHEN p_mp_refund_id IS NOT NULL THEN format(' %s', p_mp_refund_id) ELSE '' END,
        p_reservation_id),
      GREATEST(0, v_wallet.pending_balance - v_reversal));
  END IF;

  SELECT id INTO v_admin_id FROM profiles WHERE role = 'admin' ORDER BY created_at LIMIT 1;
  IF v_admin_id IS NOT NULL THEN
    UPDATE wallets SET
      available_balance = GREATEST(0, available_balance - v_admin_neto),
      total_earned      = GREATEST(0, COALESCE(total_earned, 0) - v_admin_neto),
      updated_at        = NOW()
    WHERE user_id = v_admin_id;

    INSERT INTO wallet_transactions (user_id, type, amount, reservation_id, description)
    VALUES (v_admin_id, 'debit_refund', v_admin_neto, p_reservation_id,
      format('Reverso comisión neta — reserva %s', p_reservation_id));
  END IF;

  UPDATE reservations SET
    payment_status = 'refunded', payout_status = 'refunded', updated_at = NOW()
  WHERE id = p_reservation_id;

  INSERT INTO financial_audit_logs
    (entity_type, entity_id, action, actor_id, actor_role, amount, notes)
  VALUES ('reservation', p_reservation_id, 'refund', NULL, 'system', v_reversal,
    format('Refund reversal %s', COALESCE(p_mp_refund_id,'manual')));

  RETURN jsonb_build_object('ok', true, 'reversed_group', v_reversal, 'reversed_admin', v_admin_neto);
END;
$$;
GRANT EXECUTE ON FUNCTION public.process_refund_reversal TO authenticated, service_role;

-- ── 5. get_admin_financial_overview v3 ────────────────────────────────────
CREATE OR REPLACE FUNCTION public.get_admin_financial_overview(p_days INT DEFAULT NULL)
RETURNS JSON LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_result JSON;
  v_from   TIMESTAMPTZ;
BEGIN
  IF auth.uid() IS NULL OR NOT EXISTS (
    SELECT 1 FROM profiles WHERE id = auth.uid() AND role = 'admin'
  ) THEN
    RETURN json_build_object(
      'total_facturado', 0, 'ganancia_bruta', 0, 'stripe_fees', 0,
      'mercadopago_fees', 0, 'ganancia_neta', 0, 'artistas_payout', 0,
      'event_count', 0
    );
  END IF;

  IF p_days IS NOT NULL THEN
    v_from := NOW() - (p_days || ' days')::INTERVAL;
  END IF;

  SELECT json_build_object(
    -- Total cobrado al cliente (precio base + recargo MSI)
    'total_facturado',
      COALESCE(SUM(r.total_price + COALESCE(r.msi_fee_amount, 0)), 0),
    -- Ganancia bruta: 10% del precio base + MSI fee íntegro
    'ganancia_bruta',
      COALESCE(SUM(
        COALESCE(r.service_fee_amount, ROUND(r.total_price * 0.10, 2))
        + COALESCE(r.msi_fee_amount, 0)
      ), 0),
    -- Fees Stripe reales (de balance_transaction) o estimados
    'stripe_fees',
      COALESCE(SUM(
        COALESCE(r.stripe_fee_amount,
          ROUND((r.total_price + COALESCE(r.msi_fee_amount, 0)) * 0.036 + 3, 2))
      ), 0),
    'mercadopago_fees', 0,
    -- Neto plataforma: ganancia_bruta − stripe_fees
    'ganancia_neta',
      COALESCE(SUM(
        COALESCE(r.service_fee_amount, ROUND(r.total_price * 0.10, 2))
        + COALESCE(r.msi_fee_amount, 0)
        - COALESCE(r.stripe_fee_amount,
            ROUND((r.total_price + COALESCE(r.msi_fee_amount, 0)) * 0.036 + 3, 2))
      ), 0),
    -- Pago al grupo: 90% del precio base (lo que cotizó)
    'artistas_payout',
      COALESCE(SUM(
        COALESCE(r.group_earnings, r.base_price, ROUND(r.total_price * 0.90, 2))
      ), 0),
    'event_count', COUNT(*)
  ) INTO v_result
  FROM reservations r
  WHERE r.payment_status IN ('paid','fully_paid','deposit_paid')
    AND (v_from IS NULL OR r.created_at >= v_from);

  RETURN v_result;
END;
$$;
GRANT EXECUTE ON FUNCTION public.get_admin_financial_overview TO authenticated;

-- ── 6. Corrección backfill: reservas con MSI ya procesadas ────────────────
-- Ajusta admin wallet sumando el MSI fee que faltaba en 229b,
-- luego descuenta el Stripe fee real (stripe_fee_amount).
-- El grupo ya tiene $8,100 correcto desde 229b — no se toca.
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
    v_stripe_fee  := COALESCE(v_row.stripe_fee_amount,
                       ROUND((v_row.total_price + v_msi_fee) * 0.036 + 3, 2));
    v_admin_neto  := GREATEST(0, v_admin_bruto - v_stripe_fee);

    -- Lo que se acreditó en 229b: solo service_fee sin MSI
    v_old_credit  := v_service_fee;
    v_adjustment  := v_admin_neto - v_old_credit;

    -- Guardar group_earnings correcto en la reserva
    UPDATE reservations SET
      group_earnings     = COALESCE(group_earnings, COALESCE(base_price, ROUND(total_price * 0.9, 2))),
      service_fee_amount = v_service_fee,
      updated_at         = NOW()
    WHERE id = v_row.id;

    IF v_adjustment <> 0 THEN
      UPDATE wallets SET
        available_balance = GREATEST(0, available_balance + v_adjustment),
        total_earned      = GREATEST(0, COALESCE(total_earned, 0) + v_adjustment),
        updated_at        = NOW()
      WHERE user_id = v_admin_id;

      INSERT INTO wallet_transactions (user_id, type, amount, reservation_id, description)
      VALUES (v_admin_id, 'adjustment', v_adjustment, v_row.id,
        format('[Corrección 231] MSI $%s − Stripe $%s → ajuste $%s — reserva %s',
          v_msi_fee::TEXT, v_stripe_fee::TEXT, v_adjustment::TEXT, v_row.id));

      RAISE NOTICE 'Reserva %: admin wallet ajustado $% (bruto=$%, stripe=$%, neto=$%)',
        v_row.id, v_adjustment, v_admin_bruto, v_stripe_fee, v_admin_neto;
    END IF;
  END LOOP;
END;
$$;

SELECT '231_fix_msi_commission.sql ejecutado ✅' AS status;
