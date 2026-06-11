-- ════════════════════════════════════════════════════════════════════
-- 88_admin_refund_withdrawal.sql
-- RPC segura para que el admin rechace una solicitud de retiro y
-- devuelva el monto al available_balance del usuario.
-- Ejecutar DESPUÉS de 61_distribute_event_earnings.sql y 62_wallet_bank_account.sql
-- ════════════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION public.admin_refund_withdrawal(
  p_withdrawal_id UUID
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_admin_id UUID := auth.uid();
  v_wd       RECORD;
BEGIN
  -- Solo admins
  IF NOT EXISTS (
    SELECT 1 FROM public.profiles
    WHERE id = v_admin_id AND role = 'admin'
  ) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_admin');
  END IF;

  -- Bloquear fila
  SELECT * INTO v_wd
  FROM public.withdrawals
  WHERE id = p_withdrawal_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'withdrawal_not_found');
  END IF;

  -- Solo rechazar si está pendiente o procesando
  IF v_wd.status NOT IN ('pending', 'processing') THEN
    RETURN jsonb_build_object('ok', false, 'error', 'already_processed',
      'status', v_wd.status);
  END IF;

  -- Marcar como rechazado
  UPDATE public.withdrawals
  SET status           = 'rejected',
      rejection_reason = 'Rechazado por administrador',
      processed_at     = NOW()
  WHERE id = p_withdrawal_id;

  -- Devolver saldo al usuario
  INSERT INTO public.wallets (user_id, available_balance)
  VALUES (v_wd.user_id, v_wd.amount)
  ON CONFLICT (user_id) DO UPDATE
    SET available_balance = public.wallets.available_balance + EXCLUDED.available_balance,
        updated_at        = NOW();

  -- Registrar transacción de devolución
  INSERT INTO public.wallet_transactions
    (user_id, amount, type, status, description)
  VALUES
    (v_wd.user_id, v_wd.amount, 'refund', 'completed',
     'Devolución por retiro rechazado #' || p_withdrawal_id::TEXT);

  -- Notificar al usuario
  INSERT INTO public.notifications (user_id, type, title, body, data)
  VALUES (
    v_wd.user_id,
    'payment',
    '❌ Retiro rechazado',
    'Tu retiro de $' || v_wd.amount::TEXT || ' MXN fue rechazado. El dinero fue devuelto a tu billetera.',
    jsonb_build_object('withdrawal_id', p_withdrawal_id, 'screen', 'Wallet')
  );

  RETURN jsonb_build_object(
    'ok',     true,
    'amount', v_wd.amount,
    'user_id', v_wd.user_id
  );

EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$$;

GRANT EXECUTE ON FUNCTION public.admin_refund_withdrawal(UUID) TO authenticated;

SELECT '88_admin_refund_withdrawal: RPC admin_refund_withdrawal creada ✅' AS status;
