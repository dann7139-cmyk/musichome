-- ════════════════════════════════════════════════════════════════════
-- 303_fix_distribute_event_earnings.sql
--
-- Reescribe distribute_event_earnings() para el nuevo modelo:
--
-- ANTES (modelo legacy):
--   - Iteraba event_payouts y liberaba wallets individuales de TODOS
--   - Acreditaba members e invited con sus montos
--   - Usaba wallet_transactions (59) con user_id, status, reference_event_id
--
-- AHORA (nuevo modelo):
--   - Solo libera/acredita group_wallets del owner
--   - Comisión admin: solo en wallets individual (sin wallet_transactions)
--   - Members/invited = event_payouts queda informativo, payout_status='pending' forever
--   - Solo owner event_payout se marca 'paid'
--   - wallet_transactions (184a) es group-only — no tiene user_id/status/reference_event_id
--
-- Firma idéntica: backward compatible con cualquier llamador existente.
-- Requiere: 302 aplicado (constraint credit_available ya agregado).
-- ════════════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION public.distribute_event_earnings(
  p_reservation_id UUID
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_res        RECORD;
  v_commission NUMERIC(12,2);
  v_group_net  NUMERIC(12,2);
  v_admin_id   UUID;
  v_wallet     RECORD;
  v_group_tx   RECORD;
  v_has_group_pending BOOLEAN := FALSE;
BEGIN
  SELECT * INTO v_res
  FROM   public.reservations
  WHERE  id = p_reservation_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'reservation_not_found');
  END IF;

  IF v_res.wallet_distributed THEN
    RETURN jsonb_build_object('ok', true, 'skipped', true, 'reason', 'already_distributed');
  END IF;

  v_commission := ROUND(v_res.total_price * 0.08, 2);
  v_group_net  := COALESCE(
    v_res.group_earnings,
    ROUND(v_res.total_price * 0.92, 2)
  );
  v_admin_id := public.get_platform_admin_id();

  -- Marcar evento completado (metadata)
  UPDATE public.reservations
  SET commission_amount  = v_commission,
      platform_fee       = v_commission,
      group_earnings     = v_group_net,
      wallet_distributed = TRUE,
      payout_completed   = TRUE,
      status             = 'completed',
      payment_status     = 'fully_paid',
      event_ended_at     = COALESCE(event_ended_at, NOW())
  WHERE id = p_reservation_id;

  -- ── 1. ADMIN COMMISSION: acreditar en wallets individual (tabla de 59) ──────
  -- wallet_transactions (184a) es group-only — no se usa aquí.
  -- Protegido por wallet_distributed: solo ocurre una vez.
  IF v_admin_id IS NOT NULL THEN
    INSERT INTO public.wallets (user_id)
    VALUES (v_admin_id)
    ON CONFLICT (user_id) DO NOTHING;

    -- Mover pending → available si hay saldo pending (flujo MP con 302)
    -- o acreditar directo si no hay pending (flujo Stripe / legacy)
    UPDATE public.wallets
    SET available_balance = available_balance
          + CASE WHEN pending_balance >= v_commission THEN v_commission ELSE v_commission END,
        pending_balance   = GREATEST(0, pending_balance - v_commission),
        total_earned      = total_earned + v_commission,
        updated_at        = NOW()
    WHERE user_id = v_admin_id;
    -- Nota: no INSERT en wallet_transactions (184a) — esa tabla no tiene user_id.
  END IF;

  -- ── 2. GROUP_WALLETS: liberar o acreditar SOLO al owner ───────────────────
  PERFORM public.ensure_group_wallet(v_res.group_id);
  SELECT * INTO v_wallet
  FROM   public.group_wallets
  WHERE  group_id = v_res.group_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'group_wallet_not_found');
  END IF;

  -- Verificar si ya hay credit_pending para esta reserva (flujo MP/302 o Stripe/205a)
  SELECT EXISTS (
    SELECT 1 FROM public.wallet_transactions
    WHERE reservation_id = p_reservation_id
      AND group_id       = v_res.group_id
      AND type           = 'credit_pending'
  ) INTO v_has_group_pending;

  IF v_has_group_pending THEN
    -- RUTA A: hay pending → mover a available (inline, evita deadlock con atomic)
    FOR v_group_tx IN
      SELECT id, amount
      FROM   public.wallet_transactions
      WHERE  reservation_id = p_reservation_id
        AND  group_id       = v_res.group_id
        AND  type           = 'credit_pending'
    LOOP
      UPDATE public.group_wallets
      SET available_balance = available_balance + v_group_tx.amount,
          pending_balance   = GREATEST(0, pending_balance - v_group_tx.amount),
          updated_at        = NOW()
      WHERE id = v_wallet.id;

      INSERT INTO public.wallet_transactions
        (group_wallet_id, group_id, type, amount, reservation_id, description, balance_after)
      SELECT
        gw.id, gw.group_id, 'credit_available', v_group_tx.amount,
        p_reservation_id,
        'Ganancias liberadas post-evento ' || v_res.event_date::TEXT,
        gw.available_balance + v_group_tx.amount
      FROM public.group_wallets gw WHERE gw.id = v_wallet.id;
    END LOOP;
  ELSE
    -- RUTA B: sin pending previo → acreditar directo (legacy o sin pago previo)
    -- Solo si no hay ningún registro de crédito para esta reserva
    IF NOT EXISTS (
      SELECT 1 FROM public.wallet_transactions
      WHERE reservation_id = p_reservation_id
        AND group_id       = v_res.group_id
        AND type IN ('credit_pending', 'credit_available')
    ) THEN
      UPDATE public.group_wallets
      SET available_balance = available_balance + v_group_net,
          total_earned      = total_earned + v_group_net,
          updated_at        = NOW()
      WHERE id = v_wallet.id;

      INSERT INTO public.wallet_transactions
        (group_wallet_id, group_id, type, amount, reservation_id, description, balance_after)
      SELECT
        gw.id, gw.group_id, 'credit_available', v_group_net,
        p_reservation_id,
        'Ganancia evento ' || v_res.event_date::TEXT || ' (acreditación directa)',
        gw.available_balance + v_group_net
      FROM public.group_wallets gw WHERE gw.id = v_wallet.id;
    END IF;
  END IF;

  -- Actualizar payout_status de la reserva
  UPDATE public.reservations
  SET payout_status      = 'released',
      released_at        = NOW(),
      wallet_released_at = NOW()
  WHERE id = p_reservation_id
    AND payout_status != 'released';

  -- Auditoría
  INSERT INTO public.financial_audit_logs (
    entity_type, entity_id, action, actor_id, actor_role, amount, notes
  ) VALUES (
    'reservation', p_reservation_id, 'release',
    NULL, 'system', v_group_net,
    format('distribute_event_earnings: owner_only_model, group=%s', v_res.group_id)
  );

  -- Notificar al owner
  INSERT INTO public.notifications (user_id, type, title, body, data)
  SELECT g.owner_id, 'payout',
    '💰 ¡Ganancias disponibles!',
    format('$%s MXN disponibles en tu billetera por el evento del %s.',
      to_char(v_group_net, 'FM999,999,990'), v_res.event_date::TEXT),
    jsonb_build_object(
      'reservation_id', p_reservation_id,
      'amount',         v_group_net,
      'screen',         'Wallet'
    )
  FROM public.groups g WHERE g.id = v_res.group_id;

  -- ── 3. Marcar SOLO el event_payout del owner como 'paid' ─────────────────
  -- members/invited se dejan en 'pending' para siempre (son informativos).
  UPDATE public.event_payouts
  SET payout_status = 'paid'
  WHERE reservation_id  = p_reservation_id
    AND role            = 'owner'
    AND is_informational = FALSE;

  RETURN jsonb_build_object(
    'ok',          true,
    'reservation', p_reservation_id,
    'total',       v_res.total_price,
    'commission',  v_commission,
    'group_net',   v_group_net,
    'model',       'owner_only_v2'
  );

EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$$;

GRANT EXECUTE ON FUNCTION public.distribute_event_earnings(UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION public.distribute_event_earnings(UUID) TO service_role;

SELECT '303_fix_distribute_event_earnings: solo group_wallets, sin members/invited ✅' AS status;
