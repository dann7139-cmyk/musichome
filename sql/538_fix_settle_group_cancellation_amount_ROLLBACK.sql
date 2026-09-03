-- ============================================================
-- sql/538_fix_settle_group_cancellation_amount_ROLLBACK.sql
-- Restaura settle_group_cancellation a la versión de sql/535c —
-- es decir, REINTRODUCE el bug confirmado (amount negativo bajo
-- type='adjustment', que viola wallet_transactions_amount_check
-- siempre que v_credited>0). Solo correr en caso de reversión
-- deliberada de sql/538.
-- ============================================================

BEGIN;

CREATE OR REPLACE FUNCTION public.settle_group_cancellation(
  p_reservation_id uuid,
  p_refund_id text DEFAULT NULL::text,
  p_reason text DEFAULT 'group_cancelled'::text,
  p_claim_id uuid DEFAULT NULL::uuid
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE
  v_group_id   UUID;
  v_res        RECORD;
  v_currency   TEXT;
  v_credited   NUMERIC;
  v_wallet     RECORD;
  v_owner      UUID;
  v_gname      TEXT;
  v_strikes    INT;
  v_suspended  BOOLEAN := FALSE;
  v_admin_id   UUID;
  v_ya_transferido NUMERIC;
BEGIN
  SELECT group_id INTO v_group_id FROM reservations WHERE id = p_reservation_id;
  IF v_group_id IS NULL THEN RETURN jsonb_build_object('ok', false, 'error', 'not_found'); END IF;

  PERFORM pg_advisory_xact_lock(hashtext(v_group_id::text));
  SELECT * INTO v_res FROM reservations WHERE id = p_reservation_id FOR UPDATE;
  IF v_res.group_id IS DISTINCT FROM v_group_id THEN
    RETURN jsonb_build_object('ok', false, 'error', 'temporary_retry');
  END IF;

  IF v_res.status = 'cancelled' AND v_res.payout_status = 'refunded' THEN
    RETURN jsonb_build_object('ok', true, 'skipped', true, 'reason', 'already_settled');
  END IF;

  IF v_res.payout_status NOT IN ('held', 'blocked') THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_cancellable',
      'payout_status', v_res.payout_status);
  END IF;

  v_currency := v_res.currency_code;
  IF v_currency IS NULL OR v_currency NOT IN ('MXN','USD') THEN
    RETURN jsonb_build_object('ok', false, 'error', 'unsupported_currency', 'currency_code', v_currency);
  END IF;

  SELECT COALESCE(SUM(amount),0) INTO v_ya_transferido
  FROM group_reservation_payments WHERE reservation_id = p_reservation_id;
  IF v_ya_transferido > 0 THEN
    INSERT INTO financial_audit_logs (entity_type, entity_id, action, actor_id, actor_role, amount, notes)
    VALUES ('reservation', p_reservation_id, 'refund_blocked_manual_payment_exists', NULL, 'system', v_ya_transferido,
      format('Cancelación de grupo intentada pero ya se transfirieron $%s %s manualmente al músico — requiere reconciliación manual', v_ya_transferido, v_currency));
    INSERT INTO notifications (user_id, type, title, body, data)
    SELECT p.id, 'admin', '🚨 Cancelación bloqueada — ya hubo pago manual',
      format('La reserva %s ya tiene $%s %s transferidos al músico. Requiere reconciliación manual.', p_reservation_id, v_ya_transferido, v_currency),
      jsonb_build_object('reservation_id', p_reservation_id, 'screen', 'AdminFinancial')
    FROM profiles p WHERE p.role = 'admin';
    RETURN jsonb_build_object('ok', false, 'error', 'manual_payment_already_transferred', 'amount_already_paid', v_ya_transferido);
  END IF;

  SELECT owner_id, name INTO v_owner, v_gname FROM groups WHERE id = v_res.group_id;

  SELECT COALESCE(SUM(amount),0) INTO v_credited
  FROM wallet_transactions WHERE reservation_id = p_reservation_id AND type = 'credit_pending';

  PERFORM ensure_group_wallet(v_res.group_id);
  SELECT * INTO v_wallet FROM group_wallets WHERE group_id = v_res.group_id FOR UPDATE;

  CASE v_currency
    WHEN 'MXN' THEN
      UPDATE group_wallets SET
        pending_balance = GREATEST(0, pending_balance - v_credited),
        total_earned    = GREATEST(0, total_earned - v_credited),
        updated_at      = NOW()
      WHERE id = v_wallet.id;
    WHEN 'USD' THEN
      UPDATE group_wallets SET
        pending_balance_usd = GREATEST(0, pending_balance_usd - v_credited),
        total_earned_usd    = GREATEST(0, total_earned_usd - v_credited),
        updated_at           = NOW()
      WHERE id = v_wallet.id;
  END CASE;

  INSERT INTO wallet_transactions
    (group_wallet_id, group_id, type, amount, reservation_id, description, balance_after, currency_code)
  VALUES (v_wallet.id, v_res.group_id, 'adjustment', -v_credited, p_reservation_id,
    format('Reversión total — el grupo canceló la reserva %s', p_reservation_id),
    NULL, v_currency);

  UPDATE reservations SET
    status            = 'cancelled',
    cancelled_by      = 'group',
    cancellation_type = 'group_initiated',
    cancel_reason     = p_reason,
    cancelled_at      = NOW(),
    payout_status     = 'refunded',
    updated_at        = NOW()
  WHERE id = p_reservation_id;

  IF p_claim_id IS NOT NULL THEN
    UPDATE provider_refund_claims SET status = 'done', updated_at = NOW() WHERE id = p_claim_id;
  END IF;

  INSERT INTO group_strikes (group_id, reservation_id, strike_type, issued_by, note)
  VALUES (v_res.group_id, p_reservation_id, 'late_cancel', COALESCE(v_owner, v_res.client_id),
          'Cancelación de evento pagado iniciada por el grupo (automático)');

  UPDATE groups SET
    strike_count             = COALESCE(strike_count, 0) + 1,
    last_strike_at           = NOW(),
    is_verified              = FALSE,
    visibility_penalty_until = NOW() + INTERVAL '30 days',
    updated_at               = NOW()
  WHERE id = v_res.group_id
  RETURNING strike_count INTO v_strikes;

  IF v_strikes >= 3 THEN
    UPDATE groups SET suspended_at = NOW(), is_active = FALSE WHERE id = v_res.group_id;
    UPDATE group_strikes SET auto_suspended = TRUE
    WHERE group_id = v_res.group_id AND reservation_id = p_reservation_id;
    v_suspended := TRUE;
  END IF;

  INSERT INTO financial_audit_logs
    (entity_type, entity_id, action, actor_id, actor_role, amount, notes)
  VALUES ('reservation', p_reservation_id, 'group_cancellation_settle', v_owner, 'group',
    v_res.total_price,
    format('reembolso_total=%s currency=%s strike=%s/3 suspendido=%s refund_id=%s',
      v_res.total_price, v_currency, v_strikes, v_suspended, COALESCE(p_refund_id, 'n/a')));

  IF v_owner IS NOT NULL THEN
    INSERT INTO notifications (user_id, type, title, body, data)
    VALUES (v_owner, 'reservation',
      CASE WHEN v_suspended THEN '🚫 Tu grupo fue SUSPENDIDO'
           ELSE format('⚡ Strike %s de 3 por cancelar', v_strikes) END,
      CASE WHEN v_suspended
        THEN 'Acumulaste 3 strikes y tu grupo quedó suspendido de la plataforma. Contacta a soporte.'
        ELSE format('Cancelaste un evento pagado. El cliente recibe su reembolso completo, perdiste tu insignia de verificado y tu grupo tendrá menos visibilidad por 30 días. Al strike 3 tu grupo se suspende. Strikes: %s/3.', v_strikes)
      END,
      jsonb_build_object('reservation_id', p_reservation_id, 'screen', 'GroupReservations'));
  END IF;

  SELECT id INTO v_admin_id FROM profiles WHERE role = 'admin' ORDER BY created_at LIMIT 1;
  IF v_admin_id IS NOT NULL THEN
    INSERT INTO notifications (user_id, type, title, body, data)
    VALUES (v_admin_id, 'admin',
      '🚨 Grupo canceló evento pagado',
      format('%s canceló la reserva %s. Reembolso 100%% al cliente ($%s %s). Strike %s/3%s.',
        COALESCE(v_gname, 'Grupo'), COALESCE(v_res.folio, p_reservation_id::text),
        to_char(v_res.total_price, 'FM999,999,990'), v_currency, v_strikes,
        CASE WHEN v_suspended THEN ' — GRUPO SUSPENDIDO' ELSE '' END),
      jsonb_build_object('reservation_id', p_reservation_id, 'screen', 'AdminFinancial'));
  END IF;

  RETURN jsonb_build_object('ok', true,
    'refund_amount', v_res.total_price,
    'currency', v_currency,
    'strikes', v_strikes,
    'suspended', v_suspended);
END;
$function$;

COMMIT;

SELECT '538_fix_settle_group_cancellation_amount ROLLBACK ⚠️ (reintroduce el bug de amount negativo a propósito)' AS status;
