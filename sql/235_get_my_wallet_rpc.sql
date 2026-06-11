-- ============================================================
-- sql/235_get_my_wallet_rpc.sql
--
-- WalletScreen consultaba wallets y wallet_transactions directamente.
-- Si RLS bloquea el query del cliente, el saldo aparece como $0
-- aunque los datos existan.
-- Solución: RPC SECURITY DEFINER que devuelve wallet + transacciones
-- del usuario autenticado, sin depender de que RLS esté configurado
-- correctamente en el cliente.
-- ============================================================

CREATE OR REPLACE FUNCTION public.get_my_wallet()
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_uid  UUID;
  v_role TEXT;
  v_wallet  JSONB;
  v_txs     JSONB;
BEGIN
  v_uid := auth.uid();
  IF v_uid IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'unauthenticated');
  END IF;

  SELECT role INTO v_role FROM profiles WHERE id = v_uid;

  IF v_role = 'group' THEN
    -- Grupos: retornar desde group_wallets
    SELECT to_jsonb(gw) INTO v_wallet
    FROM group_wallets gw
    JOIN groups g ON g.id = gw.group_id
    WHERE g.owner_id = v_uid
    LIMIT 1;

    SELECT jsonb_agg(t ORDER BY t.created_at DESC) INTO v_txs
    FROM (
      SELECT *
      FROM wallet_transactions
      WHERE group_id IN (SELECT id FROM groups WHERE owner_id = v_uid)
      ORDER BY created_at DESC
      LIMIT 50
    ) t;

  ELSE
    -- Admin / talent / client: retornar desde wallets
    SELECT to_jsonb(w) INTO v_wallet
    FROM wallets w
    WHERE w.user_id = v_uid
    LIMIT 1;

    SELECT jsonb_agg(t ORDER BY t.created_at DESC) INTO v_txs
    FROM (
      SELECT *
      FROM wallet_transactions
      WHERE user_id = v_uid
      ORDER BY created_at DESC
      LIMIT 50
    ) t;
  END IF;

  RETURN jsonb_build_object(
    'ok',           true,
    'role',         v_role,
    'wallet',       COALESCE(v_wallet, '{}'::JSONB),
    'transactions', COALESCE(v_txs, '[]'::JSONB)
  );
END;
$$;
GRANT EXECUTE ON FUNCTION public.get_my_wallet() TO authenticated;

SELECT '235_get_my_wallet_rpc.sql ejecutado ✅' AS status;
