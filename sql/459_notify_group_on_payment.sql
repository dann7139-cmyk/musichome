-- ════════════════════════════════════════════════════════════════════
-- sql/459_notify_group_on_payment.sql
--
-- FIX: el grupo no recibía aviso cuando el cliente paga.
-- confirm_full_payment_and_credit_wallet (la RPC que usan Conekta Y Stripe)
-- acreditaba la wallet pero NO notificaba al dueño del grupo. La notificación
-- "Pago recibido" solo existía en mp_credit_pending_earnings (ruta vieja MP).
--
-- Esta migración = COPIA EXACTA de la función de sql/402 + UNA inserción de
-- notificación al owner del grupo, justo antes del RETURN.
--   · NO cambia ningún cálculo de dinero (earnings, comisión, stripe_fee).
--   · Se dispara UNA sola vez por pago (guard de idempotencia intacto:
--     si payment_status ya es paid/fully_paid, retorna antes de llegar aquí).
--   · Aplica a Tarjeta/SPEI/Efectivo (Conekta) y a Meses (Stripe).
-- ════════════════════════════════════════════════════════════════════

BEGIN;

CREATE OR REPLACE FUNCTION public.confirm_full_payment_and_credit_wallet(
  p_reservation_id UUID,
  p_mp_payment_id  TEXT,
  p_amount_paid    NUMERIC DEFAULT NULL,
  p_stripe_fee     NUMERIC DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
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

  v_currency    := COALESCE(v_reservation.currency_code, 'MXN');

  -- Modelo markup 20%: grupo recibe base_price (su neto).
  -- Fallback cuando base_price no está guardado: total_price / 1.20.
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

  IF v_currency = 'USD' THEN
    UPDATE group_wallets SET
      pending_balance_usd = pending_balance_usd + v_earnings,
      total_earned_usd    = total_earned_usd    + v_earnings,
      updated_at          = NOW()
    WHERE id = v_wallet_id;
  ELSE
    UPDATE group_wallets SET
      pending_balance = pending_balance + v_earnings,
      total_earned    = total_earned    + v_earnings,
      updated_at      = NOW()
    WHERE id = v_wallet_id;
  END IF;

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

    IF v_currency = 'USD' THEN
      UPDATE wallets SET
        available_balance_usd = available_balance_usd + v_admin_neto,
        total_earned_usd      = COALESCE(total_earned_usd, 0) + v_admin_neto,
        updated_at            = NOW()
      WHERE user_id = v_admin_id;
    ELSE
      UPDATE wallets SET
        available_balance = available_balance + v_admin_neto,
        total_earned      = COALESCE(total_earned, 0) + v_admin_neto,
        updated_at        = NOW()
      WHERE user_id = v_admin_id;
    END IF;

    INSERT INTO wallet_transactions (user_id, type, amount, reservation_id, description, currency_code)
    VALUES (v_admin_id, 'platform_income', v_admin_neto, p_reservation_id,
      format('Comisión $%s + MSI $%s − Stripe $%s = $%s neto — reserva %s',
        v_service_fee::TEXT, v_msi_fee::TEXT,
        v_stripe_fee::TEXT, v_admin_neto::TEXT,
        p_reservation_id),
      v_currency);
  END IF;

  INSERT INTO financial_audit_logs
    (entity_type, entity_id, action, actor_id, actor_role, amount, notes)
  VALUES ('reservation', p_reservation_id, 'hold', NULL, 'system', v_earnings,
    format('currency=%s group=%s svc=%s msi=%s stripe=%s admin_neto=%s',
      v_currency, v_earnings, v_service_fee, v_msi_fee, v_stripe_fee, v_admin_neto));

  -- ★ NUEVO: avisar al grupo que el cliente pagó (dinero retenido hasta el evento).
  --   Aditivo, sin tocar el cálculo. Fires una sola vez (guard already_paid arriba).
  INSERT INTO notifications (user_id, type, title, body, data)
  SELECT g.owner_id, 'payment',
    '💰 Pago confirmado — retenido hasta el evento',
    format('El cliente pagó tu evento del %s. $%s MXN quedaron reservados y se liberan cuando el grupo llegue y al terminar el evento.',
      v_reservation.event_date::TEXT,
      to_char(v_earnings, 'FM999,999,990')),
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
$$;

GRANT EXECUTE ON FUNCTION public.confirm_full_payment_and_credit_wallet(UUID, TEXT, NUMERIC, NUMERIC)
  TO authenticated, service_role;

COMMIT;

-- ── Verificación (correr aparte) ────────────────────────────────────
-- La función ahora contiene la notificación 'payment' al grupo:
SELECT pg_get_functiondef(oid) LIKE '%Pago confirmado — retenido%' AS tiene_notif_grupo
FROM pg_proc
WHERE proname = 'confirm_full_payment_and_credit_wallet'
  AND pronamespace = 'public'::regnamespace;
-- Esperado: true
