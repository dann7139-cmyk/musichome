-- ============================================================
-- sql/539_p1f_client_claims_and_notifications_ROLLBACK.sql
--
-- Revierte sql/539: quita la política prc_client_read y restaura
-- process_refund_reversal a la versión previa (sin las notificaciones
-- cliente/owner) — byte idéntica a la instalada por sql/535c
-- (hash md5 verificado antes de 539: 2f1a35cdc980e73ba4ec086db04ceca8).
--
-- JAMÁS correr salvo emergencia deliberada.
-- ============================================================

BEGIN;

DROP POLICY IF EXISTS "prc_client_read" ON public.provider_refund_claims;

CREATE OR REPLACE FUNCTION public.process_refund_reversal(
  p_reservation_id uuid,
  p_mp_refund_id text DEFAULT NULL::text,
  p_refund_amount numeric DEFAULT NULL::numeric,
  p_claim_id uuid DEFAULT NULL::uuid
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE
  v_group_id       UUID;
  v_reservation    RECORD;
  v_wallet         RECORD;
  v_currency       TEXT;
  v_credited       NUMERIC;
  v_liberado       NUMERIC;
  v_reversal       NUMERIC;
  v_from_pending   NUMERIC;
  v_from_available NUMERIC;
  v_service_fee    NUMERIC;
  v_admin_id       UUID;
  v_ya_transferido NUMERIC;
BEGIN
  SELECT group_id INTO v_group_id FROM reservations WHERE id = p_reservation_id;
  IF v_group_id IS NULL THEN RETURN jsonb_build_object('ok', false, 'error', 'not_found'); END IF;

  PERFORM pg_advisory_xact_lock(hashtext(v_group_id::text));
  SELECT * INTO v_reservation FROM reservations WHERE id = p_reservation_id FOR UPDATE;
  IF v_reservation.group_id IS DISTINCT FROM v_group_id THEN
    RETURN jsonb_build_object('ok', false, 'error', 'temporary_retry');
  END IF;

  IF v_reservation.payout_status = 'refunded' THEN
    RETURN jsonb_build_object('ok', true, 'skipped', true, 'reason', 'already_refunded');
  END IF;

  v_currency := v_reservation.currency_code;
  IF v_currency IS NULL OR v_currency NOT IN ('MXN','USD') THEN
    RETURN jsonb_build_object('ok', false, 'error', 'unsupported_currency', 'currency_code', v_currency);
  END IF;

  SELECT COALESCE(SUM(amount),0) INTO v_ya_transferido
  FROM group_reservation_payments WHERE reservation_id = p_reservation_id;
  IF v_ya_transferido > 0 THEN
    INSERT INTO financial_audit_logs (entity_type, entity_id, action, actor_id, actor_role, amount, notes)
    VALUES ('reservation', p_reservation_id, 'refund_blocked_manual_payment_exists', NULL, 'system', v_ya_transferido,
      format('Refund intentado pero ya se transfirieron $%s %s manualmente al músico — requiere reconciliación manual', v_ya_transferido, v_currency));
    INSERT INTO notifications (user_id, type, title, body, data)
    SELECT p.id, 'admin', '🚨 Reembolso bloqueado — ya hubo pago manual',
      format('La reserva %s ya tiene $%s %s transferidos al músico. Requiere reconciliación manual.', p_reservation_id, v_ya_transferido, v_currency),
      jsonb_build_object('reservation_id', p_reservation_id, 'screen', 'AdminFinancial')
    FROM profiles p WHERE p.role = 'admin';
    RETURN jsonb_build_object('ok', false, 'error', 'manual_payment_already_transferred', 'amount_already_paid', v_ya_transferido);
  END IF;

  SELECT COALESCE(SUM(amount),0) INTO v_credited
  FROM wallet_transactions WHERE reservation_id = p_reservation_id AND type = 'credit_pending';
  SELECT COALESCE(SUM(amount),0) INTO v_liberado
  FROM wallet_transactions WHERE reservation_id = p_reservation_id AND type = 'credit_available';

  IF v_credited = 0 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'nothing_credited_to_reverse');
  END IF;

  IF p_refund_amount IS NOT NULL AND ROUND(p_refund_amount,2) <> ROUND(v_reservation.total_price,2) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'partial_refund_not_supported',
      'refund_amount', p_refund_amount, 'total_price', v_reservation.total_price);
  END IF;

  v_reversal       := v_credited;
  v_from_pending   := GREATEST(0, v_reversal - v_liberado);
  v_from_available := LEAST(v_reversal, v_liberado);
  v_service_fee    := COALESCE(v_reservation.service_fee_amount, ROUND(v_reservation.total_price - v_credited, 2));

  PERFORM ensure_group_wallet(v_reservation.group_id);
  SELECT * INTO v_wallet FROM group_wallets WHERE group_id = v_reservation.group_id FOR UPDATE;

  CASE v_currency
    WHEN 'MXN' THEN
      UPDATE group_wallets SET
        pending_balance   = GREATEST(0, pending_balance - v_from_pending),
        available_balance = GREATEST(0, available_balance - v_from_available),
        total_earned      = GREATEST(0, total_earned - v_reversal),
        updated_at        = NOW()
      WHERE id = v_wallet.id;
    WHEN 'USD' THEN
      UPDATE group_wallets SET
        pending_balance_usd   = GREATEST(0, pending_balance_usd - v_from_pending),
        available_balance_usd = GREATEST(0, available_balance_usd - v_from_available),
        total_earned_usd      = GREATEST(0, total_earned_usd - v_reversal),
        updated_at            = NOW()
      WHERE id = v_wallet.id;
  END CASE;

  INSERT INTO wallet_transactions (group_wallet_id, group_id, type, amount, reservation_id, description, balance_after, currency_code)
  VALUES (v_wallet.id, v_reservation.group_id, 'debit_refund', v_reversal, p_reservation_id,
    format('Reembolso%s — reserva %s', CASE WHEN p_mp_refund_id IS NOT NULL THEN format(' %s', p_mp_refund_id) ELSE '' END, p_reservation_id),
    NULL, v_currency);

  SELECT id INTO v_admin_id FROM profiles WHERE role = 'admin' ORDER BY created_at LIMIT 1;
  IF v_admin_id IS NOT NULL THEN
    CASE v_currency
      WHEN 'MXN' THEN
        UPDATE wallets SET available_balance = GREATEST(0, available_balance - v_service_fee),
          total_earned = GREATEST(0, COALESCE(total_earned,0) - v_service_fee), updated_at = NOW()
        WHERE user_id = v_admin_id;
      WHEN 'USD' THEN
        UPDATE wallets SET available_balance_usd = GREATEST(0, available_balance_usd - v_service_fee),
          total_earned_usd = GREATEST(0, COALESCE(total_earned_usd,0) - v_service_fee), updated_at = NOW()
        WHERE user_id = v_admin_id;
    END CASE;
    INSERT INTO wallet_transactions (user_id, type, amount, reservation_id, description, currency_code)
    VALUES (v_admin_id, 'debit_refund', v_service_fee, p_reservation_id,
      format('Reverso tarifa servicio — reserva %s', p_reservation_id), v_currency);
  END IF;

  UPDATE reservations SET
    payment_status = 'refunded', payout_status = 'refunded', updated_at = NOW()
  WHERE id = p_reservation_id;

  IF p_claim_id IS NOT NULL THEN
    UPDATE provider_refund_claims SET status = 'done', updated_at = NOW() WHERE id = p_claim_id;
  END IF;

  INSERT INTO financial_audit_logs (entity_type, entity_id, action, actor_id, actor_role, amount, notes)
  VALUES ('reservation', p_reservation_id, 'refund', NULL, 'system', v_reversal,
    format('Refund reversal %s currency=%s', COALESCE(p_mp_refund_id,'manual'), v_currency));

  RETURN jsonb_build_object('ok', true, 'reversed', v_reversal, 'currency', v_currency);
END;
$function$;

COMMIT;

SELECT '539_ROLLBACK ✅ (prc_client_read removida; process_refund_reversal restaurada sin notificaciones cliente/owner)' AS status;
