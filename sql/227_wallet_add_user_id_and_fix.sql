-- ============================================================
-- sql/227_wallet_add_user_id_and_fix.sql
--
-- Reemplaza 226 (que falló por columna user_id inexistente).
-- Cambio clave: ADD COLUMN user_id en lugar de DROP NOT NULL.
-- ============================================================

-- ── 1. Agregar columna user_id a wallet_transactions (nullable) ───────────
-- La tabla 184a no tenía esta columna. La necesitamos para
-- transacciones del admin (platform_income) que no son de grupo.
ALTER TABLE wallet_transactions
  ADD COLUMN IF NOT EXISTS user_id UUID REFERENCES profiles(id);

-- ── 2. Hacer group_wallet_id y group_id NULLABLE ──────────────────────────
-- Las transacciones de admin no tienen grupo.
ALTER TABLE wallet_transactions
  ALTER COLUMN group_wallet_id DROP NOT NULL;

ALTER TABLE wallet_transactions
  ALTER COLUMN group_id DROP NOT NULL;

-- ── 3. Agregar balance_after si no existe ─────────────────────────────────
ALTER TABLE wallet_transactions
  ADD COLUMN IF NOT EXISTS balance_after NUMERIC(14,2);

-- ── 4. Agregar stripe_fee_amount a reservations si no existe ─────────────
ALTER TABLE reservations
  ADD COLUMN IF NOT EXISTS stripe_fee_amount NUMERIC(12,2);

-- ── 5. Agregar 'half_released' al CHECK de payout_status si no existe ────
DO $$
BEGIN
  -- Eliminar el constraint antiguo y recrearlo con el nuevo valor
  ALTER TABLE reservations DROP CONSTRAINT IF EXISTS chk_payout_status;
  ALTER TABLE reservations DROP CONSTRAINT IF EXISTS chk_payout_status_v2;
  ALTER TABLE reservations DROP CONSTRAINT IF EXISTS chk_payout_status_v3;
  ALTER TABLE reservations ADD CONSTRAINT chk_payout_status_v4 CHECK (
    payout_status IN (
      'held', 'half_released', 'released', 'blocked', 'refunded', 'pending'
    )
  );
EXCEPTION WHEN others THEN
  RAISE NOTICE 'chk_payout_status: %', SQLERRM;
END;
$$;

-- ── 6. Expandir constraint de tipo en wallet_transactions ─────────────────
ALTER TABLE wallet_transactions DROP CONSTRAINT IF EXISTS chk_wt_type;
ALTER TABLE wallet_transactions ADD CONSTRAINT chk_wt_type CHECK (
  type IN (
    'credit_pending', 'credit_available',
    'release_to_available', 'debit_payout',
    'refund_dispute', 'adjustment',
    'event_earning', 'extra_hour', 'withdrawal', 'commission', 'refund',
    'platform_income', 'debit_refund',
    'ad_income', 'bid_income', 'recommendation_income'
  )
);

-- ── 7. Arreglar RLS de wallet_transactions ────────────────────────────────
DROP POLICY IF EXISTS wt_owner_select    ON wallet_transactions;
DROP POLICY IF EXISTS "wt_owner_select"  ON wallet_transactions;
DROP POLICY IF EXISTS wt_no_direct_write ON wallet_transactions;
DROP POLICY IF EXISTS "wt_no_direct_write" ON wallet_transactions;
DROP POLICY IF EXISTS wt_read            ON wallet_transactions;
DROP POLICY IF EXISTS "wt_read"          ON wallet_transactions;
DROP POLICY IF EXISTS wt_service_write   ON wallet_transactions;
DROP POLICY IF EXISTS "wt_service_write" ON wallet_transactions;
DROP POLICY IF EXISTS "wt_admin_select"  ON wallet_transactions;
DROP POLICY IF EXISTS "wt_service_all"   ON wallet_transactions;

-- Lectura: propio user_id | propio grupo | admin
CREATE POLICY wt_read ON wallet_transactions FOR SELECT
  USING (
    (user_id IS NOT NULL AND user_id = auth.uid())
    OR group_id IN (SELECT id FROM groups WHERE owner_id = auth.uid())
    OR EXISTS (SELECT 1 FROM profiles WHERE id = auth.uid() AND role = 'admin')
  );

-- Escritura: solo SECURITY DEFINER functions (que corren como postgres/superuser)
-- Esta policy permite que dichas funciones inserten; el cliente directo sigue sin poder.
CREATE POLICY wt_service_write ON wallet_transactions FOR ALL
  TO service_role
  USING (true) WITH CHECK (true);

-- ── 8. Arreglar RLS de wallets (legacy) ──────────────────────────────────
DROP POLICY IF EXISTS "wallet_owner_select" ON wallets;
DROP POLICY IF EXISTS "wallet_admin_select" ON wallets;
DROP POLICY IF EXISTS "wallet_service_all"  ON wallets;
DROP POLICY IF EXISTS wallet_read           ON wallets;
DROP POLICY IF EXISTS "wallet_read"         ON wallets;
DROP POLICY IF EXISTS wallet_service_write  ON wallets;
DROP POLICY IF EXISTS "wallet_service_write" ON wallets;

CREATE POLICY wallet_read ON wallets FOR SELECT
  USING (user_id = auth.uid());

CREATE POLICY wallet_service_write ON wallets FOR ALL
  TO service_role
  USING (true) WITH CHECK (true);

-- ── 9. confirm_full_payment_and_credit_wallet v4 ──────────────────────────
DROP FUNCTION IF EXISTS public.confirm_full_payment_and_credit_wallet(UUID, TEXT, NUMERIC);
DROP FUNCTION IF EXISTS public.confirm_full_payment_and_credit_wallet(UUID, TEXT, NUMERIC, NUMERIC);

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

  -- ── Grupo: acreditar pending_balance ──────────────────────────────────
  PERFORM ensure_group_wallet(v_reservation.group_id);
  SELECT id INTO v_wallet_id FROM group_wallets WHERE group_id = v_reservation.group_id;

  UPDATE group_wallets
  SET pending_balance = pending_balance + v_earnings,
      total_earned    = total_earned    + v_earnings,
      updated_at      = NOW()
  WHERE id = v_wallet_id;

  -- ── Actualizar reserva ────────────────────────────────────────────────
  UPDATE reservations SET
    payment_status    = 'paid',
    payout_status     = 'held',
    held_at           = NOW(),
    mp_payment_id     = p_mp_payment_id,
    stripe_fee_amount = COALESCE(p_stripe_fee, stripe_fee_amount),
    updated_at        = NOW()
  WHERE id = p_reservation_id;

  -- ── Wallet transaction del GRUPO ──────────────────────────────────────
  INSERT INTO wallet_transactions (
    group_wallet_id, group_id, type, amount,
    reservation_id, description, balance_after
  )
  SELECT
    gw.id, gw.group_id, 'credit_pending', v_earnings,
    p_reservation_id,
    format('Pago confirmado — reserva %s', p_reservation_id),
    gw.pending_balance
  FROM group_wallets gw WHERE gw.id = v_wallet_id;

  -- ── Admin wallet: acreditar tarifa de servicio ────────────────────────
  SELECT id INTO v_admin_id FROM profiles WHERE role = 'admin' ORDER BY created_at LIMIT 1;

  IF v_admin_id IS NOT NULL THEN
    INSERT INTO wallets (user_id, available_balance, pending_balance, total_earned)
    VALUES (v_admin_id, 0, 0, 0)
    ON CONFLICT (user_id) DO NOTHING;

    UPDATE wallets SET
      available_balance = available_balance + v_service_fee,
      total_earned      = COALESCE(total_earned, 0) + v_service_fee,
      updated_at        = NOW()
    WHERE user_id = v_admin_id;

    INSERT INTO wallet_transactions (
      user_id, type, amount, reservation_id, description
    ) VALUES (
      v_admin_id, 'platform_income', v_service_fee,
      p_reservation_id,
      format('Tarifa de servicio (10%%) — reserva %s', p_reservation_id)
    );
  END IF;

  -- ── Audit log ─────────────────────────────────────────────────────────
  INSERT INTO financial_audit_logs (
    entity_type, entity_id, action, actor_id, actor_role, amount, notes
  ) VALUES (
    'reservation', p_reservation_id, 'hold',
    NULL, 'system', v_earnings,
    format('earnings=%s service_fee=%s stripe_fee=%s',
      v_earnings, v_service_fee, COALESCE(p_stripe_fee::TEXT, 'estimado'))
  );

  RETURN jsonb_build_object(
    'ok', true, 'amount_held', v_earnings, 'service_fee', v_service_fee
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.confirm_full_payment_and_credit_wallet(UUID, TEXT, NUMERIC, NUMERIC)
  TO authenticated, service_role;

-- ── 10. release_half_on_arrival v2 ───────────────────────────────────────

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
    format('50%% al llegar al evento — reserva %s', p_reservation_id),
    v_wallet.available_balance + v_half
  );

  INSERT INTO financial_audit_logs (
    entity_type, entity_id, action, actor_id, actor_role, amount, notes
  ) VALUES (
    'reservation', p_reservation_id, 'partial_release',
    NULL, 'system', v_half, '50% on arrival'
  );

  INSERT INTO notifications (user_id, type, title, body, data)
  SELECT g.owner_id, 'payout',
    '💰 50% disponible en tu wallet',
    format('$%s MXN disponibles por llegar al evento.',
      to_char(v_half, 'FM999,999,990')),
    jsonb_build_object('screen','Wallet','reservation_id',p_reservation_id)
  FROM groups g WHERE g.id = v_reservation.group_id;

  RETURN jsonb_build_object('ok', true, 'amount_released', v_half);
END;
$$;

GRANT EXECUTE ON FUNCTION public.release_half_on_arrival(UUID) TO authenticated, service_role;

-- ── 11. release_group_earnings_atomic v3 ─────────────────────────────────

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
    SELECT COALESCE(role,'unknown') INTO v_actor_role FROM profiles WHERE id = p_released_by;
  END IF;

  PERFORM ensure_group_wallet(v_reservation.group_id);
  SELECT * INTO v_wallet
  FROM group_wallets WHERE group_id = v_reservation.group_id FOR UPDATE;

  v_total := COALESCE(
    v_reservation.base_price,
    ROUND(v_reservation.total_price * 0.9, 2)
  );

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
    actor_id, actor_role, before_state, after_state, amount, notes
  ) VALUES (
    'reservation', p_reservation_id, 'release',
    p_released_by, v_actor_role,
    jsonb_build_object('payout_status', v_reservation.payout_status),
    jsonb_build_object('payout_status', 'released'),
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

  RETURN jsonb_build_object('ok', true, 'amount_released', v_to_release);
END;
$$;

GRANT EXECUTE ON FUNCTION public.release_group_earnings_atomic(UUID, UUID) TO authenticated, service_role;

-- Backward compat
CREATE OR REPLACE FUNCTION public.release_event_payment(p_reservation_id UUID)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN RETURN release_group_earnings_atomic(p_reservation_id, NULL); END;
$$;
GRANT EXECUTE ON FUNCTION public.release_event_payment TO service_role;

-- ── 12. process_refund_reversal v3 ───────────────────────────────────────

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

  v_reversal    := COALESCE(v_reservation.base_price, ROUND(v_reservation.total_price * 0.9, 2));
  v_service_fee := COALESCE(v_reservation.service_fee_amount, ROUND(v_reservation.total_price * 0.10, 2));

  SELECT * INTO v_wallet FROM group_wallets WHERE group_id = v_reservation.group_id FOR UPDATE;
  IF FOUND THEN
    UPDATE group_wallets SET
      pending_balance   = GREATEST(0, pending_balance - v_reversal),
      available_balance = GREATEST(0, available_balance - (
        CASE WHEN v_reservation.payout_status IN ('half_released','released')
          THEN ROUND(v_reversal / 2, 2) ELSE 0 END
      )),
      total_earned = GREATEST(0, total_earned - v_reversal),
      updated_at   = NOW()
    WHERE id = v_wallet.id;

    INSERT INTO wallet_transactions (
      group_wallet_id, group_id, type, amount,
      reservation_id, description, balance_after
    ) VALUES (
      v_wallet.id, v_reservation.group_id, 'debit_refund', v_reversal,
      p_reservation_id,
      format('Reembolso%s — reserva %s',
        CASE WHEN p_mp_refund_id IS NOT NULL THEN format(' %s', p_mp_refund_id) ELSE '' END,
        p_reservation_id),
      GREATEST(0, v_wallet.pending_balance - v_reversal)
    );
  END IF;

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
      format('Reverso tarifa servicio — reserva %s', p_reservation_id)
    );
  END IF;

  UPDATE reservations SET
    payment_status = 'refunded', payout_status = 'refunded', updated_at = NOW()
  WHERE id = p_reservation_id;

  INSERT INTO financial_audit_logs (
    entity_type, entity_id, action, actor_id, actor_role, amount, notes
  ) VALUES (
    'reservation', p_reservation_id, 'refund', NULL, 'system', v_reversal,
    format('Refund reversal %s', COALESCE(p_mp_refund_id, 'manual'))
  );

  RETURN jsonb_build_object('ok', true, 'reversed', v_reversal);
END;
$$;
GRANT EXECUTE ON FUNCTION public.process_refund_reversal TO authenticated, service_role;

-- ── 13. BACKFILL: group_wallets para reservas pagadas sin crédito ─────────
DO $$
DECLARE
  v_row       RECORD;
  v_earnings  NUMERIC;
  v_wallet_id UUID;
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
            THEN ROUND(v_earnings / 2, 2) ELSE v_earnings END
        ),
        available_balance = available_balance + (
          CASE WHEN v_row.payout_status = 'half_released'
            THEN ROUND(v_earnings / 2, 2) ELSE 0 END
        ),
        total_earned = total_earned + v_earnings,
        updated_at   = NOW()
      WHERE id = v_wallet_id;
    ELSE
      UPDATE group_wallets SET
        available_balance = available_balance + (
          CASE WHEN v_row.payout_status = 'released' THEN v_earnings ELSE 0 END
        ),
        total_earned = total_earned + v_earnings,
        updated_at   = NOW()
      WHERE id = v_wallet_id;
    END IF;

    INSERT INTO wallet_transactions (
      group_wallet_id, group_id, type, amount,
      reservation_id, description, balance_after
    )
    SELECT
      v_wallet_id, v_row.group_id, 'credit_pending', v_earnings,
      v_row.id,
      format('[Backfill] Pago confirmado — reserva %s', v_row.id),
      0
    WHERE v_wallet_id IS NOT NULL;

  END LOOP;
  RAISE NOTICE 'Backfill group_wallets completado';
END;
$$;

-- ── 14. BACKFILL: admin wallet desde reservas pagadas ────────────────────
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

-- ── 15. Actualizar RPCs financieras admin con fee real ────────────────────

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
  IF NOT EXISTS (SELECT 1 FROM profiles WHERE id = auth.uid() AND role = 'admin') THEN
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
        COALESCE(r.service_fee_amount, r.commission_amount, ROUND(r.total_price * 0.10, 2))
        + COALESCE(r.msi_fee_amount, 0)
      ), 0),
    'stripe_fees',
      COALESCE(SUM(
        COALESCE(r.stripe_fee_amount,
          ROUND((r.total_price + COALESCE(r.msi_fee_amount, 0)) * 0.036 + 3, 2))
      ), 0),
    'mercadopago_fees', 0,
    'ganancia_neta',
      COALESCE(SUM(
        COALESCE(r.service_fee_amount, r.commission_amount, ROUND(r.total_price * 0.10, 2))
        + COALESCE(r.msi_fee_amount, 0)
        - COALESCE(r.stripe_fee_amount,
            ROUND((r.total_price + COALESCE(r.msi_fee_amount, 0)) * 0.036 + 3, 2))
      ), 0),
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

CREATE OR REPLACE FUNCTION public.get_admin_event_financials(
  p_days  INT DEFAULT 30,
  p_limit INT DEFAULT 50
)
RETURNS TABLE (
  reservation_id UUID, event_date DATE, group_name TEXT,
  event_total NUMERIC, platform_fee NUMERIC, stripe_fee NUMERIC,
  mercadopago_fee NUMERIC, net_platform_profit NUMERIC,
  artists_payout NUMERIC, created_at TIMESTAMPTZ
)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM profiles WHERE id = auth.uid() AND role = 'admin') THEN
    RAISE EXCEPTION 'Unauthorized';
  END IF;

  RETURN QUERY
  SELECT
    r.id,
    r.event_date,
    g.name,
    (r.total_price + COALESCE(r.msi_fee_amount, 0)),
    (COALESCE(r.service_fee_amount, r.commission_amount, ROUND(r.total_price * 0.10, 2))
     + COALESCE(r.msi_fee_amount, 0)),
    COALESCE(r.stripe_fee_amount,
      ROUND((r.total_price + COALESCE(r.msi_fee_amount, 0)) * 0.036 + 3, 2)),
    0::NUMERIC,
    (COALESCE(r.service_fee_amount, r.commission_amount, ROUND(r.total_price * 0.10, 2))
     + COALESCE(r.msi_fee_amount, 0)
     - COALESCE(r.stripe_fee_amount,
         ROUND((r.total_price + COALESCE(r.msi_fee_amount, 0)) * 0.036 + 3, 2))),
    COALESCE(r.group_earnings, r.base_price, ROUND(r.total_price * 0.90, 2)),
    r.created_at
  FROM reservations r
  LEFT JOIN groups g ON g.id = r.group_id
  WHERE r.payment_status IN ('paid','fully_paid','deposit_paid')
    AND (p_days IS NULL OR r.created_at >= NOW() - (p_days || ' days')::INTERVAL)
  ORDER BY r.created_at DESC
  LIMIT p_limit;
END;
$$;
GRANT EXECUTE ON FUNCTION public.get_admin_event_financials TO authenticated;

SELECT '227_wallet_add_user_id_and_fix.sql ejecutado ✅' AS status;
