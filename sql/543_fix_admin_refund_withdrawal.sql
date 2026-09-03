-- ============================================================
-- sql/543_fix_admin_refund_withdrawal.sql
--
-- BUG CONFIRMADO (auditoría 2026-08-09): admin_refund_withdrawal
-- intenta insertar en wallet_transactions una columna `status` que
-- NO EXISTE en esa tabla. El INSERT siempre lanza excepción, que se
-- captura en el EXCEPTION WHEN OTHERS del final de la función — como
-- todo el cuerpo de la función es ese bloque protegido, TODO se
-- revierte (el UPDATE de withdrawals.status y el UPSERT de
-- wallets.available_balance incluidos). Resultado: la función nunca
-- ha funcionado desde que se creó (sql/88); no hay ningún dato
-- histórico afectado (withdrawals tiene 0 filas en producción, sin
-- retiros rechazados ni pendientes).
--
-- CORRECCIÓN (única, autorizada explícitamente, alcance mínimo):
--   1. Quitar `status` del INSERT a wallet_transactions — esa tabla
--      no la tiene. Se mantiene `type='refund'` y el resto de columnas
--      igual que el archivo original.
--   2. Higiene de grants: revocar EXECUTE de PUBLIC y anon (heredado
--      por default de Postgres, nunca revocado en sql/88), dejar
--      explícito authenticated + service_role. Confirmado 0 callers
--      reales antes de este cambio — no rompe nada.
--
-- NO CAMBIA:
--   - Firma de la función (misma, 1 parámetro).
--   - Ninguna otra línea del cuerpo (guard not_admin, lock FOR UPDATE,
--     chequeo already_processed, UPDATE de withdrawals, UPSERT de
--     wallets, notificación, RETURN, EXCEPTION handler).
--   - Sin soporte USD, sin tocar el esquema de withdrawals.
--   - Sin reparación de datos históricos (no existen).
-- ============================================================

BEGIN;

CREATE OR REPLACE FUNCTION public.admin_refund_withdrawal(
  p_withdrawal_id UUID
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
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

  -- Registrar transacción de devolución (wallet_transactions no tiene
  -- columna `status` — se quitó del INSERT, único cambio real de esta
  -- migración).
  INSERT INTO public.wallet_transactions
    (user_id, amount, type, description)
  VALUES
    (v_wd.user_id, v_wd.amount, 'refund',
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
$function$;

-- Higiene de grants: revocar el PUBLIC/anon heredado por default,
-- dejar explícito solo lo que realmente lo necesita.
REVOKE EXECUTE ON FUNCTION public.admin_refund_withdrawal(UUID) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.admin_refund_withdrawal(UUID) FROM anon;
GRANT EXECUTE ON FUNCTION public.admin_refund_withdrawal(UUID) TO authenticated, service_role;

COMMIT;

-- ════════════════════════════════════════════════════════════════════
-- VERIFICACIONES (ejecutar separado después del COMMIT)
-- ════════════════════════════════════════════════════════════════════

-- V1: firma sin cambios
SELECT COUNT(*) = 1 AS firma_correcta
FROM   pg_proc p
JOIN   pg_namespace n ON n.oid = p.pronamespace
WHERE  n.nspname = 'public'
  AND  p.proname = 'admin_refund_withdrawal'
  AND  pg_get_function_identity_arguments(p.oid) = 'p_withdrawal_id uuid';
-- Esperado: true

-- V2: SECURITY DEFINER
SELECT prosecdef FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'public' AND p.proname = 'admin_refund_withdrawal';
-- Esperado: true

-- V3: ya no referencia la columna status en el INSERT roto
SELECT
  routine_definition NOT LIKE '%(user_id, amount, type, status, description)%' AS ya_no_usa_status_inexistente,
  routine_definition LIKE '%(user_id, amount, type, description)%' AS insert_corregido
FROM information_schema.routines
WHERE routine_schema = 'public' AND routine_name = 'admin_refund_withdrawal';
-- Esperado: true | true

-- V4: grants correctos — ni PUBLIC ni anon, sí authenticated y service_role
SELECT grantee, privilege_type
FROM information_schema.role_routine_grants
WHERE routine_schema = 'public' AND routine_name = 'admin_refund_withdrawal'
ORDER BY grantee;
-- Esperado: solo authenticated y service_role (y postgres como dueño, implícito)

SELECT '543_fix_admin_refund_withdrawal ✅' AS status;
