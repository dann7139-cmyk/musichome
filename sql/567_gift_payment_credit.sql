-- ============================================================
-- sql/567_gift_payment_credit.sql — FASE 1: acreditar el regalo pagado
--
-- Sigue EXACTAMENTE el mismo patrón vigente y ya auditado de
-- approve_extra_hour_payment_atomic (sql/545, 2026-08-09):
--   - ensure_group_wallet() + FOR UPDATE (lock) antes de acreditar.
--   - Bucket de moneda separado (available_balance / available_balance_usd),
--     nunca mezclado.
--   - wallet_transactions para el grupo (group_wallet_id, group_id).
--   - Comisión de Daricefy → public.wallets (billetera del admin, vía
--     get_platform_admin_id()), type='commission' — mismo type que ya
--     usa el flujo de horas extra, no 'platform_income' (ese es el type
--     viejo de ads/bids/recomendados, un flujo distinto).
--   - Idempotente: si group_gifts.status ya es 'paid', no vuelve a
--     acreditar (guard igual al de extra_hours).
--
-- gift_id nullable en wallet_transactions, mismo criterio que ya existe
-- para reservation_id / payout_request_id / dispute_id — un regalo no
-- es ninguna de esas cosas, necesita su propia referencia trazable.
-- ============================================================

ALTER TABLE public.wallet_transactions
  ADD COLUMN IF NOT EXISTS gift_id UUID REFERENCES public.group_gifts(id);

CREATE OR REPLACE FUNCTION public.confirm_gift_payment(
  p_group_gift_id     UUID,
  p_conekta_order_id  TEXT
)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $$
DECLARE
  v_gift          RECORD;
  v_gw            RECORD;
  v_admin_id      UUID;
  v_gw_bal_after  NUMERIC(14,2);
BEGIN
  SELECT * INTO v_gift FROM public.group_gifts WHERE id = p_group_gift_id FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'group_gift no encontrado: %', p_group_gift_id;
  END IF;

  -- Idempotencia: reenvíos del webhook no acreditan dos veces.
  IF v_gift.status = 'paid' THEN
    RETURN jsonb_build_object('ok', true, 'skipped', true, 'reason', 'already_paid');
  END IF;

  IF v_gift.currency_code NOT IN ('MXN', 'USD') THEN
    RAISE EXCEPTION 'unsupported_currency: %', v_gift.currency_code;
  END IF;

  UPDATE public.group_gifts
  SET status = 'paid', paid_at = NOW(), payment_ref = p_conekta_order_id
  WHERE id = p_group_gift_id;

  -- ── Acreditar al grupo (60%) ────────────────────────────────────────
  PERFORM public.ensure_group_wallet(v_gift.group_id);
  SELECT * INTO v_gw FROM public.group_wallets WHERE group_id = v_gift.group_id FOR UPDATE;

  IF v_gift.currency_code = 'USD' THEN
    v_gw_bal_after := COALESCE(v_gw.available_balance_usd, 0) + v_gift.group_amount;
    UPDATE public.group_wallets
    SET available_balance_usd = v_gw_bal_after,
        total_earned_usd      = COALESCE(total_earned_usd, 0) + v_gift.group_amount,
        updated_at            = NOW()
    WHERE id = v_gw.id;
  ELSE
    v_gw_bal_after := COALESCE(v_gw.available_balance, 0) + v_gift.group_amount;
    UPDATE public.group_wallets
    SET available_balance = v_gw_bal_after,
        total_earned      = COALESCE(total_earned, 0) + v_gift.group_amount,
        updated_at        = NOW()
    WHERE id = v_gw.id;
  END IF;

  INSERT INTO public.wallet_transactions
    (group_wallet_id, group_id, type, amount, gift_id, description, balance_after, currency_code)
  VALUES
    (v_gw.id, v_gift.group_id, 'gift_income', v_gift.group_amount, v_gift.id,
     'Regalo recibido', v_gw_bal_after, v_gift.currency_code);

  -- ── Comisión Daricefy (40%) — directo a available, sin pending ──────
  v_admin_id := public.get_platform_admin_id();
  IF v_admin_id IS NOT NULL THEN
    INSERT INTO public.wallets (user_id) VALUES (v_admin_id) ON CONFLICT (user_id) DO NOTHING;

    IF v_gift.currency_code = 'USD' THEN
      UPDATE public.wallets
      SET available_balance_usd = COALESCE(available_balance_usd, 0) + v_gift.platform_amount,
          total_earned_usd      = COALESCE(total_earned_usd, 0) + v_gift.platform_amount,
          updated_at            = NOW()
      WHERE user_id = v_admin_id;
    ELSE
      UPDATE public.wallets
      SET available_balance = available_balance + v_gift.platform_amount,
          total_earned      = COALESCE(total_earned, 0) + v_gift.platform_amount,
          updated_at        = NOW()
      WHERE user_id = v_admin_id;
    END IF;

    INSERT INTO public.wallet_transactions
      (user_id, type, amount, gift_id, description, currency_code)
    VALUES
      (v_admin_id, 'commission', v_gift.platform_amount, v_gift.id,
       'Comisión por regalo', v_gift.currency_code);
  END IF;

  RETURN jsonb_build_object(
    'ok', true,
    'group_amount', v_gift.group_amount,
    'platform_amount', v_gift.platform_amount,
    'currency', v_gift.currency_code
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.confirm_gift_payment(UUID, TEXT) TO service_role;

SELECT '567_gift_payment_credit.sql ejecutado ✅' AS status;
