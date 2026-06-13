-- ════════════════════════════════════════════════════════════════════
-- sql/348_fix_commission_10pct.sql
--
-- Corrige comisión hardcodeada 8% → 10% en DOS funciones activas.
--
-- Funciones afectadas (las únicas con 8% que aún están en producción):
--
--   1. distribute_event_earnings  (última versión: sql/303)
--      - v_commission usaba 0.08 → ahora 0.10
--      - v_group_net fallback usaba 0.92 → ahora 0.90
--
--   2. mp_credit_pending_earnings (última versión: sql/302)
--      - v_commission usaba 0.08 → ahora 0.10
--      - v_group_net = total_price - v_commission → auto-corregido a 90%
--      - Llamada desde mercadopago-webhook cuando payment_mode='deposit'
--
-- Archivos con 8% que NO se tocan (código supersedido, funciones
-- reemplazadas por versiones más recientes, ya no están en la DB):
--   sql/59, 60, 61, 63, 64, 69, 79, 89, 100, 135
--
-- Funciones que YA usan 10% y no requieren cambio:
--   confirm_full_payment_and_credit_wallet (sql/240) — usa service_fee_amount || 0.10 ✅
--   release_group_earnings_atomic (sql/225/226) — usa base_price || total*0.9 ✅
--   release_half_on_arrival (sql/225/226) — usa base_price || total*0.9 ✅
--   credit_extra_hour_earnings (sql/232) — ya usa 0.10 ✅
-- ════════════════════════════════════════════════════════════════════


-- ── 1. distribute_event_earnings: 8% → 10% ───────────────────────────────────
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

  -- 10% tarifa de servicio (corregido desde 8%)
  v_commission := ROUND(v_res.total_price * 0.10, 2);
  v_group_net  := COALESCE(
    v_res.group_earnings,
    ROUND(v_res.total_price * 0.90, 2)
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

  -- ── 1. Comisión 10% → admin wallet individual ─────────────────────────────
  IF v_admin_id IS NOT NULL THEN
    INSERT INTO public.wallets (user_id)
    VALUES (v_admin_id)
    ON CONFLICT (user_id) DO NOTHING;

    UPDATE public.wallets
    SET available_balance = available_balance + v_commission,
        pending_balance   = GREATEST(0, pending_balance - v_commission),
        total_earned      = total_earned + v_commission,
        updated_at        = NOW()
    WHERE user_id = v_admin_id;
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

  SELECT EXISTS (
    SELECT 1 FROM public.wallet_transactions
    WHERE reservation_id = p_reservation_id
      AND group_id       = v_res.group_id
      AND type           = 'credit_pending'
  ) INTO v_has_group_pending;

  IF v_has_group_pending THEN
    -- RUTA A: hay pending → mover a available
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
    -- RUTA B: sin pending previo → acreditar directo
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

  UPDATE public.reservations
  SET payout_status      = 'released',
      released_at        = NOW(),
      wallet_released_at = NOW()
  WHERE id = p_reservation_id
    AND payout_status != 'released';

  INSERT INTO public.financial_audit_logs (
    entity_type, entity_id, action, actor_id, actor_role, amount, notes
  ) VALUES (
    'reservation', p_reservation_id, 'release',
    NULL, 'system', v_group_net,
    format('distribute_event_earnings: 10pct_commission, group=%s', v_res.group_id)
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

  -- Marcar SOLO el event_payout del owner como 'paid'
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
    'model',       'owner_only_v3_10pct'
  );

EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$$;

GRANT EXECUTE ON FUNCTION public.distribute_event_earnings(UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION public.distribute_event_earnings(UUID) TO service_role;


-- ── 2. mp_credit_pending_earnings: 8% → 10% ──────────────────────────────────
-- Llamada desde mercadopago-webhook Edge Function cuando payment_mode='deposit'.
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

  IF v_res.wallet_pending_credited THEN
    RETURN jsonb_build_object('ok', true, 'skipped', true, 'reason', 'already_pending_credited');
  END IF;

  -- 10% tarifa de servicio (corregido desde 8%); 90% al grupo
  v_commission := ROUND(v_res.total_price * 0.10, 2);
  v_group_net  := v_res.total_price - v_commission;
  v_admin_id   := public.get_platform_admin_id();

  UPDATE public.reservations
  SET payment_status          = 'deposit_paid',
      mp_payment_id           = p_payment_id,
      wallet_pending_credited = TRUE,
      payout_status           = 'held',
      held_at                 = NOW()
  WHERE id = p_reservation_id;

  -- ── 1. Comisión 10% → admin wallet individual (pending) ──────────────────
  IF v_admin_id IS NOT NULL THEN
    INSERT INTO public.wallets (user_id)
    VALUES (v_admin_id)
    ON CONFLICT (user_id) DO NOTHING;

    UPDATE public.wallets
    SET pending_balance = pending_balance + v_commission,
        updated_at      = NOW()
    WHERE user_id = v_admin_id;
  END IF;

  -- ── 2. 90% → group_wallets del owner (ÚNICO destino real) ────────────────
  PERFORM public.ensure_group_wallet(v_res.group_id);
  SELECT id INTO v_wallet_id FROM public.group_wallets WHERE group_id = v_res.group_id;

  IF v_wallet_id IS NOT NULL THEN
    UPDATE public.group_wallets
    SET pending_balance = pending_balance + v_group_net,
        total_earned    = total_earned    + v_group_net,
        updated_at      = NOW()
    WHERE id = v_wallet_id;

    INSERT INTO public.wallet_transactions
      (group_wallet_id, group_id, type, amount, reservation_id, description, balance_after)
    SELECT
      gw.id, gw.group_id, 'credit_pending', v_group_net,
      p_reservation_id,
      format('Pago MP:%s retenido · evento %s', p_payment_id, v_res.event_date::TEXT),
      gw.pending_balance + v_group_net
    FROM public.group_wallets gw WHERE gw.id = v_wallet_id;

    INSERT INTO public.financial_audit_logs (
      entity_type, entity_id, action, actor_id, actor_role, amount, notes
    ) VALUES (
      'reservation', p_reservation_id, 'hold',
      NULL, 'system', v_group_net,
      format('MP payment confirmed MP:%s — earnings held in group_wallet (10pct commission)', p_payment_id)
    );

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
    'model',        'owner_only_v3_10pct'
  );

EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$$;

GRANT EXECUTE ON FUNCTION public.mp_credit_pending_earnings(UUID, TEXT, NUMERIC) TO service_role;


-- ── Verificación post-deploy ──────────────────────────────────────────────────
DO $$
DECLARE
  v_src TEXT;
BEGIN
  SELECT prosrc INTO v_src FROM pg_proc p
  JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public' AND p.proname = 'distribute_event_earnings';
  IF v_src LIKE '%0.08%' THEN
    RAISE WARNING '[348] ALERTA: distribute_event_earnings aún contiene 0.08';
  ELSE
    RAISE NOTICE '[348] distribute_event_earnings: 10%% comisión confirmada ✅';
  END IF;

  SELECT prosrc INTO v_src FROM pg_proc p
  JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public' AND p.proname = 'mp_credit_pending_earnings';
  IF v_src LIKE '%0.08%' THEN
    RAISE WARNING '[348] ALERTA: mp_credit_pending_earnings aún contiene 0.08';
  ELSE
    RAISE NOTICE '[348] mp_credit_pending_earnings: 10%% comisión confirmada ✅';
  END IF;
END;
$$;

SELECT '348_fix_commission_10pct.sql: distribute_event_earnings + mp_credit_pending_earnings → 10%% ✅' AS status;
