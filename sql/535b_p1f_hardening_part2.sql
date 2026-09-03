-- ============================================================
-- sql/535b_p1f_hardening_part2.sql — continuación de 535
-- confirm_full_payment_and_credit_wallet, resolve_dispute,
-- process_refund_reversal, settle_cancellation, settle_group_cancellation,
-- admin_get_pending_group_payments, group_get_payable_reservations,
-- group_request_payment, request_withdrawal, RLS withdrawals.
-- ============================================================

BEGIN;

-- ── confirm_full_payment_and_credit_wallet ────────────────────
-- Guard de moneda vía RAISE EXCEPTION (no jsonb ok:false): los webhooks
-- que la llaman (stripe-webhook, mercadopago-webhook) solo verifican
-- error de red/RPC y `skipped`, nunca `ok:false` — un retorno "suave"
-- quedaría silenciosamente ignorado y la reserva se marcaría pagada
-- sin acreditar el wallet.
CREATE OR REPLACE FUNCTION public.confirm_full_payment_and_credit_wallet(p_reservation_id uuid, p_mp_payment_id text, p_amount_paid numeric DEFAULT NULL::numeric, p_stripe_fee numeric DEFAULT NULL::numeric)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE
  v_reservation  RECORD;
  v_wallet_id    UUID;
  v_earnings     NUMERIC;
  v_service_fee  NUMERIC;
  v_msi_fee      NUMERIC;
  v_admin_bruto  NUMERIC;
  v_stripe_fee   NUMERIC;
  v_admin_neto   NUMERIC;
  v_admin_id     UUID;
  v_currency     TEXT;
BEGIN
  SELECT * INTO v_reservation
  FROM reservations WHERE id = p_reservation_id FOR UPDATE;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'reservation_not_found');
  END IF;

  IF v_reservation.payment_status IN ('paid','fully_paid') THEN
    RETURN jsonb_build_object('ok', true, 'skipped', true, 'reason', 'already_paid');
  END IF;

  IF v_reservation.status IN ('cancelled', 'rejected', 'expired') THEN
    UPDATE reservations SET
      payment_status = 'paid',
      payout_status  = 'blocked',
      mp_payment_id  = p_mp_payment_id,
      stripe_fee_amount = COALESCE(p_stripe_fee, stripe_fee_amount),
      updated_at     = NOW()
    WHERE id = p_reservation_id;

    INSERT INTO financial_audit_logs
      (entity_type, entity_id, action, actor_id, actor_role, amount, notes)
    VALUES ('reservation', p_reservation_id, 'late_payment_blocked', NULL, 'system',
      COALESCE(v_reservation.total_price, 0),
      format('Pago recibido con reserva en estado %s — NO acreditado; requiere reembolso. pago=%s',
        v_reservation.status, p_mp_payment_id));

    INSERT INTO notifications (user_id, type, title, body, data)
    SELECT p.id, 'reservation',
      '🚨 Pago recibido de reserva cancelada',
      format('La reserva %s estaba %s cuando llegó el pago. El dinero quedó BLOQUEADO (no se acreditó al grupo). Procesa el reembolso al cliente.',
        COALESCE(v_reservation.folio, p_reservation_id::TEXT), v_reservation.status),
      jsonb_build_object('reservation_id', p_reservation_id, 'screen', 'AdminFinancial')
    FROM profiles p WHERE p.role = 'admin';

    RETURN jsonb_build_object('ok', false, 'blocked', true,
      'reason', 'reservation_' || v_reservation.status);
  END IF;

  IF v_reservation.currency_code IS NULL OR v_reservation.currency_code NOT IN ('MXN','USD') THEN
    RAISE EXCEPTION 'confirm_full_payment_and_credit_wallet: moneda % sin wallet autorizada — reserva %',
      v_reservation.currency_code, p_reservation_id;
  END IF;
  v_currency := v_reservation.currency_code;

  v_earnings    := COALESCE(v_reservation.base_price,
                     ROUND(v_reservation.total_price / 1.20, 2));
  v_service_fee := COALESCE(v_reservation.service_fee_amount,
                     v_reservation.total_price - ROUND(v_reservation.total_price / 1.20, 2));
  v_msi_fee     := COALESCE(v_reservation.msi_fee_amount, 0);
  v_admin_bruto := v_service_fee + v_msi_fee;
  v_stripe_fee  := COALESCE(
                     p_stripe_fee,
                     COALESCE(v_reservation.stripe_fee_amount,
                       ROUND((v_reservation.total_price + v_msi_fee) * 0.036 + 3, 2))
                   );
  v_admin_neto  := GREATEST(0, v_admin_bruto - v_stripe_fee);

  PERFORM ensure_group_wallet(v_reservation.group_id);
  SELECT id INTO v_wallet_id FROM group_wallets WHERE group_id = v_reservation.group_id;

  CASE v_currency
    WHEN 'MXN' THEN
      UPDATE group_wallets SET
        pending_balance = pending_balance + v_earnings,
        total_earned    = total_earned    + v_earnings,
        updated_at      = NOW()
      WHERE id = v_wallet_id;
    WHEN 'USD' THEN
      UPDATE group_wallets SET
        pending_balance_usd = pending_balance_usd + v_earnings,
        total_earned_usd    = total_earned_usd    + v_earnings,
        updated_at          = NOW()
      WHERE id = v_wallet_id;
  END CASE;

  UPDATE reservations SET
    payment_status     = 'paid',
    payout_status      = 'held',
    held_at            = NOW(),
    mp_payment_id      = p_mp_payment_id,
    stripe_fee_amount  = COALESCE(p_stripe_fee, stripe_fee_amount),
    service_fee_amount = v_service_fee,
    group_earnings     = v_earnings,
    updated_at         = NOW()
  WHERE id = p_reservation_id;

  INSERT INTO wallet_transactions (
    group_wallet_id, group_id, type, amount,
    reservation_id, description, balance_after, currency_code
  )
  SELECT gw.id, gw.group_id, 'credit_pending', v_earnings,
    p_reservation_id,
    format('Pago confirmado — reserva %s', p_reservation_id),
    CASE WHEN v_currency = 'USD' THEN gw.pending_balance_usd ELSE gw.pending_balance END,
    v_currency
  FROM group_wallets gw WHERE gw.id = v_wallet_id;

  SELECT id INTO v_admin_id FROM profiles WHERE role = 'admin' ORDER BY created_at LIMIT 1;
  IF v_admin_id IS NOT NULL THEN
    INSERT INTO wallets (user_id, available_balance, pending_balance, total_earned)
    VALUES (v_admin_id, 0, 0, 0)
    ON CONFLICT (user_id) DO NOTHING;

    CASE v_currency
      WHEN 'MXN' THEN
        UPDATE wallets SET
          available_balance = available_balance + v_admin_neto,
          total_earned      = COALESCE(total_earned, 0) + v_admin_neto,
          updated_at        = NOW()
        WHERE user_id = v_admin_id;
      WHEN 'USD' THEN
        UPDATE wallets SET
          available_balance_usd = available_balance_usd + v_admin_neto,
          total_earned_usd      = COALESCE(total_earned_usd, 0) + v_admin_neto,
          updated_at            = NOW()
        WHERE user_id = v_admin_id;
    END CASE;

    INSERT INTO wallet_transactions (user_id, type, amount, reservation_id, description, currency_code)
    VALUES (v_admin_id, 'platform_income', v_admin_bruto, p_reservation_id,
      format('Comisión $%s + MSI $%s = $%s bruto — fee procesador: %s — reserva %s',
        v_service_fee::TEXT, v_msi_fee::TEXT, v_admin_bruto::TEXT,
        COALESCE('$' || v_stripe_fee::TEXT, 'No capturado'),
        p_reservation_id),
      v_currency);
  END IF;

  INSERT INTO financial_audit_logs
    (entity_type, entity_id, action, actor_id, actor_role, amount, notes)
  VALUES ('reservation', p_reservation_id, 'hold', NULL, 'system', v_earnings,
    format('currency=%s group=%s svc=%s msi=%s stripe=%s admin_neto=%s',
      v_currency, v_earnings, v_service_fee, v_msi_fee, v_stripe_fee, v_admin_neto));

  INSERT INTO notifications (user_id, type, title, body, data)
  SELECT g.owner_id, 'payment',
    '💰 Pago confirmado — retenido hasta el evento',
    format('El cliente pagó tu evento del %s. $%s %s quedaron reservados y se liberan cuando el grupo llegue y al terminar el evento.',
      v_reservation.event_date::TEXT, to_char(v_earnings, 'FM999,999,990'), v_currency),
    jsonb_build_object('reservation_id', p_reservation_id, 'amount', v_earnings, 'screen', 'Wallet')
  FROM groups g
  WHERE g.id = v_reservation.group_id AND g.owner_id IS NOT NULL;

  RETURN jsonb_build_object(
    'ok',             true,
    'currency',       v_currency,
    'group_earnings', v_earnings,
    'service_fee',    v_service_fee,
    'msi_fee',        v_msi_fee,
    'admin_bruto',    v_admin_bruto,
    'stripe_fee',     v_stripe_fee,
    'admin_neto',     v_admin_neto
  );
END;
$function$;

-- ── resolve_dispute ────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.resolve_dispute(p_dispute_id uuid, p_resolution text, p_resolution_note text DEFAULT NULL::text)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE
  v_caller_id     UUID := auth.uid();
  v_dispute       RECORD;
  v_reservation   RECORD;
  v_wallet        RECORD;
  v_owner_id      UUID;
  v_group_name    TEXT;
  v_currency      TEXT;
  v_pending_total NUMERIC;
  v_liberado      NUMERIC;
  v_pendiente     NUMERIC;
  v_avail_after   NUMERIC;
  v_admin_id      UUID;
  v_ya_transferido NUMERIC;
BEGIN
  IF v_caller_id IS NULL THEN RAISE EXCEPTION 'unauthorized: sesión requerida'; END IF;

  IF NOT EXISTS (SELECT 1 FROM profiles WHERE id = v_caller_id AND role = 'admin') THEN
    RAISE EXCEPTION 'unauthorized: solo admins pueden resolver disputas';
  END IF;

  SELECT * INTO v_dispute FROM disputes WHERE id = p_dispute_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Disputa no encontrada'; END IF;

  IF v_dispute.status NOT IN ('open','under_review') THEN
    RAISE EXCEPTION 'Esta disputa ya fue resuelta';
  END IF;

  SELECT * INTO v_reservation FROM reservations WHERE id = v_dispute.reservation_id;

  IF p_resolution = 'resolved_client' THEN
    IF v_reservation.currency_code IS NULL OR v_reservation.currency_code NOT IN ('MXN','USD') THEN
      RAISE EXCEPTION 'resolve_dispute: moneda % sin wallet autorizada — reserva %',
        v_reservation.currency_code, v_dispute.reservation_id;
    END IF;

    SELECT COALESCE(SUM(amount),0) INTO v_ya_transferido
    FROM group_reservation_payments WHERE reservation_id = v_dispute.reservation_id;
    IF v_ya_transferido > 0
       AND v_reservation.payout_status <> 'refunded'
       AND NOT EXISTS (SELECT 1 FROM wallet_transactions WHERE reservation_id = v_dispute.reservation_id AND type = 'refund_dispute')
    THEN
      INSERT INTO financial_audit_logs (entity_type, entity_id, action, actor_id, actor_role, amount, notes)
      VALUES ('reservation', v_dispute.reservation_id, 'dispute_blocked_manual_payment_exists', v_caller_id, 'admin', v_ya_transferido,
        format('Disputa %s no pudo revertirse automáticamente — ya se transfirieron $%s al músico', p_dispute_id, v_ya_transferido));
      INSERT INTO notifications (user_id, type, title, body, data)
      SELECT p.id, 'admin', '🚨 Disputa bloqueada — ya hubo pago manual',
        format('La reserva %s ya tiene $%s transferidos al músico. Requiere reconciliación manual antes de resolver a favor del cliente.',
          v_dispute.reservation_id, v_ya_transferido),
        jsonb_build_object('reservation_id', v_dispute.reservation_id, 'screen', 'AdminFinancial')
      FROM profiles p WHERE p.role = 'admin';
      RAISE EXCEPTION 'resolve_dispute: reserva % ya tiene $% transferidos manualmente — requiere reconciliación manual antes de resolver_client',
        v_dispute.reservation_id, v_ya_transferido;
    END IF;
  END IF;

  UPDATE disputes
  SET
    status          = p_resolution,
    resolution_note = p_resolution_note,
    resolved_by     = v_caller_id,
    resolved_at     = NOW(),
    updated_at      = NOW()
  WHERE id = p_dispute_id;

  IF p_resolution = 'resolved_group' THEN
    PERFORM release_event_payment(v_dispute.reservation_id);
  END IF;

  IF p_resolution = 'resolved_client' THEN

    IF v_reservation.payout_status = 'refunded'
       OR EXISTS (
         SELECT 1 FROM wallet_transactions
         WHERE reservation_id = v_dispute.reservation_id
           AND type = 'refund_dispute'
       )
    THEN
      RAISE NOTICE '[resolve_dispute] Reversa ya aplicada para reserva % — skip',
        v_dispute.reservation_id;
    ELSE
      v_currency := v_reservation.currency_code;

      SELECT * INTO v_wallet FROM group_wallets
      WHERE group_id = v_reservation.group_id
      FOR UPDATE;

      SELECT COALESCE(SUM(amount), 0) INTO v_pending_total
      FROM wallet_transactions
      WHERE reservation_id = v_dispute.reservation_id AND type = 'credit_pending';

      SELECT COALESCE(SUM(amount), 0) INTO v_liberado
      FROM wallet_transactions
      WHERE reservation_id = v_dispute.reservation_id AND type = 'credit_available';

      v_pendiente := GREATEST(v_pending_total - v_liberado, 0);

      IF v_pendiente > 0 THEN
        CASE v_currency
          WHEN 'MXN' THEN
            UPDATE group_wallets
            SET pending_balance = GREATEST(0, pending_balance - v_pendiente),
                updated_at = NOW()
            WHERE id = v_wallet.id;
          WHEN 'USD' THEN
            UPDATE group_wallets
            SET pending_balance_usd = GREATEST(0, pending_balance_usd - v_pendiente),
                updated_at = NOW()
            WHERE id = v_wallet.id;
        END CASE;

        INSERT INTO wallet_transactions (
          group_wallet_id, group_id, type, amount, reservation_id,
          dispute_id, description, balance_after, currency_code
        )
        SELECT gw.id, gw.group_id, 'refund_dispute', v_pendiente,
               v_dispute.reservation_id, p_dispute_id,
               'Reversa por disputa — parte pendiente',
               CASE WHEN v_currency = 'USD' THEN gw.pending_balance_usd
                    ELSE gw.pending_balance END,
               v_currency
        FROM group_wallets gw WHERE gw.id = v_wallet.id;
      END IF;

      IF v_liberado > 0 THEN
        CASE v_currency
          WHEN 'MXN' THEN
            UPDATE group_wallets
            SET available_balance = available_balance - v_liberado,
                updated_at = NOW()
            WHERE id = v_wallet.id;
          WHEN 'USD' THEN
            UPDATE group_wallets
            SET available_balance_usd = available_balance_usd - v_liberado,
                updated_at = NOW()
            WHERE id = v_wallet.id;
        END CASE;

        INSERT INTO wallet_transactions (
          group_wallet_id, group_id, type, amount, reservation_id,
          dispute_id, description, balance_after, currency_code
        )
        SELECT gw.id, gw.group_id, 'refund_dispute', v_liberado,
               v_dispute.reservation_id, p_dispute_id,
               'Reversa por disputa — monto ya liberado (50% llegada / release)',
               CASE WHEN v_currency = 'USD' THEN gw.available_balance_usd
                    ELSE gw.available_balance END,
               v_currency
        FROM group_wallets gw WHERE gw.id = v_wallet.id;
      END IF;

      UPDATE reservations
      SET payout_status = 'refunded', updated_at = NOW()
      WHERE id = v_dispute.reservation_id;

      SELECT CASE WHEN v_currency = 'USD' THEN available_balance_usd
                  ELSE available_balance END
      INTO v_avail_after
      FROM group_wallets WHERE id = v_wallet.id;

      SELECT name INTO v_group_name FROM groups WHERE id = v_reservation.group_id;

      IF v_avail_after < 0 THEN
        SELECT id INTO v_admin_id FROM profiles WHERE role = 'admin' LIMIT 1;
        IF v_admin_id IS NOT NULL THEN
          INSERT INTO notifications (user_id, type, title, body, data)
          VALUES (
            v_admin_id, 'admin',
            '⚠️ Grupo con saldo deudor por disputa',
            COALESCE(v_group_name, 'Un grupo') || ' quedó con saldo ' ||
              to_char(v_avail_after, 'FM-999,999,990.00') || ' ' || v_currency ||
              ' tras la reversa. La deuda se netea contra sus próximos eventos.',
            jsonb_build_object(
              'reservation_id', v_dispute.reservation_id,
              'dispute_id',     p_dispute_id,
              'group_id',       v_reservation.group_id,
              'screen',         'AdminFinancial'
            )
          );
        END IF;

        INSERT INTO financial_audit_logs
          (entity_type, entity_id, action, actor_id, actor_role, amount, notes)
        VALUES ('group_wallet', v_wallet.id, 'dispute_debt', v_caller_id, 'admin',
          v_avail_after,
          format('Saldo deudor tras reversa completa de disputa %s', p_dispute_id));
      END IF;

      INSERT INTO financial_audit_logs
        (entity_type, entity_id, action, actor_id, actor_role, amount, notes)
      VALUES ('reservation', v_dispute.reservation_id, 'dispute_reversal',
        v_caller_id, 'admin', v_pendiente + v_liberado,
        format('resolved_client: pendiente=%s liberado=%s currency=%s dispute=%s',
               v_pendiente, v_liberado, v_currency, p_dispute_id));
    END IF;
  END IF;

  INSERT INTO notifications (user_id, type, title, body, data)
  VALUES (
    v_reservation.client_id, 'dispute',
    CASE p_resolution WHEN 'resolved_client' THEN '✅ Disputa resuelta a tu favor' ELSE '❌ Disputa resuelta' END,
    p_resolution_note,
    jsonb_build_object('screen','Reservations','reservation_id',v_dispute.reservation_id)
  );

  SELECT g.owner_id INTO v_owner_id FROM groups g WHERE g.id = v_reservation.group_id;
  IF v_owner_id IS NOT NULL THEN
    INSERT INTO notifications (user_id, type, title, body, data)
    VALUES (
      v_owner_id, 'dispute',
      CASE p_resolution
        WHEN 'resolved_group' THEN '✅ Disputa resuelta a tu favor'
        ELSE '⚠️ Disputa resuelta a favor del cliente'
      END,
      COALESCE(p_resolution_note,
        CASE p_resolution
          WHEN 'resolved_group' THEN 'El pago del evento fue liberado.'
          ELSE 'El saldo del evento fue revertido.'
        END),
      jsonb_build_object('screen','GroupReservations','reservation_id',v_dispute.reservation_id)
    );
  END IF;

  RETURN jsonb_build_object('ok', true, 'resolution', p_resolution);
END;
$function$;

COMMIT;

SELECT '535b_p1f_hardening_part2 (confirm_full_payment+resolve_dispute) ✅' AS status;
