-- ════════════════════════════════════════════════════════════════════
-- sql/460_fix_request_withdrawal_group_wallet.sql
--
-- FIX: request_withdrawal (sql/61) leía/descontaba de `wallets` (nivel
-- usuario), pero las ganancias del grupo viven en `group_wallets`. Efecto:
-- el grupo veía su saldo (get_my_wallet → group_wallets) pero al retirar
-- obtenía insufficient_balance (wallets de usuario = 0). Los grupos NO
-- podían retirar.
--
-- Esta versión resuelve el grupo del usuario (owner_id = auth.uid()) y opera
-- sobre group_wallets.available_balance. Mantiene la tabla `withdrawals` y las
-- notificaciones. NO cambia el modelo de liberación (held/half/released).
-- ════════════════════════════════════════════════════════════════════

BEGIN;

CREATE OR REPLACE FUNCTION public.request_withdrawal(
  p_amount         NUMERIC,
  p_bank_clabe     TEXT,
  p_bank_name      TEXT,
  p_account_holder TEXT
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_user_id  UUID := auth.uid();
  v_group_id UUID;
  v_wallet   RECORD;
  v_wd_id    UUID;
BEGIN
  IF v_user_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_authenticated');
  END IF;

  -- El retiro es del GRUPO del usuario (sus ganancias viven en group_wallets)
  SELECT id INTO v_group_id FROM public.groups WHERE owner_id = v_user_id LIMIT 1;
  IF v_group_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'no_group');
  END IF;

  SELECT * INTO v_wallet
  FROM public.group_wallets
  WHERE group_id = v_group_id
  FOR UPDATE;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'wallet_not_found');
  END IF;

  IF p_amount <= 0 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_amount');
  END IF;

  IF v_wallet.available_balance < p_amount THEN
    RETURN jsonb_build_object('ok', false, 'error', 'insufficient_balance',
      'available', v_wallet.available_balance);
  END IF;

  -- Solicitud de retiro (misma tabla `withdrawals`)
  INSERT INTO public.withdrawals
    (user_id, amount, status, payout_method, bank_clabe, bank_name, account_holder)
  VALUES
    (v_user_id, p_amount, 'pending', 'spei', p_bank_clabe, p_bank_name, p_account_holder)
  RETURNING id INTO v_wd_id;

  -- Descontar del saldo DISPONIBLE del group_wallet
  UPDATE public.group_wallets
  SET available_balance = available_balance - p_amount,
      updated_at        = NOW()
  WHERE id = v_wallet.id;

  -- Movimiento en el ledger del group_wallet
  INSERT INTO public.wallet_transactions
    (group_wallet_id, group_id, type, amount, description, balance_after, currency_code)
  VALUES
    (v_wallet.id, v_group_id, 'debit_payout', p_amount,
     format('Retiro SPEI solicitado $%s MXN', p_amount),
     v_wallet.available_balance - p_amount,
     'MXN');

  -- Notificar al grupo
  INSERT INTO public.notifications (user_id, type, title, body, data)
  VALUES (
    v_user_id, 'payout',
    '🏦 Retiro en proceso',
    format('Tu retiro de $%s MXN está siendo procesado.', to_char(p_amount, 'FM999,999,990')),
    jsonb_build_object('withdrawal_id', v_wd_id, 'screen', 'Wallet')
  );

  -- Notificar a admins
  INSERT INTO public.notifications (user_id, type, title, body, data)
  SELECT p.id, 'payout',
    format('💸 Solicitud de retiro — $%s', to_char(p_amount, 'FM999,999,990')),
    'Un grupo solicitó retirar vía SPEI.',
    jsonb_build_object('withdrawal_id', v_wd_id, 'group_id', v_group_id, 'screen', 'Withdrawals')
  FROM public.profiles p
  WHERE p.role = 'admin';

  RETURN jsonb_build_object(
    'ok',            true,
    'withdrawal_id', v_wd_id,
    'amount',        p_amount,
    'new_balance',   v_wallet.available_balance - p_amount
  );

EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$$;

GRANT EXECUTE ON FUNCTION public.request_withdrawal(NUMERIC, TEXT, TEXT, TEXT) TO authenticated;

COMMIT;

-- ── Verificación ────────────────────────────────────────────────────
SELECT pg_get_functiondef(oid) LIKE '%group_wallets%' AS lee_group_wallets
FROM pg_proc
WHERE proname = 'request_withdrawal' AND pronamespace = 'public'::regnamespace;
-- Esperado: true
