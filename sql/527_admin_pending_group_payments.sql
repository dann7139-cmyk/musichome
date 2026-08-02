-- ============================================================
-- sql/527_admin_pending_group_payments.sql
-- Fase P1B — Cola automática de pagos pendientes por reservation_id
--
-- Solo lectura/visualización administrativa. NO mueve dinero, NO crea
-- withdrawals, NO modifica group_wallets, NO toca release_group_earnings_atomic.
--
-- Muestra automáticamente toda reservation liberada (payout_status='released')
-- con group_earnings > 0, sin depender de que el grupo solicite nada.
--
-- total_anticipado queda fijo en 0 y saldo_pendiente = group_earnings porque
-- la tabla group_reservation_payments (Fase P1C) todavía no existe — es una
-- aproximación explícitamente provisional, etiquetada como tal en el frontend
-- ("Saldo estimado, sin descontar anticipos"). Cuando exista P1C, esta función
-- se reemplaza con CREATE OR REPLACE para sumar el ledger real.
--
-- Verificado antes de este archivo (solo lectura, sin escritura):
--   - withdrawals: 0 filas en cualquier estado
--   - wallet_transactions tipo 'debit_payout': 0 filas (nunca salió dinero
--     por la vía vieja)
--   - reservations con payout_status='released': 0 filas
-- Es decir: la cola nace vacía, sin ningún caso real al que la aproximación
-- pueda estarle mintiendo al admin hoy.
--
-- Rollback: sql/527_admin_pending_group_payments_ROLLBACK.sql (DROP FUNCTION).
-- ============================================================

BEGIN;

CREATE OR REPLACE FUNCTION public.admin_get_pending_group_payments(p_limit integer DEFAULT 50)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE
  v_result jsonb;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM profiles WHERE id = auth.uid() AND role = 'admin') THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_admin');
  END IF;

  SELECT jsonb_build_object(
    'ok', true,
    'items', COALESCE(jsonb_agg(x.item ORDER BY x.event_date DESC NULLS LAST), '[]'::jsonb)
  )
  INTO v_result
  FROM (
    SELECT
      r.event_date,
      jsonb_build_object(
        'reservation_id',   r.id,
        'folio',            r.folio,
        'event_date',       r.event_date,
        'event_time',       r.event_time,
        'group_id',         r.group_id,
        'group_name',       g.name,
        'client_name',      p.full_name,
        'group_earnings',   r.group_earnings,
        'total_anticipado', 0,                  -- [P1C] reemplaza por SUM real cuando exista el ledger
        'saldo_pendiente',  r.group_earnings,    -- = group_earnings hasta que exista P1C
        'bank_clabe',       w.bank_clabe,
        'bank_name',        w.bank_name,
        'account_holder',   w.account_holder,
        'bank_linked_at',   w.bank_linked_at
      ) AS item
    FROM reservations r
    JOIN      groups   g ON g.id = r.group_id
    LEFT JOIN profiles p ON p.id = r.client_id
    LEFT JOIN wallets   w ON w.user_id = g.owner_id
    WHERE r.payout_status  = 'released'
      AND r.payment_status IN ('paid','fully_paid','deposit_paid')
      AND COALESCE(r.group_earnings, 0) > 0
    ORDER BY r.event_date DESC NULLS LAST
    LIMIT p_limit
  ) x;

  RETURN v_result;
END;
$function$;

COMMIT;

-- ── Verificación ──────────────────────────────────────────────────
SELECT
  proname,
  pg_get_function_identity_arguments(oid) AS firma,
  prosecdef AS es_security_definer
FROM pg_proc
WHERE pronamespace = 'public'::regnamespace AND proname = 'admin_get_pending_group_payments';

SELECT '527_admin_pending_group_payments ✅ — RPC solo lectura creada' AS status;
