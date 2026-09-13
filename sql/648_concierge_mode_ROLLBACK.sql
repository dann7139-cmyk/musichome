-- ============================================================================
-- ROLLBACK sql/648_concierge_mode.sql
-- Revierte modo conserjería: quita las 3 funciones nuevas, deja
-- _apply_confirmed_credit exactamente como estaba antes (sin el bloque de
-- aviso de conserjería), y quita la columna groups.concierge_mode.
--
-- ⚠️ NO correr salvo emergencia deliberada. Si algún grupo ya tiene
-- concierge_mode=true, este rollback borra ese dato al quitar la columna.
-- ============================================================================

DROP FUNCTION IF EXISTS public.admin_get_concierge_quotes(integer);
DROP FUNCTION IF EXISTS public.admin_respond_quote(uuid, numeric, numeric, text);
DROP FUNCTION IF EXISTS public.notify_quote_request(uuid);

-- _apply_confirmed_credit — restaurado a como estaba antes de sql/648
-- (idéntico, solo sin el bloque de aviso "modo conserjería" al final).
CREATE OR REPLACE FUNCTION public._apply_confirmed_credit(p_receipt_id uuid, p_reservation_id uuid, p_provider text, p_payment_id text, p_method text, p_fee_minor bigint, p_fee_source text, p_attempt_id uuid, p_manual boolean DEFAULT false, p_actor uuid DEFAULT NULL::uuid, p_evidence_id uuid DEFAULT NULL::uuid, p_note text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_group_id    UUID;
  v_res         RECORD;
  v_receipt     RECORD;
  v_att         RECORD;
  v_ev          RECORD;
  v_currency    TEXT;
  v_earnings    NUMERIC;
  v_service_fee NUMERIC;
  v_msi_fee     NUMERIC;
  v_admin_bruto NUMERIC;
  v_fee_pesos   NUMERIC;
  v_admin_id    UUID;
  v_wallet_id   UUID;
  v_revived     BOOLEAN;
  v_fuente      TEXT;
BEGIN
  SELECT group_id INTO v_group_id FROM reservations WHERE id = p_reservation_id;
  IF v_group_id IS NULL THEN
    RAISE EXCEPTION '_credit_assert: reserva % inexistente', p_reservation_id;
  END IF;
  PERFORM pg_advisory_xact_lock(hashtext(v_group_id::text));

  SELECT * INTO v_res FROM reservations WHERE id = p_reservation_id FOR UPDATE;

  IF v_res.status IN ('cancelled','rejected') THEN
    RAISE EXCEPTION '_credit_assert: reserva % terminal (%)', p_reservation_id, v_res.status;
  END IF;
  IF v_res.payment_status IN ('paid','fully_paid') THEN
    RAISE EXCEPTION '_credit_assert: reserva % ya pagada', p_reservation_id;
  END IF;

  SELECT * INTO v_receipt FROM payment_receipts WHERE id = p_receipt_id FOR UPDATE;
  IF NOT FOUND OR v_receipt.money_state <> 'recorded' OR v_receipt.resolution IS NOT NULL THEN
    RAISE EXCEPTION '_credit_assert: receipt % no acreditable (state=%, resolution=%)',
      p_receipt_id, v_receipt.money_state, v_receipt.resolution;
  END IF;
  IF p_manual AND p_evidence_id IS NULL THEN
    RAISE EXCEPTION '_credit_assert: crédito manual sin evidencia';
  END IF;

  v_currency := UPPER(COALESCE(v_res.currency_code, 'MXN'));
  v_revived  := (v_res.status = 'expired');

  IF p_evidence_id IS NOT NULL THEN
    SELECT * INTO v_ev FROM admin_payment_evidence WHERE id = p_evidence_id;
    IF NOT FOUND OR NOT v_ev.captured OR v_ev.group_base_minor IS NULL THEN
      RAISE EXCEPTION '_credit_assert: evidencia % sin composición capturada', p_evidence_id;
    END IF;
    v_earnings    := v_ev.group_base_minor   / 100.0;
    v_service_fee := v_ev.platform_fee_minor / 100.0;
    v_msi_fee     := v_ev.msi_fee_minor      / 100.0;
    v_fuente      := 'evidence:' || p_evidence_id;
  ELSE
    IF p_attempt_id IS NOT NULL THEN
      SELECT * INTO v_att FROM payment_attempts WHERE id = p_attempt_id;
    END IF;
    IF p_attempt_id IS NOT NULL AND FOUND AND v_att.group_base_minor IS NOT NULL THEN
      v_earnings    := v_att.group_base_minor   / 100.0;
      v_service_fee := v_att.platform_fee_minor / 100.0;
      v_msi_fee     := v_att.msi_fee_minor      / 100.0;
      v_fuente      := 'attempt_snapshot';
    ELSE
      v_earnings    := COALESCE(v_res.base_price, ROUND(v_res.total_price / 1.20, 2));
      v_service_fee := COALESCE(v_res.service_fee_amount,
                         v_res.total_price - ROUND(v_res.total_price / 1.20, 2));
      v_msi_fee     := COALESCE(v_res.msi_fee_amount, 0);
      v_fuente      := 'reservation_compat';
    END IF;
  END IF;

  v_admin_bruto := v_service_fee + v_msi_fee;
  v_fee_pesos   := CASE WHEN p_fee_minor IS NULL THEN NULL ELSE p_fee_minor / 100.0 END;

  PERFORM ensure_group_wallet(v_group_id);
  SELECT id INTO v_wallet_id FROM group_wallets WHERE group_id = v_group_id;

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
    ELSE
      RAISE EXCEPTION '_credit_assert: moneda % sin wallet autorizada — crédito prohibido', v_currency;
  END CASE;

  UPDATE reservations SET
    status              = CASE WHEN status IN ('pending','pending_payment',
                                               'pending_group_confirmation',
                                               'accepted','expired')
                               THEN 'confirmed' ELSE status END,
    payment_status      = 'paid',
    payout_status       = 'held',
    held_at             = NOW(),
    mp_payment_id       = p_payment_id,
    payment_provider    = p_provider,
    payment_method_type = COALESCE(p_method, payment_method_type),
    stripe_fee_amount   = COALESCE(v_fee_pesos, stripe_fee_amount),
    service_fee_amount  = v_service_fee,
    group_earnings      = v_earnings,
    updated_at          = NOW()
  WHERE id = p_reservation_id;

  INSERT INTO wallet_transactions (
    group_wallet_id, group_id, type, amount,
    reservation_id, description, balance_after, currency_code
  )
  SELECT gw.id, gw.group_id, 'credit_pending', v_earnings,
    p_reservation_id,
    format('Pago confirmado — reserva %s', p_reservation_id),
    CASE v_currency WHEN 'USD' THEN gw.pending_balance_usd ELSE gw.pending_balance END,
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
          available_balance = available_balance + v_admin_bruto,
          total_earned      = COALESCE(total_earned, 0) + v_admin_bruto,
          updated_at        = NOW()
        WHERE user_id = v_admin_id;
      WHEN 'USD' THEN
        UPDATE wallets SET
          available_balance_usd = available_balance_usd + v_admin_bruto,
          total_earned_usd      = COALESCE(total_earned_usd, 0) + v_admin_bruto,
          updated_at            = NOW()
        WHERE user_id = v_admin_id;
      ELSE
        RAISE EXCEPTION '_credit_assert: moneda % sin wallet admin autorizada', v_currency;
    END CASE;

    INSERT INTO wallet_transactions (user_id, type, amount, reservation_id, description, currency_code)
    VALUES (v_admin_id, 'platform_income', v_admin_bruto, p_reservation_id,
      format('Comisión $%s + MSI $%s = $%s bruto — fee procesador: %s — reserva %s',
        v_service_fee::TEXT, v_msi_fee::TEXT, v_admin_bruto::TEXT,
        COALESCE('$' || v_fee_pesos::TEXT, 'No capturado'),
        p_reservation_id),
      v_currency);
  END IF;

  INSERT INTO financial_audit_logs
    (entity_type, entity_id, action, actor_id, actor_role, amount, notes)
  VALUES ('reservation', p_reservation_id, 'hold',
    p_actor, CASE WHEN p_manual THEN 'admin' ELSE 'system' END, v_earnings,
    format('%s currency=%s group=%s svc=%s msi=%s fee=%s fuente=%s pago=%s/%s%s%s',
      CASE WHEN p_manual THEN 'manual_credit' ELSE 'v2' END,
      v_currency, v_earnings, v_service_fee, v_msi_fee,
      COALESCE(v_fee_pesos::TEXT, 'not_captured'), v_fuente,
      p_provider, p_payment_id,
      CASE WHEN v_revived THEN ' [REVIVIDA]' ELSE '' END,
      CASE WHEN p_note IS NOT NULL THEN ' nota=' || p_note ELSE '' END));

  IF v_fuente <> 'reservation_compat'
     AND v_res.base_price IS NOT NULL
     AND ROUND(v_res.base_price * 100)::BIGINT <> ROUND(v_earnings * 100)::BIGINT THEN
    INSERT INTO financial_audit_logs
      (entity_type, entity_id, action, actor_id, actor_role, amount, notes)
    VALUES ('reservation', p_reservation_id, 'snapshot_reservation_drift',
      p_actor, CASE WHEN p_manual THEN 'admin' ELSE 'system' END, v_earnings,
      format('reserva_viva base=%s vs snapshot base=%s — el snapshot MANDA',
        v_res.base_price, v_earnings));
  END IF;

  INSERT INTO notifications (user_id, type, title, body, data)
  SELECT g.owner_id, 'payment',
    '💰 Pago confirmado — retenido hasta el evento',
    format('El cliente pagó tu evento del %s. $%s %s quedaron reservados y se liberan cuando el grupo llegue y al terminar el evento.',
      v_res.event_date::TEXT, to_char(v_earnings, 'FM999,999,990'), v_currency),
    jsonb_build_object('reservation_id', p_reservation_id, 'amount', v_earnings, 'screen', 'Wallet')
  FROM groups g
  WHERE g.id = v_group_id AND g.owner_id IS NOT NULL;

  UPDATE payment_receipts SET
    result               = CASE WHEN p_manual THEN result ELSE 'confirmed' END,
    money_state          = 'credited',
    settlement_status    = 'credited',
    reservation_id       = p_reservation_id,
    processor_fee_minor  = p_fee_minor,
    processor_fee_status = CASE WHEN p_fee_minor IS NULL THEN 'not_captured' ELSE 'captured' END,
    fee_source           = CASE WHEN p_fee_minor IS NULL THEN NULL ELSE p_fee_source END,
    resolution           = CASE WHEN p_manual THEN 'credited_manual' ELSE resolution END,
    resolved_by          = CASE WHEN p_manual THEN p_actor ELSE resolved_by END,
    resolved_at          = CASE WHEN p_manual THEN NOW() ELSE resolved_at END,
    resolution_note      = CASE WHEN p_manual THEN p_note ELSE resolution_note END,
    updated_at           = NOW()
  WHERE id = p_receipt_id;

  IF p_attempt_id IS NOT NULL THEN
    UPDATE payment_attempts SET status = 'consumed', updated_at = NOW()
    WHERE id = p_attempt_id;
  END IF;

  RETURN jsonb_build_object(
    'currency', v_currency, 'group_earnings', v_earnings,
    'admin_bruto', v_admin_bruto, 'processor_fee', v_fee_pesos,
    'fuente', v_fuente, 'revived', v_revived
  );
END $function$;

ALTER TABLE public.groups DROP COLUMN IF EXISTS concierge_mode;
