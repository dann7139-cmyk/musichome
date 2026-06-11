-- ════════════════════════════════════════════════════════════════════
-- 302_fix_mp_credit_pending_earnings.sql
--
-- Reescribe mp_credit_pending_earnings() para el nuevo modelo:
--
-- ANTES (modelo legacy):
--   - Iteraba event_payouts y acreditaba wallets individuales de TODOS
--     (owner + members + invited)
--
-- AHORA (nuevo modelo):
--   - 8%  → admin wallet (individual, sin cambio)
--   - 92% → group_wallets del owner ÚNICAMENTE
--   - Members/invited NO reciben nada en wallets
--   - payout_status='held', held_at marcado
--
-- Firma idéntica: backward compatible con mercadopago-webhook Edge Function.
-- Requiere: 184a_tables.sql aplicado (ensure_group_wallet, group_wallets).
-- ════════════════════════════════════════════════════════════════════

-- ── 0. Extender constraint de tipos en wallet_transactions ────────────────────
-- 184a define: credit_pending, release_to_available, debit_payout, refund_dispute, adjustment
-- 205a usa 'credit_available' — lo agregamos aquí para que funcione.
DO $$ BEGIN
  ALTER TABLE public.wallet_transactions
    DROP CONSTRAINT IF EXISTS chk_wt_type;
  ALTER TABLE public.wallet_transactions
    ADD CONSTRAINT chk_wt_type CHECK (
      type IN (
        'credit_pending',
        'credit_available',
        'release_to_available',
        'debit_payout',
        'refund_dispute',
        'adjustment'
      )
    );
EXCEPTION WHEN OTHERS THEN
  RAISE NOTICE 'chk_wt_type ya existe o error: %', SQLERRM;
END; $$;

CREATE OR REPLACE FUNCTION public.mp_credit_pending_earnings(
  p_reservation_id UUID,
  p_payment_id     TEXT,
  p_amount_paid    NUMERIC DEFAULT NULL
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
  v_wallet_id  UUID;
BEGIN
  SELECT * INTO v_res
  FROM   public.reservations
  WHERE  id = p_reservation_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'reservation_not_found');
  END IF;

  -- Idempotencia: si ya fue creditado, no duplicar
  IF v_res.wallet_pending_credited THEN
    RETURN jsonb_build_object('ok', true, 'skipped', true, 'reason', 'already_pending_credited');
  END IF;

  -- Calcular comisión 8% y ganancia neta del grupo
  v_commission := ROUND(v_res.total_price * 0.08, 2);
  v_group_net  := v_res.total_price - v_commission;
  v_admin_id   := public.get_platform_admin_id();

  -- Marcar reserva como pagada y en hold
  UPDATE public.reservations
  SET payment_status          = 'deposit_paid',
      mp_payment_id           = p_payment_id,
      wallet_pending_credited = TRUE,
      payout_status           = 'held',
      held_at                 = NOW()
  WHERE id = p_reservation_id;

  -- ── 1. Comisión 8% → admin wallet individual (pending) ───────────────────────
  -- Nota: wallet_transactions (184a) es exclusivo para group_wallets.
  -- La comisión admin se registra en la tabla wallets (individual, de 59).
  IF v_admin_id IS NOT NULL THEN
    INSERT INTO public.wallets (user_id)
    VALUES (v_admin_id)
    ON CONFLICT (user_id) DO NOTHING;

    UPDATE public.wallets
    SET pending_balance = pending_balance + v_commission,
        updated_at      = NOW()
    WHERE user_id = v_admin_id;
    -- No hay INSERT en wallet_transactions aquí: esa tabla es group-based (184a).
    -- La auditoría de comisión admin queda en financial_audit_logs.
  END IF;

  -- ── 2. 92% → group_wallets del owner (ÚNICO destino real) ─────────────────
  -- Members e invitados NO reciben nada aquí.
  -- El owner distribuye a su equipo fuera de la app.
  PERFORM public.ensure_group_wallet(v_res.group_id);
  SELECT id INTO v_wallet_id FROM public.group_wallets WHERE group_id = v_res.group_id;

  IF v_wallet_id IS NOT NULL THEN
    UPDATE public.group_wallets
    SET pending_balance = pending_balance + v_group_net,
        total_earned    = total_earned    + v_group_net,
        updated_at      = NOW()
    WHERE id = v_wallet_id;

    -- Registro en wallet_transactions del grupo
    INSERT INTO public.wallet_transactions
      (group_wallet_id, group_id, type, amount, reservation_id, description, balance_after)
    SELECT
      gw.id, gw.group_id, 'credit_pending', v_group_net,
      p_reservation_id,
      format('Pago MP:%s retenido · evento %s', p_payment_id, v_res.event_date::TEXT),
      gw.pending_balance + v_group_net
    FROM public.group_wallets gw WHERE gw.id = v_wallet_id;

    -- Auditoría
    INSERT INTO public.financial_audit_logs (
      entity_type, entity_id, action, actor_id, actor_role, amount, notes
    ) VALUES (
      'reservation', p_reservation_id, 'hold',
      NULL, 'system', v_group_net,
      format('MP payment confirmed MP:%s — earnings held in group_wallet', p_payment_id)
    );

    -- Notificar al owner
    INSERT INTO public.notifications (user_id, type, title, body, data)
    SELECT g.owner_id, 'payment',
      '⏳ Pago recibido — retenido hasta fin del evento',
      format('$%s MXN reservados para tu grupo. Se liberarán automáticamente cuando termine el evento del %s.',
        to_char(v_group_net, 'FM999,999,990'), v_res.event_date::TEXT),
      jsonb_build_object(
        'reservation_id', p_reservation_id,
        'amount',         v_group_net,
        'screen',         'Wallet'
      )
    FROM public.groups g WHERE g.id = v_res.group_id;
  END IF;

  RETURN jsonb_build_object(
    'ok',           true,
    'total',        v_res.total_price,
    'commission',   v_commission,
    'group_net',    v_group_net,
    'credited_to',  'group_wallet_only',
    'model',        'owner_only_v2'
  );

EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$$;

GRANT EXECUTE ON FUNCTION public.mp_credit_pending_earnings(UUID, TEXT, NUMERIC) TO service_role;

SELECT '302_fix_mp_credit_pending_earnings: solo group_wallets ✅' AS status;
