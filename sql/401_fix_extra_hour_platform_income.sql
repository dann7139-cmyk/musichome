-- ════════════════════════════════════════════════════════════════════
-- sql/401 — Fix: confirm_extra_hour_stripe_payment sin platform_income
--
-- Problema: sql/400 acredita el 90% al grupo correctamente pero NO
-- registra el 10% como platform_income en wallet_transactions del admin.
-- Daricefy no recibía su comisión en cada hora extra pagada con Stripe.
--
-- Fix: añadir bloque 10b — calcular y acreditar comisión neta al admin,
-- idéntico al patrón de confirm_full_payment_and_credit_wallet (sql/240).
--
-- Cambios vs sql/400 (único archivo anterior que define esta función):
--   1. DECLARE: +v_service_fee, +v_stripe_fee, +v_admin_neto, +v_admin_id
--   2. Paso 5b: calcular service_fee=10%, stripe_fee (real o fallback), admin_neto
--   3. Paso 10b: UPDATE wallets + INSERT wallet_transactions (platform_income)
--
-- NO TOCA:
--   confirm_full_payment_and_credit_wallet
--   release_extra_hours_partial / release_extra_hours_final
--   group_accept_extra_hour_stripe
--   group_confirm_extra_hours / group_reject_extra_hour
--   stripe-webhook (ya pasa p_stripe_fee correctamente)
--   Notificaciones existentes (pasos 11 y 12)
--
-- Comisión: 10% (se subirá a 20% en refactor posterior separado).
-- Fallback stripe_fee: 3.6% + $3 si webhook no lo entrega.
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
  v_extra       RECORD;
  v_group_id    UUID;
  v_owner_id    UUID;
  v_client_id   UUID;
  v_res_id      UUID;
  v_wallet      RECORD;
  v_earnings    NUMERIC(12,2);
  v_bal_after   NUMERIC(14,2);
  -- Comisión Daricefy (añadido en sql/401)
  v_service_fee NUMERIC(12,2);
  v_stripe_fee  NUMERIC(12,2);
  v_admin_neto  NUMERIC(12,2);
  v_admin_id    UUID;
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

  IF v_extra.status NOT IN ('pending_payment') THEN
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

  -- ── 5. Calcular earnings del grupo (90% pre-calculado al INSERT) ──
  v_earnings  := ROUND(COALESCE(v_extra.group_extra_earnings, 0), 2);
  v_bal_after := COALESCE(v_wallet.pending_balance, 0) + v_earnings;

  -- ── 5b. Calcular comisión Daricefy ────────────────────────────────
  -- 10% bruto sobre lo que pagó el cliente (total_extra_cost).
  -- Stripe fee: real desde webhook o estimado 3.6% + $3 fijo.
  -- Neto = bruto - stripe_fee (mínimo 0).
  v_service_fee := ROUND(v_extra.total_extra_cost * 0.10, 2);
  v_stripe_fee  := COALESCE(
                     p_stripe_fee,
                     ROUND(v_extra.total_extra_cost * 0.036 + 3, 2)
                   );
  v_admin_neto  := GREATEST(0, v_service_fee - v_stripe_fee);

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

  -- ── 9. wallet_transaction del grupo ──────────────────────────────
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

  -- ── 10. financial_audit_log ───────────────────────────────────────
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
    jsonb_build_object('status', 'pending_payment', 'payout_status', 'pending'),
    jsonb_build_object(
      'status',             'paid',
      'payout_status',      'held',
      'stripe_payment_id',  p_stripe_payment_id,
      'amount_paid',        p_amount_paid,
      'service_fee',        v_service_fee,
      'stripe_fee',         v_stripe_fee,
      'admin_neto',         v_admin_neto
    ),
    p_amount_paid,
    'Pago Stripe hora extra confirmado por webhook'
  );

  -- ── 10b. platform_income → admin wallet (Daricefy) ───────────────
  -- Patrón idéntico a confirm_full_payment_and_credit_wallet (sql/240).
  -- Acredita el neto de comisión a available_balance del admin inmediatamente
  -- (no a pending, ya que este ingreso no está sujeto a disputa de evento).
  SELECT id INTO v_admin_id
  FROM   public.profiles
  WHERE  role = 'admin'
  ORDER  BY created_at
  LIMIT  1;

  IF v_admin_id IS NOT NULL THEN
    INSERT INTO public.wallets (user_id, available_balance, pending_balance, total_earned)
    VALUES (v_admin_id, 0, 0, 0)
    ON CONFLICT (user_id) DO NOTHING;

    UPDATE public.wallets
    SET
      available_balance = available_balance + v_admin_neto,
      total_earned      = COALESCE(total_earned, 0) + v_admin_neto,
      updated_at        = NOW()
    WHERE user_id = v_admin_id;

    INSERT INTO public.wallet_transactions (
      user_id,
      type,
      amount,
      reservation_id,
      description
    ) VALUES (
      v_admin_id,
      'platform_income',
      v_admin_neto,
      v_res_id,
      format(
        'Comisión extra-hora $%s − Stripe $%s = $%s neto — extra %s',
        v_service_fee::TEXT,
        v_stripe_fee::TEXT,
        v_admin_neto::TEXT,
        p_extra_id
      )
    );
  END IF;

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
    'ok',           true,
    'extra_id',     p_extra_id,
    'earnings',     v_earnings,
    'group_id',     v_group_id,
    'service_fee',  v_service_fee,
    'stripe_fee',   v_stripe_fee,
    'admin_neto',   v_admin_neto
  );

EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$$;

GRANT EXECUTE ON FUNCTION public.confirm_extra_hour_stripe_payment(UUID, TEXT, NUMERIC, NUMERIC)
  TO authenticated, service_role;

COMMIT;


-- ════════════════════════════════════════════════════════════════════
-- VERIFICACIONES (ejecutar separado, después del COMMIT)
-- ════════════════════════════════════════════════════════════════════

-- V1: Función existe con nombre correcto
SELECT COUNT(*) = 1 AS funcion_existe
FROM   pg_proc p
JOIN   pg_namespace n ON n.oid = p.pronamespace
WHERE  n.nspname = 'public'
  AND  p.proname = 'confirm_extra_hour_stripe_payment';
-- Esperado: true

-- V2: Contiene las 4 variables nuevas y el bloque platform_income
SELECT
  routine_definition LIKE '%v_service_fee%'  AS tiene_service_fee,
  routine_definition LIKE '%v_stripe_fee%'   AS tiene_stripe_fee,
  routine_definition LIKE '%v_admin_neto%'   AS tiene_admin_neto,
  routine_definition LIKE '%v_admin_id%'     AS tiene_admin_id,
  routine_definition LIKE '%platform_income%' AS tiene_platform_income,
  routine_definition LIKE '%pending_payment%' AS valida_pending_payment,
  routine_definition NOT LIKE '%awaiting_group_confirmation%' AS no_valida_legacy
FROM   information_schema.routines
WHERE  routine_schema = 'public'
  AND  routine_name   = 'confirm_extra_hour_stripe_payment';
-- Esperado: true | true | true | true | true | true | true

-- V3: GRANTs correctos para authenticated y service_role
SELECT grantee, privilege_type
FROM   information_schema.routine_privileges
WHERE  routine_schema = 'public'
  AND  routine_name   = 'confirm_extra_hour_stripe_payment'
ORDER  BY grantee;
-- Esperado: 2 filas — authenticated EXECUTE, service_role EXECUTE

-- V4: Idempotencia — función devuelve skip si extra ya está 'paid'
--     (no necesita extra real: basta verificar la rama en el código)
SELECT
  routine_definition LIKE '%already_paid%' AS skip_si_already_paid,
  routine_definition LIKE '%skipped%'      AS devuelve_skipped
FROM   information_schema.routines
WHERE  routine_schema = 'public'
  AND  routine_name   = 'confirm_extra_hour_stripe_payment';
-- Esperado: true | true


-- ════════════════════════════════════════════════════════════════════
-- BACKFILL OPCIONAL — extras Stripe ya pagadas sin platform_income
--
-- Identificar:
SELECT
  eh.id                   AS extra_id,
  eh.total_extra_cost     AS total_pagado,
  ROUND(eh.total_extra_cost * 0.10, 2) AS comision_bruta,
  eh.paid_at,
  eh.stripe_payment_id
FROM   public.extra_hours eh
WHERE  eh.status         = 'paid'
  AND  eh.payment_method = 'stripe'
  AND  NOT EXISTS (
    SELECT 1
    FROM   public.wallet_transactions wt
    WHERE  wt.reservation_id = eh.reservation_id
      AND  wt.type           = 'platform_income'
      AND  wt.description    LIKE '%extra%'
  )
ORDER  BY eh.paid_at;
-- Si hay filas: ejecutar el bloque de backfill por separado (sql/401b).
-- ════════════════════════════════════════════════════════════════════

SELECT 'sql/401_fix_extra_hour_platform_income.sql aplicado ✅' AS status;
