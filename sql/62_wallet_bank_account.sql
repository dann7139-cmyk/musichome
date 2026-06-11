-- ════════════════════════════════════════════════════════════════════
-- 62_wallet_bank_account.sql
-- Agrega columnas de cuenta bancaria a wallets para que el usuario
-- solo ingrese su CLABE una vez y quede guardada para retiros futuros.
-- ════════════════════════════════════════════════════════════════════

ALTER TABLE public.wallets
  ADD COLUMN IF NOT EXISTS bank_clabe       TEXT,
  ADD COLUMN IF NOT EXISTS bank_name        TEXT,
  ADD COLUMN IF NOT EXISTS account_holder   TEXT,
  ADD COLUMN IF NOT EXISTS bank_linked_at   TIMESTAMPTZ;

-- RPC: guardar/actualizar cuenta bancaria del usuario autenticado
CREATE OR REPLACE FUNCTION public.save_bank_account(
  p_clabe          TEXT,
  p_bank_name      TEXT,
  p_account_holder TEXT
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_user_id UUID := auth.uid();
BEGIN
  IF v_user_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_authenticated');
  END IF;

  IF p_clabe IS NULL OR length(p_clabe) != 18 OR p_clabe !~ '^\d{18}$' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_clabe');
  END IF;

  -- Crear wallet si no existe
  INSERT INTO public.wallets (user_id) VALUES (v_user_id)
  ON CONFLICT (user_id) DO NOTHING;

  UPDATE public.wallets
  SET bank_clabe      = p_clabe,
      bank_name       = p_bank_name,
      account_holder  = p_account_holder,
      bank_linked_at  = NOW(),
      updated_at      = NOW()
  WHERE user_id = v_user_id;

  RETURN jsonb_build_object('ok', true);
END;
$$;

GRANT EXECUTE ON FUNCTION public.save_bank_account(TEXT, TEXT, TEXT) TO authenticated;

SELECT '62_wallet_bank_account: columnas banco + RPC save_bank_account creados ✅' AS status;
