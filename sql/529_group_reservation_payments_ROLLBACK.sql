-- ============================================================
-- sql/529_group_reservation_payments_ROLLBACK.sql
-- Revierte sql/529_group_reservation_payments.sql
--
-- Restaura release_group_earnings_atomic() y chk_wt_type byte a byte a como
-- estaban antes (capturados vía pg_get_functiondef/pg_get_constraintdef en
-- producción antes del cambio). Restaura admin_get_pending_group_payments a
-- la versión de sql/527 (total_anticipado=0 fijo). Elimina la tabla nueva y
-- el RPC de escritura.
--
-- Solo correr en caso de reversión deliberada de la Fase P1C.
-- ============================================================

BEGIN;

DROP FUNCTION IF EXISTS public.admin_register_group_payment(UUID, NUMERIC, TEXT, TEXT, TEXT);
DROP TABLE IF EXISTS public.group_reservation_payments;

ALTER TABLE public.wallet_transactions DROP CONSTRAINT chk_wt_type;
ALTER TABLE public.wallet_transactions ADD CONSTRAINT chk_wt_type
  CHECK ((type = ANY (ARRAY['credit_pending'::text, 'credit_available'::text, 'release_to_available'::text, 'debit_payout'::text, 'refund_dispute'::text, 'adjustment'::text, 'event_earning'::text, 'extra_hour'::text, 'withdrawal'::text, 'commission'::text, 'refund'::text, 'platform_income'::text, 'debit_refund'::text, 'ad_income'::text, 'bid_income'::text, 'recommendation_income'::text, 'commission_correction'::text])));

CREATE OR REPLACE FUNCTION public.release_group_earnings_atomic(p_reservation_id uuid, p_released_by uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_reservation RECORD;
  v_wallet      RECORD;
  v_total       NUMERIC;
  v_to_release  NUMERIC;
  v_actor_role  TEXT := 'system';
  v_currency    TEXT;
BEGIN
  SELECT * INTO v_reservation FROM reservations WHERE id = p_reservation_id FOR UPDATE;
  IF NOT FOUND THEN RETURN jsonb_build_object('ok', false, 'error', 'not_found'); END IF;

  IF v_reservation.payout_status = 'released' THEN
    RETURN jsonb_build_object('ok', true, 'skipped', true, 'reason', 'already_released');
  END IF;
  IF v_reservation.payout_status IN ('blocked','refunded') THEN
    RETURN jsonb_build_object('ok', false, 'error', 'payout_blocked',
      'payout_status', v_reservation.payout_status);
  END IF;
  IF v_reservation.payment_status NOT IN ('paid','fully_paid','deposit_paid') THEN
    RETURN jsonb_build_object('ok', false, 'error', 'payment_not_confirmed');
  END IF;
  IF EXISTS (
    SELECT 1 FROM disputes
    WHERE reservation_id = p_reservation_id AND status IN ('open','under_review')
  ) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'open_dispute_blocks_release');
  END IF;

  IF NOT (v_reservation.group_arrived_at IS NOT NULL OR COALESCE(v_reservation.arrival_verified, false)) THEN
    RETURN jsonb_build_object('ok', true, 'skipped', true, 'reason', 'no_arrival_verification');
  END IF;

  IF p_released_by IS NOT NULL THEN
    SELECT COALESCE(role,'unknown') INTO v_actor_role FROM profiles WHERE id = p_released_by;
  END IF;

  v_currency := COALESCE(v_reservation.currency_code, 'MXN');

  PERFORM ensure_group_wallet(v_reservation.group_id);
  SELECT * INTO v_wallet FROM group_wallets WHERE group_id = v_reservation.group_id FOR UPDATE;

  v_total := COALESCE(v_reservation.group_earnings,
               COALESCE(v_reservation.base_price,
                 ROUND(v_reservation.total_price * 0.9, 2)));
  v_to_release := CASE
    WHEN v_reservation.payout_status = 'half_released' THEN v_total - ROUND(v_total / 2, 2)
    ELSE v_total
  END;

  IF v_currency = 'USD' THEN
    UPDATE group_wallets SET
      pending_balance_usd   = GREATEST(0, pending_balance_usd - v_to_release),
      available_balance_usd = available_balance_usd + v_to_release,
      updated_at            = NOW()
    WHERE id = v_wallet.id;
  ELSE
    UPDATE group_wallets SET
      pending_balance   = GREATEST(0, pending_balance - v_to_release),
      available_balance = available_balance + v_to_release,
      updated_at        = NOW()
    WHERE id = v_wallet.id;
  END IF;

  UPDATE reservations SET
    payout_status = 'released', released_at = NOW(),
    released_by = p_released_by, wallet_released_at = NOW(), updated_at = NOW()
  WHERE id = p_reservation_id;

  INSERT INTO wallet_transactions
    (group_wallet_id, group_id, type, amount, reservation_id, description, balance_after, currency_code)
  VALUES (v_wallet.id, v_reservation.group_id, 'credit_available', v_to_release,
    p_reservation_id,
    CASE WHEN v_reservation.payout_status = 'half_released'
      THEN format('50%% final al terminar evento — reserva %s', p_reservation_id)
      ELSE format('Ganancias liberadas post-evento — reserva %s', p_reservation_id)
    END,
    CASE WHEN v_currency = 'USD'
      THEN v_wallet.available_balance_usd + v_to_release
      ELSE v_wallet.available_balance + v_to_release
    END,
    v_currency);

  INSERT INTO financial_audit_logs
    (entity_type, entity_id, action, actor_id, actor_role, amount, notes)
  VALUES ('reservation', p_reservation_id, 'release', p_released_by, v_actor_role, v_to_release,
    format('currency=%s payout_status_was=%s', v_currency, v_reservation.payout_status));

  INSERT INTO notifications (user_id, type, title, body, data)
  SELECT g.owner_id, 'payout', '🎉 Ganancias liberadas',
    format('$%s %s disponibles en tu billetera.',
      to_char(v_to_release, 'FM999,999,990'), v_currency),
    jsonb_build_object('screen','Wallet','reservation_id',p_reservation_id)
  FROM groups g WHERE g.id = v_reservation.group_id;

  RETURN jsonb_build_object(
    'ok',            true,
    'released',      v_to_release,
    'currency',      v_currency,
    'payout_status', 'released'
  );
END;
$function$;

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
        'total_anticipado', 0,
        'saldo_pendiente',  r.group_earnings,
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

SELECT '529_group_reservation_payments_ROLLBACK ✅' AS status;
