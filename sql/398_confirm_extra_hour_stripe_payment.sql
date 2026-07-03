-- ════════════════════════════════════════════════════════════════════
-- sql/398 — RPC confirm_extra_hour_stripe_payment
--
-- Llamada por stripe-webhook cuando payment_intent.succeeded contiene
-- metadata.extra_hour_id. Equivalente a confirm_full_payment_and_credit_wallet
-- pero para horas extra.
--
-- Flujo:
--   1. Lock extra_hour FOR UPDATE (idempotencia: skip si ya 'paid').
--   2. Lock group_wallet FOR UPDATE.
--   3. Acreditar group_extra_earnings a pending_balance.
--   4. Marcar extra_hours.status = 'paid', payout_status = 'held'.
--   5. Incrementar reservations.extra_hours_added.
--   6. INSERT wallet_transaction + financial_audit_log.
--   7. Notificar grupo (extra_hour_approved_by_client).
--   8. Notificar cliente (extra_hour_payment_confirmed).
--
-- Importante: usa group_extra_earnings ya calculado al INSERT de extra_hours
--   (= total_extra_cost * 0.90). No recalcula.
-- ════════════════════════════════════════════════════════════════════

BEGIN;

DROP FUNCTION IF EXISTS public.confirm_extra_hour_stripe_payment(UUID, TEXT, NUMERIC, NUMERIC);

CREATE OR REPLACE FUNCTION public.confirm_extra_hour_stripe_payment(
  p_extra_id           UUID,
  p_stripe_payment_id  TEXT,
  p_amount_paid        NUMERIC,
  p_stripe_fee         NUMERIC DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_extra     RECORD;
  v_group_id  UUID;
  v_owner_id  UUID;
  v_client_id UUID;
  v_res_id    UUID;
  v_wallet    RECORD;
  v_earnings  NUMERIC(12,2);
  v_bal_after NUMERIC(14,2);
BEGIN
  -- ── 1. Lock extra_hour ────────────────────────────────────────────
  SELECT *
  INTO   v_extra
  FROM   public.extra_hours
  WHERE  id = p_extra_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'extra_not_found');
  END IF;

  -- ── 2. Idempotencia ───────────────────────────────────────────────
  IF v_extra.status = 'paid' THEN
    RETURN jsonb_build_object('ok', true, 'skipped', true, 'reason', 'already_paid');
  END IF;

  IF v_extra.status NOT IN ('awaiting_group_confirmation') THEN
    RETURN jsonb_build_object(
      'ok',     false,
      'error',  'invalid_status',
      'status', v_extra.status
    );
  END IF;

  -- ── 3. Lock reservation FOR UPDATE ───────────────────────────────
  SELECT r.id, r.client_id, r.group_id
  INTO   v_res_id, v_client_id, v_group_id
  FROM   public.reservations r
  WHERE  r.id = v_extra.reservation_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'reservation_not_found');
  END IF;

  -- Obtener owner_id del grupo (groups no requiere lock)
  SELECT g.owner_id INTO v_owner_id
  FROM   public.groups g WHERE g.id = v_group_id;

  -- ── 4. Lock group_wallet (crear si no existe) ─────────────────────
  SELECT *
  INTO   v_wallet
  FROM   public.group_wallets
  WHERE  group_id = v_group_id
  FOR UPDATE;

  IF NOT FOUND THEN
    INSERT INTO public.group_wallets (group_id)
    VALUES (v_group_id)
    RETURNING * INTO v_wallet;
  END IF;

  -- ── 5. Calcular earnings (ya pre-calculado = total * 0.90) ────────
  v_earnings  := ROUND(COALESCE(v_extra.group_extra_earnings, 0), 2);
  v_bal_after := COALESCE(v_wallet.pending_balance, 0) + v_earnings;

  -- ── 6. Acreditar pending_balance al grupo ─────────────────────────
  UPDATE public.group_wallets
  SET
    pending_balance = v_bal_after,
    total_earned    = COALESCE(total_earned, 0) + v_earnings,
    updated_at      = NOW()
  WHERE group_id = v_group_id;

  -- ── 7. Marcar extra_hour → 'paid' ─────────────────────────────────
  UPDATE public.extra_hours
  SET
    status            = 'paid',
    stripe_payment_id = p_stripe_payment_id,
    paid_at           = NOW(),
    payout_status     = 'held'
  WHERE id = p_extra_id;

  -- ── 8. Incrementar extra_hours_added en reservation ───────────────
  UPDATE public.reservations
  SET    extra_hours_added = COALESCE(extra_hours_added, 0) + v_extra.hours_added
  WHERE  id = v_res_id;

  -- ── 9. wallet_transaction ─────────────────────────────────────────
  INSERT INTO public.wallet_transactions (
    group_wallet_id,
    group_id,
    type,
    amount,
    reservation_id,
    mp_payment_id,
    description,
    balance_after
  ) VALUES (
    v_wallet.id,
    v_group_id,
    'extra_hour',
    v_earnings,
    v_res_id,
    p_stripe_payment_id,
    'Hora extra (Stripe) — retenida hasta fin de evento',
    v_bal_after
  );

  -- ── 10. financial_audit_log (esquema real: sql/354) ───────────────
  INSERT INTO public.financial_audit_logs (
    entity_type,
    entity_id,
    action,
    actor_id,
    actor_role,
    before_state,
    after_state,
    amount,
    notes
  ) VALUES (
    'extra_hour',
    p_extra_id,
    'stripe_paid',
    NULL,
    'stripe_webhook',
    jsonb_build_object('status', 'awaiting_group_confirmation', 'payout_status', 'pending'),
    jsonb_build_object(
      'status',             'paid',
      'payout_status',      'held',
      'stripe_payment_id',  p_stripe_payment_id,
      'amount_paid',        p_amount_paid
    ),
    p_amount_paid,
    'Pago Stripe hora extra confirmado por webhook'
  );

  -- ── 11. Notificar al grupo ────────────────────────────────────────
  IF v_owner_id IS NOT NULL THEN
    INSERT INTO public.notifications (user_id, type, title, body, data)
    VALUES (
      v_owner_id,
      'extra_hour_approved_by_client',
      '💰 ' || v_extra.hours_added || 'h extra pagadas con tarjeta',
      'El cliente pagó $' || ROUND(v_extra.total_extra_cost)::TEXT ||
        ' MXN. Las ganancias ($' || ROUND(v_earnings)::TEXT || ') se liberan al terminar.',
      jsonb_build_object(
        'reservation_id', v_res_id,
        'extra_hour_id',  p_extra_id,
        'screen',         'EventTimer'
      )
    );
  END IF;

  -- ── 12. Notificar al cliente ──────────────────────────────────────
  IF v_client_id IS NOT NULL THEN
    INSERT INTO public.notifications (user_id, type, title, body, data)
    VALUES (
      v_client_id,
      'extra_hour_payment_confirmed',
      '✅ ' || v_extra.hours_added || 'h extra confirmadas',
      'Tu pago fue procesado. El evento se extiende automáticamente.',
      jsonb_build_object(
        'reservation_id', v_res_id,
        'screen',         'EventTimer'
      )
    );
  END IF;

  RETURN jsonb_build_object(
    'ok',       true,
    'extra_id', p_extra_id,
    'earnings', v_earnings,
    'group_id', v_group_id
  );

EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$$;

GRANT EXECUTE ON FUNCTION public.confirm_extra_hour_stripe_payment(UUID, TEXT, NUMERIC, NUMERIC)
  TO authenticated, service_role;

COMMIT;

-- ════════════════════════════════════════════════════════════════════
-- VERIFICACIONES (ejecutar separado después del COMMIT)
-- ════════════════════════════════════════════════════════════════════

-- V1: Función existe con firma correcta
SELECT COUNT(*) = 1 AS funcion_existe
FROM   pg_proc p
JOIN   pg_namespace n ON n.oid = p.pronamespace
WHERE  n.nspname  = 'public'
  AND  p.proname  = 'confirm_extra_hour_stripe_payment';
-- Esperado: true

-- V2: SECURITY DEFINER activo
SELECT prosecdef AS is_security_definer
FROM   pg_proc p
JOIN   pg_namespace n ON n.oid = p.pronamespace
WHERE  n.nspname = 'public'
  AND  p.proname = 'confirm_extra_hour_stripe_payment';
-- Esperado: true

-- V3: GRANT existe para service_role
SELECT COUNT(*) > 0 AS grant_service_role
FROM   information_schema.role_routine_grants
WHERE  routine_schema = 'public'
  AND  routine_name   = 'confirm_extra_hour_stripe_payment'
  AND  grantee        = 'service_role';
-- Esperado: true

-- V4: Función usa notificaciones correctas (no 'reservation')
SELECT
  routine_definition LIKE '%extra_hour_approved_by_client%' AS usa_notif_grupo,
  routine_definition LIKE '%extra_hour_payment_confirmed%'   AS usa_notif_cliente,
  routine_definition NOT LIKE '%''reservation''%'            AS sin_tipo_legacy
FROM information_schema.routines
WHERE routine_schema = 'public'
  AND routine_name   = 'confirm_extra_hour_stripe_payment';
-- Esperado: true | true | true
