-- ============================================================
-- sql/535c_p1f_hardening_part3.sql — continuación de 535b
-- process_refund_reversal, settle_cancellation, settle_group_cancellation
-- (firma nueva: +p_claim_id; moneda explícita; guard de pago manual;
--  monto real vía ledger en vez de fórmula; partial_refund_not_supported;
--  candado de grupo consistente con admin_register_group_payment).
-- ============================================================

BEGIN;

DROP FUNCTION IF EXISTS public.process_refund_reversal(uuid, text, numeric);

CREATE FUNCTION public.process_refund_reversal(
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

-- ── settle_cancellation ────────────────────────────────────────
DROP FUNCTION IF EXISTS public.settle_cancellation(uuid, text, text);

CREATE FUNCTION public.settle_cancellation(
  p_reservation_id uuid,
  p_refund_id text DEFAULT NULL::text,
  p_reason text DEFAULT 'client_cancelled'::text,
  p_claim_id uuid DEFAULT NULL::uuid
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE
  v_group_id    UUID;
  v_res         RECORD;
  v_charge      JSONB;
  v_grp_comp    NUMERIC;
  v_plat_ret    NUMERIC;
  v_currency    TEXT;
  v_credited    NUMERIC;
  v_service     NUMERIC;
  v_admin_delta NUMERIC;
  v_wallet      RECORD;
  v_admin_id    UUID;
  v_group_name  TEXT;
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
      format('Cancelación intentada pero ya se transfirieron $%s %s manualmente al músico — requiere reconciliación manual', v_ya_transferido, v_currency));
    INSERT INTO notifications (user_id, type, title, body, data)
    SELECT p.id, 'admin', '🚨 Cancelación bloqueada — ya hubo pago manual',
      format('La reserva %s ya tiene $%s %s transferidos al músico. Requiere reconciliación manual.', p_reservation_id, v_ya_transferido, v_currency),
      jsonb_build_object('reservation_id', p_reservation_id, 'screen', 'AdminFinancial')
    FROM profiles p WHERE p.role = 'admin';
    RETURN jsonb_build_object('ok', false, 'error', 'manual_payment_already_transferred', 'amount_already_paid', v_ya_transferido);
  END IF;

  v_charge   := public.compute_cancellation_charge(p_reservation_id);
  v_grp_comp := (v_charge->>'group_compensation')::NUMERIC;
  v_plat_ret := (v_charge->>'platform_retained')::NUMERIC;

  SELECT COALESCE(SUM(amount),0) INTO v_credited
  FROM wallet_transactions WHERE reservation_id = p_reservation_id AND type = 'credit_pending';
  v_service := COALESCE(v_res.service_fee_amount, ROUND(v_res.total_price - v_credited, 2));

  PERFORM ensure_group_wallet(v_res.group_id);
  SELECT * INTO v_wallet FROM group_wallets WHERE group_id = v_res.group_id FOR UPDATE;

  CASE v_currency
    WHEN 'MXN' THEN
      UPDATE group_wallets SET
        pending_balance   = GREATEST(0, pending_balance - v_credited),
        available_balance = available_balance + v_grp_comp,
        total_earned      = GREATEST(0, total_earned - (v_credited - v_grp_comp)),
        updated_at        = NOW()
      WHERE id = v_wallet.id;
    WHEN 'USD' THEN
      UPDATE group_wallets SET
        pending_balance_usd   = GREATEST(0, pending_balance_usd - v_credited),
        available_balance_usd = available_balance_usd + v_grp_comp,
        total_earned_usd      = GREATEST(0, total_earned_usd - (v_credited - v_grp_comp)),
        updated_at            = NOW()
      WHERE id = v_wallet.id;
  END CASE;

  INSERT INTO wallet_transactions
    (group_wallet_id, group_id, type, amount, reservation_id, description, balance_after, currency_code)
  VALUES (v_wallet.id, v_res.group_id, 'adjustment', v_grp_comp, p_reservation_id,
    format('Compensación por cancelación del cliente — reserva %s', p_reservation_id),
    NULL, v_currency);

  v_admin_delta := v_plat_ret - v_service;
  SELECT id INTO v_admin_id FROM profiles WHERE role = 'admin' ORDER BY created_at LIMIT 1;
  IF v_admin_id IS NOT NULL AND v_admin_delta <> 0 THEN
    CASE v_currency
      WHEN 'MXN' THEN
        UPDATE wallets SET available_balance = GREATEST(0, available_balance + v_admin_delta),
          total_earned = GREATEST(0, COALESCE(total_earned, 0) + v_admin_delta), updated_at = NOW()
        WHERE user_id = v_admin_id;
      WHEN 'USD' THEN
        UPDATE wallets SET available_balance_usd = GREATEST(0, available_balance_usd + v_admin_delta),
          total_earned_usd = GREATEST(0, COALESCE(total_earned_usd, 0) + v_admin_delta), updated_at = NOW()
        WHERE user_id = v_admin_id;
    END CASE;

    INSERT INTO wallet_transactions (user_id, type, amount, reservation_id, description, currency_code)
    VALUES (v_admin_id,
      CASE WHEN v_admin_delta >= 0 THEN 'platform_income' ELSE 'debit_refund' END,
      ABS(v_admin_delta), p_reservation_id,
      format('Ajuste platform income por cancelación (%s) — reserva %s',
             v_charge->>'tier', p_reservation_id), v_currency);
  END IF;

  UPDATE reservations SET
    status            = 'cancelled',
    cancelled_by      = 'client',
    cancellation_type = 'client_initiated',
    cancel_reason     = p_reason,
    cancelled_at      = NOW(),
    payout_status     = 'refunded',
    updated_at        = NOW()
  WHERE id = p_reservation_id;

  IF p_claim_id IS NOT NULL THEN
    UPDATE provider_refund_claims SET status = 'done', updated_at = NOW() WHERE id = p_claim_id;
  END IF;

  INSERT INTO financial_audit_logs
    (entity_type, entity_id, action, actor_id, actor_role, amount, notes)
  VALUES ('reservation', p_reservation_id, 'cancellation_settle', v_res.client_id, 'client',
    v_grp_comp + v_plat_ret,
    format('tier=%s currency=%s refund=%s grp_comp=%s plat_ret=%s refund_id=%s',
      v_charge->>'tier', v_currency, v_charge->>'refund_amount', v_grp_comp, v_plat_ret,
      COALESCE(p_refund_id, 'n/a')));

  SELECT name INTO v_group_name FROM groups WHERE id = v_res.group_id;

  INSERT INTO notifications (user_id, type, title, body, data)
  SELECT g.owner_id, 'booking',
    CASE WHEN v_grp_comp > 0 THEN '📅 Evento cancelado — compensación en tu wallet'
         ELSE '📅 Evento cancelado por el cliente' END,
    CASE WHEN v_grp_comp > 0
      THEN format('El cliente canceló el evento. Recibiste $%s %s de compensación disponible en tu wallet por la fecha que reservaste.',
                  to_char(v_grp_comp, 'FM999,999,990'), v_currency)
      ELSE 'El cliente canceló el evento con suficiente anticipación (sin cargo).'
    END,
    jsonb_build_object('screen', 'Wallet', 'reservation_id', p_reservation_id)
  FROM groups g WHERE g.id = v_res.group_id;

  IF v_admin_id IS NOT NULL THEN
    INSERT INTO notifications (user_id, type, title, body, data)
    VALUES (v_admin_id, 'admin',
      '💸 Cancelación con cargo',
      format('%s canceló (%s). Cargo total $%s %s: grupo $%s, Daricefy $%s. Reembolso al cliente $%s.',
        COALESCE(v_group_name, 'Reserva'), v_charge->>'tier',
        to_char(v_grp_comp + v_plat_ret, 'FM999,999,990'), v_currency,
        to_char(v_grp_comp, 'FM999,999,990'),
        to_char(v_plat_ret, 'FM999,999,990'),
        v_charge->>'refund_amount'),
      jsonb_build_object('reservation_id', p_reservation_id, 'screen', 'AdminFinancial'));
  END IF;

  RETURN jsonb_build_object('ok', true,
    'tier', v_charge->>'tier',
    'currency', v_currency,
    'refund_amount', (v_charge->>'refund_amount')::NUMERIC,
    'group_compensation', v_grp_comp,
    'platform_retained', v_plat_ret);
END;
$function$;

-- ── settle_group_cancellation ─────────────────────────────────
DROP FUNCTION IF EXISTS public.settle_group_cancellation(uuid, text, text);

CREATE FUNCTION public.settle_group_cancellation(
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

SELECT '535c_p1f_hardening_part3 (refund_reversal+settle_cancellation+settle_group_cancellation) ✅' AS status;
