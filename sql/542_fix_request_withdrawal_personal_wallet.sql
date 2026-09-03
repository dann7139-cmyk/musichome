-- ============================================================
-- sql/542_fix_request_withdrawal_personal_wallet.sql
--
-- BUG CONFIRMADO (auditoría 2026-08-09): request_withdrawal bloquea
-- explícitamente role='group' (correcto, P1F) pero el único camino que
-- queda para cualquier OTRO rol (admin/talent/client) resuelve el
-- wallet vía `groups WHERE owner_id = auth.uid()` — ninguno de esos
-- roles es dueño de una fila en `groups`, así que la función retorna
-- 'no_group' SIEMPRE. Efecto: el botón "Retirar" está roto para todo
-- rol que no sea 'group' (que además está bloqueado a propósito).
-- Verificado en producción: admin real con available_balance=1408.20
-- MXN en `wallets`, owns_a_group=false — retiro imposible hoy.
--
-- CORRECCIÓN (única, autorizada explícitamente):
--   Reemplazar la resolución rota (`groups.owner_id`) por la resolución
--   correcta para wallet personal (`wallets.user_id`) para cualquier
--   rol distinto de 'group'. Ya es el diseño documentado en el propio
--   código (WalletScreen.tsx: "Roles distintos de group... wallet
--   personal en wallets... ese flujo no cambia aquí") — nunca se había
--   completado en el backend.
--
-- NO CAMBIA:
--   - Firma de la función (misma, 4 parámetros).
--   - Guard ni mensaje de role='group' — byte-idéntico.
--   - Ningún otro RPC (admin_withdrawals_queue, admin_complete_payout,
--     admin_refund_withdrawal — huérfana y con bug propio documentado
--     aparte, no tocada aquí).
--   - Alcance exclusivo MXN — available_balance / currency_code='MXN'.
--     Sin soporte USD (ningún rol tiene botón de retiro en USD hoy).
--
-- Idempotencia/seguridad: mismo mecanismo que la rama de grupo ya
-- tenía — SELECT ... FOR UPDATE sobre la fila de wallet antes de
-- validar saldo y descontar, dentro de la misma transacción de la
-- función. SECURITY DEFINER + search_path fijo, sin cambios.
-- ============================================================

BEGIN;

CREATE OR REPLACE FUNCTION public.request_withdrawal(p_amount numeric, p_bank_clabe text, p_bank_name text, p_account_holder text)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE
  v_user_id  UUID := auth.uid();
  v_wallet   RECORD;
  v_wd_id    UUID;
BEGIN
  IF v_user_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_authenticated');
  END IF;

  IF EXISTS (SELECT 1 FROM profiles WHERE id = v_user_id AND role = 'group') THEN
    RETURN jsonb_build_object('ok', false, 'error', 'group_self_withdrawal_disabled',
      'hint', 'Usa "Solicitar pago" desde tu Wallet — el admin realiza la transferencia.');
  END IF;

  IF p_amount IS NULL OR p_amount <= 0 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_amount');
  END IF;

  -- Wallet personal (admin/talent/client) — mismo mecanismo de lock que
  -- la rama de grupo tenía sobre group_wallets, ahora sobre `wallets`.
  -- Solo bucket MXN (available_balance): ningún rol tiene hoy flujo de
  -- retiro en USD.
  SELECT * INTO v_wallet FROM public.wallets WHERE user_id = v_user_id FOR UPDATE;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'wallet_not_found');
  END IF;

  IF v_wallet.available_balance < p_amount THEN
    RETURN jsonb_build_object('ok', false, 'error', 'insufficient_balance',
      'available', v_wallet.available_balance);
  END IF;

  INSERT INTO public.withdrawals
    (user_id, amount, status, payout_method, bank_clabe, bank_name, account_holder)
  VALUES
    (v_user_id, p_amount, 'pending', 'spei', p_bank_clabe, p_bank_name, p_account_holder)
  RETURNING id INTO v_wd_id;

  UPDATE public.wallets
  SET available_balance = available_balance - p_amount,
      updated_at        = NOW()
  WHERE id = v_wallet.id;

  INSERT INTO public.wallet_transactions
    (user_id, type, amount, description, balance_after, currency_code)
  VALUES
    (v_user_id, 'debit_payout', p_amount,
     format('Retiro SPEI solicitado $%s MXN', p_amount),
     v_wallet.available_balance - p_amount,
     'MXN');

  INSERT INTO public.notifications (user_id, type, title, body, data)
  VALUES (
    v_user_id, 'payout',
    '🏦 Retiro en proceso',
    format('Tu retiro de $%s MXN está siendo procesado.', to_char(p_amount, 'FM999,999,990')),
    jsonb_build_object('withdrawal_id', v_wd_id, 'screen', 'Wallet')
  );

  -- Notificar a admins (excluyendo al propio solicitante si es admin,
  -- para no autonotificarse).
  INSERT INTO public.notifications (user_id, type, title, body, data)
  SELECT p.id, 'payout',
    format('💸 Solicitud de retiro — $%s', to_char(p_amount, 'FM999,999,990')),
    format('%s solicitó retirar $%s MXN vía SPEI.',
      COALESCE((SELECT full_name FROM public.profiles WHERE id = v_user_id), 'Un usuario'),
      to_char(p_amount, 'FM999,999,990')),
    jsonb_build_object('withdrawal_id', v_wd_id, 'user_id', v_user_id, 'screen', 'Withdrawals')
  FROM public.profiles p
  WHERE p.role = 'admin' AND p.id <> v_user_id;

  RETURN jsonb_build_object(
    'ok',            true,
    'withdrawal_id', v_wd_id,
    'amount',        p_amount,
    'new_balance',   v_wallet.available_balance - p_amount
  );

EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$function$;

GRANT EXECUTE ON FUNCTION public.request_withdrawal(NUMERIC, TEXT, TEXT, TEXT) TO authenticated;

COMMIT;

-- ════════════════════════════════════════════════════════════════════
-- VERIFICACIONES (ejecutar separado después del COMMIT)
-- ════════════════════════════════════════════════════════════════════

-- V1: Función existe con la misma firma de siempre (4 args, sin cambio)
SELECT COUNT(*) = 1 AS firma_correcta
FROM   pg_proc p
JOIN   pg_namespace n ON n.oid = p.pronamespace
WHERE  n.nspname = 'public'
  AND  p.proname = 'request_withdrawal'
  AND  pg_get_function_identity_arguments(p.oid) =
       'p_amount numeric, p_bank_clabe text, p_bank_name text, p_account_holder text';
-- Esperado: true

-- V2: SECURITY DEFINER activo
SELECT prosecdef AS is_security_definer
FROM   pg_proc p
JOIN   pg_namespace n ON n.oid = p.pronamespace
WHERE  n.nspname = 'public' AND p.proname = 'request_withdrawal';
-- Esperado: true

-- V3: Grant a authenticated
SELECT COUNT(*) > 0 AS grant_authenticated
FROM   information_schema.role_routine_grants
WHERE  routine_schema = 'public'
  AND  routine_name   = 'request_withdrawal'
  AND  grantee         = 'authenticated';
-- Esperado: true

-- V4: la rama de role='group' sigue intacta (mismo mensaje/hint)
SELECT
  routine_definition LIKE '%group_self_withdrawal_disabled%' AS mantiene_guard_group,
  routine_definition LIKE '%Usa "Solicitar pago" desde tu Wallet%' AS mantiene_hint_group
FROM information_schema.routines
WHERE routine_schema = 'public' AND routine_name = 'request_withdrawal';
-- Esperado: true | true

-- V5: la nueva resolución usa `wallets` por user_id, ya no `groups.owner_id`
SELECT
  routine_definition LIKE '%FROM public.wallets WHERE user_id = v_user_id FOR UPDATE%' AS usa_wallet_personal,
  routine_definition NOT LIKE '%FROM public.groups WHERE owner_id = v_user_id%' AS ya_no_asume_grupo
FROM information_schema.routines
WHERE routine_schema = 'public' AND routine_name = 'request_withdrawal';
-- Esperado: true | true

SELECT '542_fix_request_withdrawal_personal_wallet ✅' AS status;
