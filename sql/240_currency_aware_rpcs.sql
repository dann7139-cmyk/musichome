-- ============================================================
-- sql/240_currency_aware_rpcs.sql
--
-- FASE 2: RPCs financieros con soporte multi-moneda.
-- REQUIERE: sql/239_currency_fields.sql ejecutado primero.
--
-- Cambios mínimos por función:
--   1. Detectar currency_code desde la reserva
--   2. Enrutar UPDATE a columna MXN o USD según moneda
--   3. Incluir currency_code en wallet_transactions
--
-- La lógica de importes y porcentajes NO cambia.
-- USD y MXN NUNCA se mezclan en el mismo balance.
-- ============================================================

-- ── 1. confirm_full_payment_and_credit_wallet v6 (currency-aware) ─────────────
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

  v_currency    := COALESCE(v_reservation.currency_code, 'MXN');

  v_earnings    := COALESCE(v_reservation.base_price,
                     ROUND(v_reservation.total_price * 0.9, 2));
  v_service_fee := COALESCE(v_reservation.service_fee_amount,
                     ROUND(v_reservation.total_price * 0.10, 2));
  v_msi_fee     := COALESCE(v_reservation.msi_fee_amount, 0);
  v_admin_bruto := v_service_fee + v_msi_fee;
  v_stripe_fee  := COALESCE(
                     p_stripe_fee,
                     COALESCE(v_reservation.stripe_fee_amount,
                       ROUND((v_reservation.total_price + v_msi_fee) * 0.036 + 3, 2))
                   );
  v_admin_neto  := GREATEST(0, v_admin_bruto - v_stripe_fee);

  -- Acreditar wallet del grupo (separado por moneda)
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

  -- Acreditar billetera admin
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

-- ── 2. release_half_on_arrival v4 (currency-aware) ────────────────────────────
CREATE OR REPLACE FUNCTION public.release_half_on_arrival(p_reservation_id UUID)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_reservation RECORD;
  v_wallet      RECORD;
  v_total       NUMERIC;
  v_half        NUMERIC;
  v_currency    TEXT;
BEGIN
  SELECT * INTO v_reservation FROM reservations WHERE id = p_reservation_id FOR UPDATE;
  IF NOT FOUND THEN RETURN jsonb_build_object('ok', false, 'error', 'not_found'); END IF;

  IF v_reservation.payout_status != 'held' THEN
    RETURN jsonb_build_object('ok', true, 'skipped', true, 'reason', v_reservation.payout_status);
  END IF;

  IF v_reservation.payment_status NOT IN ('paid','fully_paid','deposit_paid') THEN
    RETURN jsonb_build_object('ok', false, 'error', 'payment_not_confirmed');
  END IF;

  v_currency := COALESCE(v_reservation.currency_code, 'MXN');

  PERFORM ensure_group_wallet(v_reservation.group_id);
  SELECT * INTO v_wallet FROM group_wallets WHERE group_id = v_reservation.group_id FOR UPDATE;

  v_total := COALESCE(v_reservation.group_earnings,
               COALESCE(v_reservation.base_price,
                 ROUND(v_reservation.total_price * 0.9, 2)));
  v_half  := ROUND(v_total / 2, 2);

  IF v_currency = 'USD' THEN
    UPDATE group_wallets SET
      pending_balance_usd   = GREATEST(0, pending_balance_usd - v_half),
      available_balance_usd = available_balance_usd + v_half,
      updated_at            = NOW()
    WHERE id = v_wallet.id;
  ELSE
    UPDATE group_wallets SET
      pending_balance   = GREATEST(0, pending_balance - v_half),
      available_balance = available_balance + v_half,
      updated_at        = NOW()
    WHERE id = v_wallet.id;
  END IF;

  UPDATE reservations SET payout_status = 'half_released', updated_at = NOW()
  WHERE id = p_reservation_id;

  INSERT INTO wallet_transactions
    (group_wallet_id, group_id, type, amount, reservation_id, description, balance_after, currency_code)
  VALUES (v_wallet.id, v_reservation.group_id, 'credit_available', v_half,
    p_reservation_id,
    format('50%% al llegar al evento — reserva %s', p_reservation_id),
    CASE WHEN v_currency = 'USD'
      THEN v_wallet.available_balance_usd + v_half
      ELSE v_wallet.available_balance + v_half
    END,
    v_currency);

  INSERT INTO financial_audit_logs
    (entity_type, entity_id, action, actor_id, actor_role, amount, notes)
  VALUES ('reservation', p_reservation_id, 'partial_release', NULL, 'system', v_half,
    format('50%% on arrival currency=%s', v_currency));

  INSERT INTO notifications (user_id, type, title, body, data)
  SELECT g.owner_id, 'payout',
    '💰 50% disponible en tu wallet',
    format('$%s %s disponibles por llegar al evento.',
      to_char(v_half, 'FM999,999,990'), v_currency),
    jsonb_build_object('screen','Wallet','reservation_id',p_reservation_id)
  FROM groups g WHERE g.id = v_reservation.group_id;

  RETURN jsonb_build_object('ok', true, 'amount_released', v_half, 'currency', v_currency);
END;
$$;
GRANT EXECUTE ON FUNCTION public.release_half_on_arrival(UUID) TO authenticated, service_role;

-- ── 3. release_group_earnings_atomic v5 (currency-aware) ──────────────────────
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
  v_currency    TEXT;
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

  v_currency := COALESCE(v_reservation.currency_code, 'MXN');

  PERFORM ensure_group_wallet(v_reservation.group_id);
  SELECT * INTO v_wallet FROM group_wallets WHERE group_id = v_reservation.group_id FOR UPDATE;

  v_total := COALESCE(v_reservation.group_earnings,
               COALESCE(v_reservation.base_price,
                 ROUND(v_reservation.total_price * 0.9, 2)));
  v_to_release := CASE
    WHEN v_reservation.payout_status = 'half_released' THEN v_total - ROUND(v_total / 2, 2)
    ELSE v_total
  END;

  IF v_currency = 'USD' THEN
    UPDATE group_wallets SET
      pending_balance_usd   = GREATEST(0, pending_balance_usd - v_to_release),
      available_balance_usd = available_balance_usd + v_to_release,
      updated_at            = NOW()
    WHERE id = v_wallet.id;
  ELSE
    UPDATE group_wallets SET
      pending_balance   = GREATEST(0, pending_balance - v_to_release),
      available_balance = available_balance + v_to_release,
      updated_at        = NOW()
    WHERE id = v_wallet.id;
  END IF;

  UPDATE reservations SET
    payout_status = 'released', released_at = NOW(),
    released_by = p_released_by, wallet_released_at = NOW(), updated_at = NOW()
  WHERE id = p_reservation_id;

  INSERT INTO wallet_transactions
    (group_wallet_id, group_id, type, amount, reservation_id, description, balance_after, currency_code)
  VALUES (v_wallet.id, v_reservation.group_id, 'credit_available', v_to_release,
    p_reservation_id,
    CASE WHEN v_reservation.payout_status = 'half_released'
      THEN format('50%% final al terminar evento — reserva %s', p_reservation_id)
      ELSE format('Ganancias liberadas post-evento — reserva %s', p_reservation_id)
    END,
    CASE WHEN v_currency = 'USD'
      THEN v_wallet.available_balance_usd + v_to_release
      ELSE v_wallet.available_balance + v_to_release
    END,
    v_currency);

  INSERT INTO financial_audit_logs
    (entity_type, entity_id, action, actor_id, actor_role, amount, notes)
  VALUES ('reservation', p_reservation_id, 'release', p_released_by, v_actor_role, v_to_release,
    format('currency=%s payout_status_was=%s', v_currency, v_reservation.payout_status));

  INSERT INTO notifications (user_id, type, title, body, data)
  SELECT g.owner_id, 'payout', '🎉 Ganancias liberadas',
    format('$%s %s disponibles en tu billetera.',
      to_char(v_to_release, 'FM999,999,990'), v_currency),
    jsonb_build_object('screen','Wallet','reservation_id',p_reservation_id)
  FROM groups g WHERE g.id = v_reservation.group_id;

  RETURN jsonb_build_object(
    'ok',            true,
    'released',      v_to_release,
    'currency',      v_currency,
    'payout_status', 'released'
  );
END;
$$;
GRANT EXECUTE ON FUNCTION public.release_group_earnings_atomic(UUID, UUID) TO authenticated, service_role;

-- ── 4. credit_extra_hour_earnings v2 (currency-aware) ─────────────────────────
CREATE OR REPLACE FUNCTION public.credit_extra_hour_earnings(
  p_reservation_id UUID,
  p_extra_amount   NUMERIC
)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_res        RECORD;
  v_commission NUMERIC(12,2);
  v_net        NUMERIC(12,2);
  v_admin_id   UUID;
  v_owner_id   UUID;
  v_currency   TEXT;
BEGIN
  SELECT r.*, g.owner_id AS group_owner_id
  INTO   v_res
  FROM   public.reservations r
  JOIN   public.groups g ON g.id = r.group_id
  WHERE  r.id = p_reservation_id;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'reservation_not_found');
  END IF;

  IF p_extra_amount <= 0 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_amount');
  END IF;

  v_currency   := COALESCE(v_res.currency_code, 'MXN');
  v_commission := ROUND(p_extra_amount * 0.10, 2);
  v_net        := p_extra_amount - v_commission;
  v_admin_id   := public.get_platform_admin_id();
  v_owner_id   := v_res.group_owner_id;

  -- 10% al admin
  IF v_admin_id IS NOT NULL THEN
    INSERT INTO public.wallets (user_id)
    VALUES (v_admin_id)
    ON CONFLICT (user_id) DO NOTHING;

    IF v_currency = 'USD' THEN
      UPDATE public.wallets SET
        available_balance_usd = available_balance_usd + v_commission,
        total_earned_usd      = total_earned_usd + v_commission,
        updated_at            = NOW()
      WHERE user_id = v_admin_id;
    ELSE
      UPDATE public.wallets SET
        available_balance = available_balance + v_commission,
        total_earned      = total_earned + v_commission,
        updated_at        = NOW()
      WHERE user_id = v_admin_id;
    END IF;

    INSERT INTO public.wallet_transactions
      (user_id, amount, type, status, reference_event_id, description, currency_code)
    VALUES
      (v_admin_id, v_commission, 'commission', 'completed', p_reservation_id,
       format('Comisión 10%% hora extra · %s · %s', v_res.event_date::TEXT, v_currency),
       v_currency);
  END IF;

  -- 90% al grupo (disponible inmediato)
  IF v_owner_id IS NOT NULL THEN
    PERFORM public.ensure_group_wallet(v_res.group_id);

    IF v_currency = 'USD' THEN
      UPDATE public.group_wallets SET
        available_balance_usd = available_balance_usd + v_net,
        total_earned_usd      = total_earned_usd + v_net,
        updated_at            = NOW()
      WHERE group_id = v_res.group_id;
    ELSE
      UPDATE public.group_wallets SET
        available_balance = available_balance + v_net,
        total_earned      = total_earned + v_net,
        updated_at        = NOW()
      WHERE group_id = v_res.group_id;
    END IF;

    INSERT INTO public.wallet_transactions
      (group_id, amount, type, status, reference_event_id, description, currency_code)
    VALUES
      (v_res.group_id, v_net, 'extra_hour', 'completed', p_reservation_id,
       format('Hora extra · evento %s · %s', v_res.event_date::TEXT, v_currency),
       v_currency);

    INSERT INTO public.notifications
      (user_id, type, title, body, data)
    VALUES
      (v_owner_id, 'payment',
       '💰 Hora extra cobrada',
       format('Se agregaron $%s %s a tu billetera por hora(s) extra.', v_net::TEXT, v_currency),
       jsonb_build_object(
         'reservation_id', p_reservation_id,
         'amount',         v_net,
         'currency',       v_currency,
         'screen',         'Wallet'
       ));
  END IF;

  RETURN jsonb_build_object(
    'ok',          true,
    'currency',    v_currency,
    'extra_amount', p_extra_amount,
    'commission',  v_commission,
    'net',         v_net,
    'admin_id',    v_admin_id,
    'owner_id',    v_owner_id
  );

EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$$;

GRANT EXECUTE ON FUNCTION public.credit_extra_hour_earnings(UUID, NUMERIC) TO authenticated, service_role;

SELECT '240_currency_aware_rpcs.sql: 4 RPCs actualizados para multi-moneda ✅' AS status;
