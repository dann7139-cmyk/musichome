-- ============================================================
-- sql/225_admin_wallet_and_partial_release.sql
--
-- Cambios:
--   1. stripe_fee_amount en reservations (fee real de Stripe vs estimación)
--   2. Añadir 'half_released' al constraint de payout_status
--   3. confirm_full_payment_and_credit_wallet v3:
--        - acepta p_stripe_fee (fee real)
--        - acredita admin wallet con tarifa de servicio
--   4. RPC release_half_on_arrival: libera 50% al marcar llegué
--   5. release_group_earnings_atomic v2: maneja half_released (solo libera el 50% restante)
--   6. process_refund_reversal v2: revierte también el admin wallet
--   7. get_admin_financial_overview v3: usa stripe_fee_amount real cuando existe
--   8. get_admin_event_financials v3: usa stripe_fee_amount real cuando existe
-- ============================================================

-- ── 1. Columna stripe_fee_amount ─────────────────────────────────────────────
ALTER TABLE reservations
  ADD COLUMN IF NOT EXISTS stripe_fee_amount NUMERIC(12,2);

-- ── 2. Constraint payout_status: añadir half_released ────────────────────────
ALTER TABLE reservations DROP CONSTRAINT IF EXISTS chk_payout_status;
ALTER TABLE reservations ADD CONSTRAINT chk_payout_status
  CHECK (payout_status IN (
    'held', 'half_released', 'pending_release', 'released', 'blocked', 'refunded'
  ));

-- ── 3. confirm_full_payment_and_credit_wallet v3 ─────────────────────────────
-- Añade: p_stripe_fee (fee real de Stripe), crédito a admin wallet
-- Eliminar la versión anterior (3 parámetros) para evitar conflicto de overload
DROP FUNCTION IF EXISTS public.confirm_full_payment_and_credit_wallet(UUID, TEXT, NUMERIC);

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
  v_reservation RECORD;
  v_wallet_id   UUID;
  v_earnings    NUMERIC;
  v_service_fee NUMERIC;
  v_admin_id    UUID;
BEGIN
  SELECT * INTO v_reservation
  FROM reservations WHERE id = p_reservation_id FOR UPDATE;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'reservation_not_found');
  END IF;

  IF v_reservation.payment_status IN ('paid','fully_paid') THEN
    RETURN jsonb_build_object('ok', true, 'skipped', true, 'reason', 'already_paid');
  END IF;

  v_earnings := COALESCE(
    v_reservation.base_price,
    ROUND(v_reservation.total_price * 0.9, 2)
  );

  v_service_fee := COALESCE(
    v_reservation.service_fee_amount,
    ROUND(v_reservation.total_price * 0.10, 2)
  );

  -- ── Grupo: acreditar pending_balance ──────────────────────────────────────
  PERFORM ensure_group_wallet(v_reservation.group_id);
  SELECT id INTO v_wallet_id FROM group_wallets WHERE group_id = v_reservation.group_id;

  UPDATE group_wallets
  SET pending_balance = pending_balance + v_earnings,
      total_earned    = total_earned    + v_earnings,
      updated_at      = NOW()
  WHERE id = v_wallet_id;

  -- ── Actualizar reserva ────────────────────────────────────────────────────
  UPDATE reservations SET
    payment_status    = 'paid',
    payout_status     = 'held',
    held_at           = NOW(),
    mp_payment_id     = p_mp_payment_id,
    stripe_fee_amount = COALESCE(p_stripe_fee, stripe_fee_amount),
    updated_at        = NOW()
  WHERE id = p_reservation_id;

  -- ── Wallet transaction del grupo ──────────────────────────────────────────
  INSERT INTO wallet_transactions (
    group_wallet_id, group_id, type, amount,
    reservation_id, description, balance_after
  )
  SELECT
    gw.id, gw.group_id, 'credit_pending', v_earnings,
    p_reservation_id,
    format('Pago confirmado — reserva %s', p_reservation_id),
    gw.pending_balance + v_earnings
  FROM group_wallets gw WHERE gw.id = v_wallet_id;

  -- ── Admin wallet: acreditar tarifa de servicio (ganancia plataforma) ──────
  SELECT id INTO v_admin_id FROM profiles WHERE role = 'admin' ORDER BY created_at LIMIT 1;

  IF v_admin_id IS NOT NULL THEN
    -- Upsert wallet del admin (crea si no existe)
    INSERT INTO wallets (user_id, available_balance, pending_balance, total_earned)
    VALUES (v_admin_id, v_service_fee, 0, v_service_fee)
    ON CONFLICT (user_id) DO UPDATE SET
      available_balance = wallets.available_balance + v_service_fee,
      total_earned      = COALESCE(wallets.total_earned, 0) + v_service_fee,
      updated_at        = NOW();

    INSERT INTO wallet_transactions (user_id, type, amount, reservation_id, description)
    VALUES (
      v_admin_id, 'platform_income', v_service_fee,
      p_reservation_id,
      format('Tarifa de servicio (10%%) — reserva %s', p_reservation_id)
    );
  END IF;

  -- ── Audit log ─────────────────────────────────────────────────────────────
  INSERT INTO financial_audit_logs (
    entity_type, entity_id, action, actor_id, actor_role, amount, notes
  ) VALUES (
    'reservation', p_reservation_id, 'hold',
    NULL, 'system', v_earnings,
    format('Payment confirmed — group_earnings=%s held, admin service_fee=%s credited',
      v_earnings, v_service_fee)
  );

  RAISE NOTICE '[PAYMENT_CONFIRMED_HELD] reservation=% mp=% earnings=% service_fee=%',
    p_reservation_id, p_mp_payment_id, v_earnings, v_service_fee;

  RETURN jsonb_build_object(
    'ok', true,
    'amount_held', v_earnings,
    'service_fee', v_service_fee
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.confirm_full_payment_and_credit_wallet(UUID, TEXT, NUMERIC, NUMERIC) TO authenticated, service_role;

-- ── 4. release_half_on_arrival: 50% al marcar llegué ─────────────────────────

CREATE OR REPLACE FUNCTION public.release_half_on_arrival(
  p_reservation_id UUID
)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_reservation RECORD;
  v_wallet      RECORD;
  v_total       NUMERIC;
  v_half        NUMERIC;
BEGIN
  SELECT * INTO v_reservation
  FROM reservations WHERE id = p_reservation_id FOR UPDATE;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_found');
  END IF;

  -- Solo aplica si está en 'held' (no si ya se liberó parcial o total)
  IF v_reservation.payout_status != 'held' THEN
    RETURN jsonb_build_object('ok', true, 'skipped', true, 'reason', v_reservation.payout_status);
  END IF;

  IF v_reservation.payment_status NOT IN ('paid','fully_paid','deposit_paid') THEN
    RETURN jsonb_build_object('ok', false, 'error', 'payment_not_confirmed');
  END IF;

  PERFORM ensure_group_wallet(v_reservation.group_id);
  SELECT * INTO v_wallet
  FROM group_wallets WHERE group_id = v_reservation.group_id FOR UPDATE;

  v_total := COALESCE(
    v_reservation.base_price,
    ROUND(v_reservation.total_price * 0.9, 2)
  );
  v_half := ROUND(v_total / 2, 2);

  UPDATE group_wallets SET
    pending_balance   = GREATEST(0, pending_balance - v_half),
    available_balance = available_balance + v_half,
    updated_at        = NOW()
  WHERE id = v_wallet.id;

  UPDATE reservations SET
    payout_status = 'half_released',
    updated_at    = NOW()
  WHERE id = p_reservation_id;

  INSERT INTO wallet_transactions (
    group_wallet_id, group_id, type, amount,
    reservation_id, description, balance_after
  ) VALUES (
    v_wallet.id, v_reservation.group_id, 'credit_available', v_half,
    p_reservation_id,
    format('50%% adelantado al llegar al evento — reserva %s', p_reservation_id),
    v_wallet.available_balance + v_half
  );

  INSERT INTO financial_audit_logs (
    entity_type, entity_id, action, actor_id, actor_role, amount, notes
  ) VALUES (
    'reservation', p_reservation_id, 'partial_release',
    NULL, 'system', v_half, '50% released on group arrival'
  );

  INSERT INTO notifications (user_id, type, title, body, data)
  SELECT g.owner_id, 'payout',
    '💰 50% disponible en tu wallet',
    format('$%s MXN disponibles por llegar al evento del %s.',
      to_char(v_half, 'FM999,999,990'), v_reservation.event_date),
    jsonb_build_object('screen','Wallet','reservation_id',p_reservation_id)
  FROM groups g WHERE g.id = v_reservation.group_id;

  RAISE NOTICE '[HALF_RELEASED_ON_ARRIVAL] reservation=% amount=%', p_reservation_id, v_half;

  RETURN jsonb_build_object('ok', true, 'amount_released', v_half);
END;
$$;

GRANT EXECUTE ON FUNCTION public.release_half_on_arrival TO authenticated, service_role;

-- ── 5. release_group_earnings_atomic v2: maneja half_released ────────────────
-- Si payout_status='half_released' → solo libera el 50% restante
-- Si payout_status='held'          → libera todo (fallback cron / admin manual)

CREATE OR REPLACE FUNCTION public.release_group_earnings_atomic(
  p_reservation_id UUID,
  p_released_by    UUID DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_reservation RECORD;
  v_wallet      RECORD;
  v_total       NUMERIC;
  v_to_release  NUMERIC;
  v_actor_role  TEXT := 'system';
BEGIN
  SELECT * INTO v_reservation
  FROM reservations WHERE id = p_reservation_id FOR UPDATE;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_found');
  END IF;

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
    SELECT COALESCE(role, 'unknown') INTO v_actor_role
    FROM profiles WHERE id = p_released_by;
  END IF;

  PERFORM ensure_group_wallet(v_reservation.group_id);
  SELECT * INTO v_wallet
  FROM group_wallets WHERE group_id = v_reservation.group_id FOR UPDATE;

  v_total := COALESCE(
    v_reservation.base_price,
    ROUND(v_reservation.total_price * 0.9, 2)
  );

  -- Si ya liberó la mitad, solo libera el resto
  IF v_reservation.payout_status = 'half_released' THEN
    v_to_release := v_total - ROUND(v_total / 2, 2);
  ELSE
    v_to_release := v_total;
  END IF;

  UPDATE group_wallets SET
    pending_balance   = GREATEST(0, pending_balance - v_to_release),
    available_balance = available_balance + v_to_release,
    updated_at        = NOW()
  WHERE id = v_wallet.id;

  UPDATE reservations SET
    payout_status      = 'released',
    released_at        = NOW(),
    released_by        = p_released_by,
    wallet_released_at = NOW(),
    updated_at         = NOW()
  WHERE id = p_reservation_id;

  INSERT INTO wallet_transactions (
    group_wallet_id, group_id, type, amount,
    reservation_id, description, balance_after
  ) VALUES (
    v_wallet.id, v_reservation.group_id, 'credit_available', v_to_release,
    p_reservation_id,
    CASE
      WHEN v_reservation.payout_status = 'half_released'
        THEN format('50%% final al terminar evento — reserva %s', p_reservation_id)
      ELSE format('Ganancias liberadas post-evento — reserva %s', p_reservation_id)
    END,
    v_wallet.available_balance + v_to_release
  );

  INSERT INTO financial_audit_logs (
    entity_type, entity_id, action,
    actor_id, actor_role,
    before_state, after_state,
    amount, notes
  ) VALUES (
    'reservation', p_reservation_id, 'release',
    p_released_by, v_actor_role,
    jsonb_build_object('payout_status', v_reservation.payout_status, 'available', v_wallet.available_balance),
    jsonb_build_object('payout_status', 'released', 'available', v_wallet.available_balance + v_to_release),
    v_to_release,
    format('Released by %s (was %s)', v_actor_role, v_reservation.payout_status)
  );

  INSERT INTO notifications (user_id, type, title, body, data)
  SELECT g.owner_id, 'payout',
    '💰 Ganancias liberadas',
    format('$%s MXN disponibles en tu billetera.',
      to_char(v_to_release, 'FM999,999,990')),
    jsonb_build_object('screen','Wallet','reservation_id',p_reservation_id)
  FROM groups g WHERE g.id = v_reservation.group_id;

  RAISE NOTICE '[PAYOUT_RELEASED] reservation=% group=% amount=% was=% actor=%',
    p_reservation_id, v_reservation.group_id, v_to_release,
    v_reservation.payout_status, v_actor_role;

  RETURN jsonb_build_object(
    'ok', true,
    'amount_released', v_to_release,
    'released_at', NOW()
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.release_group_earnings_atomic TO authenticated, service_role;

-- Backward compat
CREATE OR REPLACE FUNCTION public.release_event_payment(p_reservation_id UUID)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  RETURN release_group_earnings_atomic(p_reservation_id, NULL);
END;
$$;
GRANT EXECUTE ON FUNCTION public.release_event_payment TO service_role;

-- ── 6. process_refund_reversal v2: revierte también admin wallet ──────────────

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
  v_service_fee NUMERIC;
  v_admin_id    UUID;
BEGIN
  SELECT * INTO v_reservation
  FROM reservations WHERE id = p_reservation_id FOR UPDATE;

  IF NOT FOUND THEN RETURN jsonb_build_object('ok', false, 'error', 'not_found'); END IF;

  IF v_reservation.payout_status = 'refunded' THEN
    RETURN jsonb_build_object('ok', true, 'skipped', true, 'reason', 'already_refunded');
  END IF;

  v_reversal := COALESCE(
    v_reservation.base_price,
    ROUND(v_reservation.total_price * 0.9, 2)
  );
  v_service_fee := COALESCE(
    v_reservation.service_fee_amount,
    ROUND(v_reservation.total_price * 0.10, 2)
  );

  -- Revertir grupo wallet
  SELECT * INTO v_wallet
  FROM group_wallets WHERE group_id = v_reservation.group_id FOR UPDATE;

  IF FOUND THEN
    UPDATE group_wallets SET
      pending_balance   = GREATEST(0, pending_balance   - v_reversal),
      available_balance = GREATEST(0, available_balance - (
        CASE WHEN v_reservation.payout_status IN ('half_released','released')
          THEN ROUND(v_reversal / 2, 2) ELSE 0 END
      )),
      total_earned      = GREATEST(0, total_earned - v_reversal),
      updated_at        = NOW()
    WHERE id = v_wallet.id;

    INSERT INTO wallet_transactions (
      group_wallet_id, group_id, type, amount,
      reservation_id, description, balance_after
    ) VALUES (
      v_wallet.id, v_reservation.group_id, 'debit_refund', v_reversal,
      p_reservation_id,
      format('Reversión reembolso%s — reserva %s',
        CASE WHEN p_mp_refund_id IS NOT NULL THEN format(' %s', p_mp_refund_id) ELSE '' END,
        p_reservation_id),
      GREATEST(0, v_wallet.pending_balance - v_reversal)
    );
  END IF;

  -- Revertir admin wallet
  SELECT id INTO v_admin_id FROM profiles WHERE role = 'admin' ORDER BY created_at LIMIT 1;
  IF v_admin_id IS NOT NULL THEN
    UPDATE wallets SET
      available_balance = GREATEST(0, available_balance - v_service_fee),
      total_earned      = GREATEST(0, COALESCE(total_earned, 0) - v_service_fee),
      updated_at        = NOW()
    WHERE user_id = v_admin_id;

    INSERT INTO wallet_transactions (user_id, type, amount, reservation_id, description)
    VALUES (
      v_admin_id, 'debit_refund', v_service_fee,
      p_reservation_id,
      format('Reverso tarifa servicio por reembolso — reserva %s', p_reservation_id)
    );
  END IF;

  UPDATE reservations SET
    payment_status = 'refunded',
    payout_status  = 'refunded',
    updated_at     = NOW()
  WHERE id = p_reservation_id;

  INSERT INTO financial_audit_logs (
    entity_type, entity_id, action, actor_id, actor_role, amount, notes
  ) VALUES (
    'reservation', p_reservation_id, 'refund',
    NULL, 'system', v_reversal,
    format('Refund reversal %s', COALESCE(p_mp_refund_id, 'manual'))
  );

  RAISE NOTICE '[REFUND_REVERSED] reservation=% amount=% service_fee=%',
    p_reservation_id, v_reversal, v_service_fee;

  RETURN jsonb_build_object('ok', true, 'reversed', v_reversal);
END;
$$;

GRANT EXECUTE ON FUNCTION public.process_refund_reversal TO authenticated, service_role;

-- ── 7. get_admin_financial_overview v3: usa stripe_fee_amount real ────────────

CREATE OR REPLACE FUNCTION public.get_admin_financial_overview(
  p_days INT DEFAULT NULL
)
RETURNS JSON
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_result JSON;
  v_from   TIMESTAMPTZ;
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM profiles WHERE id = auth.uid() AND role = 'admin'
  ) THEN
    RAISE EXCEPTION 'Unauthorized';
  END IF;

  IF p_days IS NOT NULL THEN
    v_from := NOW() - (p_days || ' days')::INTERVAL;
  END IF;

  SELECT json_build_object(
    'total_facturado',
      COALESCE(SUM(r.total_price + COALESCE(r.msi_fee_amount, 0)), 0),

    'ganancia_bruta',
      COALESCE(SUM(
        COALESCE(r.service_fee_amount,
                 r.commission_amount,
                 ROUND(r.total_price * 0.10, 2))
        + COALESCE(r.msi_fee_amount, 0)
      ), 0),

    -- Usa el fee real de Stripe cuando está disponible, si no estima
    'stripe_fees',
      COALESCE(SUM(
        COALESCE(
          r.stripe_fee_amount,
          ROUND((r.total_price + COALESCE(r.msi_fee_amount, 0)) * 0.036 + 3, 2)
        )
      ), 0),

    'mercadopago_fees', 0,

    'ganancia_neta',
      COALESCE(SUM(
        COALESCE(r.service_fee_amount,
                 r.commission_amount,
                 ROUND(r.total_price * 0.10, 2))
        + COALESCE(r.msi_fee_amount, 0)
        - COALESCE(
            r.stripe_fee_amount,
            ROUND((r.total_price + COALESCE(r.msi_fee_amount, 0)) * 0.036 + 3, 2)
          )
      ), 0),

    'artistas_payout',
      COALESCE(SUM(
        COALESCE(r.group_earnings,
                 r.base_price,
                 ROUND(r.total_price * 0.90, 2))
      ), 0),

    'event_count', COUNT(*)
  ) INTO v_result
  FROM reservations r
  WHERE r.payment_status IN ('paid', 'fully_paid', 'deposit_paid')
    AND (v_from IS NULL OR r.created_at >= v_from);

  RETURN v_result;
END;
$$;

GRANT EXECUTE ON FUNCTION public.get_admin_financial_overview TO authenticated;

-- ── 8. get_admin_event_financials v3: usa stripe_fee_amount real ──────────────

CREATE OR REPLACE FUNCTION public.get_admin_event_financials(
  p_days  INT DEFAULT 30,
  p_limit INT DEFAULT 50
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
)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM profiles WHERE id = auth.uid() AND role = 'admin'
  ) THEN
    RAISE EXCEPTION 'Unauthorized';
  END IF;

  RETURN QUERY
  SELECT
    r.id                                                          AS reservation_id,
    r.event_date,
    g.name                                                        AS group_name,

    (r.total_price + COALESCE(r.msi_fee_amount, 0))              AS event_total,

    (COALESCE(r.service_fee_amount,
              r.commission_amount,
              ROUND(r.total_price * 0.10, 2))
     + COALESCE(r.msi_fee_amount, 0))                            AS platform_fee,

    -- Fee real si existe, si no estimación
    COALESCE(
      r.stripe_fee_amount,
      ROUND((r.total_price + COALESCE(r.msi_fee_amount, 0)) * 0.036 + 3, 2)
    )                                                             AS stripe_fee,

    0::NUMERIC                                                    AS mercadopago_fee,

    (COALESCE(r.service_fee_amount,
              r.commission_amount,
              ROUND(r.total_price * 0.10, 2))
     + COALESCE(r.msi_fee_amount, 0)
     - COALESCE(
         r.stripe_fee_amount,
         ROUND((r.total_price + COALESCE(r.msi_fee_amount, 0)) * 0.036 + 3, 2)
       ))                                                         AS net_platform_profit,

    COALESCE(r.group_earnings,
             r.base_price,
             ROUND(r.total_price * 0.90, 2))                      AS artists_payout,

    r.created_at
  FROM reservations r
  LEFT JOIN groups g ON g.id = r.group_id
  WHERE r.payment_status IN ('paid', 'fully_paid', 'deposit_paid')
    AND (
      p_days IS NULL
      OR r.created_at >= NOW() - (p_days || ' days')::INTERVAL
    )
  ORDER BY r.created_at DESC
  LIMIT p_limit;
END;
$$;

GRANT EXECUTE ON FUNCTION public.get_admin_event_financials TO authenticated;

SELECT '225_admin_wallet_and_partial_release.sql ejecutado ✅' AS status;
