-- ════════════════════════════════════════════════════════════════════
-- sql/541 — Horas extra: currency-aware + fail-closed
--
-- Contexto (auditoría 2026-08-08):
--   confirm_extra_hour_stripe_payment, release_extra_hours_partial y
--   release_extra_hours_final acreditaban SIEMPRE las columnas MXN del
--   wallet (pending_balance / available_balance), sin importar la moneda
--   real de la reserva. El cobro a Stripe ya era correcto (create-extra-
--   hour-payment-intent detecta bien la moneda) — el bug era puramente
--   de contabilidad interna: dólares se sumaban a columnas de pesos.
--   Verificado en producción: 0 reservas USD, 0 extra_hours, 0
--   wallet_transactions de horas extra, 0 withdrawals — sin dato
--   histórico que reparar. Este fix es puramente preventivo.
--
-- Cambios:
--   A) confirm_extra_hour_stripe_payment — NUEVA FIRMA (agrega p_currency).
--      Único caller: supabase/functions/stripe-webhook/index.ts.
--      Valida p_currency (moneda real del cobro Stripe) contra
--      extra_hours.currency_code (moneda esperada, ya poblada por el
--      INSERT de EventTimerScreen.tsx desde este mismo cambio). Si no
--      coinciden: registra financial_audit_logs y falla cerrado —
--      NINGÚN wallet se toca, extra_hours.status no avanza. Sin
--      conversiones automáticas.
--   B) release_extra_hours_partial / release_extra_hours_final — MISMA
--      FIRMA (solo p_reservation_id). Usan reservations.currency_code
--      como fuente única de la moneda (una reserva = una sola moneda
--      para todas sus filas de extra_hours). MXN solo toca columnas
--      MXN, USD solo toca columnas USD — nunca se mezclan.
--   C) Las tres corrigen el texto de notificación (antes " MXN" fijo).
--
-- NO TOCA:
--   group_accept_extra_hour_stripe, create-extra-hour-payment-intent,
--   withdrawals, ningún otro flujo de pago, ningún dato histórico
--   (no existe dato histórico afectado — confirmado por auditoría).
-- ════════════════════════════════════════════════════════════════════

BEGIN;

-- ── A. confirm_extra_hour_stripe_payment — nueva firma (+ p_currency) ────────

DROP FUNCTION IF EXISTS public.confirm_extra_hour_stripe_payment(UUID, TEXT, NUMERIC, NUMERIC);

CREATE OR REPLACE FUNCTION public.confirm_extra_hour_stripe_payment(
  p_extra_id           UUID,
  p_stripe_payment_id  TEXT,
  p_amount_paid        NUMERIC,
  p_currency           TEXT,
  p_stripe_fee         NUMERIC DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_extra         RECORD;
  v_group_id      UUID;
  v_owner_id      UUID;
  v_client_id     UUID;
  v_res_id        UUID;
  v_wallet        RECORD;
  v_earnings      NUMERIC(12,2);
  v_bal_after     NUMERIC(14,2);
  v_service_fee   NUMERIC(12,2);
  v_stripe_fee    NUMERIC(12,2);
  v_admin_neto    NUMERIC(12,2);
  v_admin_id      UUID;
  v_currency      TEXT;
  v_paid_currency TEXT;
  v_curr_label    TEXT;
BEGIN
  SELECT * INTO v_extra FROM public.extra_hours WHERE id = p_extra_id FOR UPDATE;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'extra_not_found');
  END IF;

  IF v_extra.status = 'paid' THEN
    RETURN jsonb_build_object('ok', true, 'skipped', true, 'reason', 'already_paid');
  END IF;

  IF v_extra.status NOT IN ('pending_payment') THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_status', 'status', v_extra.status);
  END IF;

  SELECT r.id, r.client_id, r.group_id INTO v_res_id, v_client_id, v_group_id
  FROM   public.reservations r WHERE r.id = v_extra.reservation_id FOR UPDATE;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'reservation_not_found');
  END IF;

  -- ── Validación de moneda — fail-closed, sin conversiones ──────────────────
  -- Moneda esperada = extra_hours.currency_code (heredada de la reserva al
  -- crear la solicitud). Moneda recibida = pi.currency real de Stripe.
  -- Si no coinciden (o si currency_code quedó NULL en una fila legada),
  -- NINGÚN wallet se toca y extra_hours.status NO avanza a 'paid'.
  v_currency      := v_extra.currency_code;
  v_paid_currency := UPPER(COALESCE(p_currency, ''));

  IF v_paid_currency IS DISTINCT FROM v_currency THEN
    -- Si este INSERT falla, la excepción se propaga al handler de abajo y
    -- la función retorna sin haber acreditado nada — el bloqueo es efectivo
    -- con o sin auditoría exitosa.
    INSERT INTO public.financial_audit_logs (
      entity_type, entity_id, action, actor_id, actor_role,
      before_state, after_state, amount, notes
    ) VALUES (
      'extra_hour', p_extra_id, 'currency_mismatch_blocked', NULL, 'stripe_webhook',
      jsonb_build_object('status', v_extra.status, 'expected_currency', v_currency),
      jsonb_build_object(
        'expected_currency',        v_currency,
        'received_currency',        v_paid_currency,
        'stripe_payment_intent_id', p_stripe_payment_id
      ),
      p_amount_paid,
      'Pago Stripe hora extra BLOQUEADO: moneda esperada ' || COALESCE(v_currency, 'NULL') ||
        ' recibida ' || COALESCE(NULLIF(v_paid_currency, ''), 'NULL')
    );

    RETURN jsonb_build_object(
      'ok',       false,
      'error',    'currency_mismatch',
      'expected', v_currency,
      'received', v_paid_currency
    );
  END IF;

  SELECT g.owner_id INTO v_owner_id FROM public.groups g WHERE g.id = v_group_id;

  SELECT * INTO v_wallet FROM public.group_wallets WHERE group_id = v_group_id FOR UPDATE;
  IF NOT FOUND THEN
    INSERT INTO public.group_wallets (group_id) VALUES (v_group_id) RETURNING * INTO v_wallet;
  END IF;

  -- Ganancia del grupo: 100% de su precio neto (almacenado en group_extra_earnings)
  v_earnings := ROUND(COALESCE(v_extra.group_extra_earnings, 0), 2);

  -- Comisión Daricefy: diferencia entre lo que pagó el cliente y lo que recibe el grupo.
  v_service_fee := ROUND(
    v_extra.total_extra_cost
    - COALESCE(v_extra.group_extra_earnings, ROUND(v_extra.total_extra_cost / 1.20, 2)),
    2
  );
  v_stripe_fee := COALESCE(p_stripe_fee, ROUND(v_extra.total_extra_cost * 0.036 + 3, 2));
  v_admin_neto := GREATEST(0, v_service_fee - v_stripe_fee);
  v_curr_label := CASE WHEN v_currency = 'USD' THEN 'USD' ELSE 'MXN' END;

  -- ── Acreditar ganancia del grupo — bucket según moneda, nunca mezclado ────
  IF v_currency = 'USD' THEN
    v_bal_after := COALESCE(v_wallet.pending_balance_usd, 0) + v_earnings;

    UPDATE public.group_wallets
    SET pending_balance_usd = v_bal_after,
        total_earned_usd    = COALESCE(total_earned_usd, 0) + v_earnings,
        updated_at          = NOW()
    WHERE group_id = v_group_id;
  ELSE
    v_bal_after := COALESCE(v_wallet.pending_balance, 0) + v_earnings;

    UPDATE public.group_wallets
    SET pending_balance = v_bal_after,
        total_earned    = COALESCE(total_earned, 0) + v_earnings,
        updated_at      = NOW()
    WHERE group_id = v_group_id;
  END IF;

  UPDATE public.extra_hours
  SET status            = 'paid',
      stripe_payment_id = p_stripe_payment_id,
      paid_at           = NOW(),
      payout_status     = 'held'
  WHERE id = p_extra_id;

  UPDATE public.reservations
  SET extra_hours_added = COALESCE(extra_hours_added, 0) + v_extra.hours_added
  WHERE id = v_res_id;

  INSERT INTO public.wallet_transactions (
    group_wallet_id, group_id, type, amount, reservation_id,
    mp_payment_id, description, balance_after, currency_code
  ) VALUES (
    v_wallet.id, v_group_id, 'extra_hour', v_earnings, v_res_id,
    p_stripe_payment_id,
    'Hora extra (Stripe) — retenida hasta fin de evento',
    v_bal_after, v_currency
  );

  INSERT INTO public.financial_audit_logs (
    entity_type, entity_id, action, actor_id, actor_role,
    before_state, after_state, amount, notes
  ) VALUES (
    'extra_hour', p_extra_id, 'stripe_paid', NULL, 'stripe_webhook',
    jsonb_build_object('status', 'pending_payment', 'payout_status', 'pending'),
    jsonb_build_object(
      'status',            'paid',
      'payout_status',     'held',
      'stripe_payment_id', p_stripe_payment_id,
      'amount_paid',       p_amount_paid,
      'currency',          v_currency,
      'service_fee',       v_service_fee,
      'stripe_fee',        v_stripe_fee,
      'admin_neto',        v_admin_neto
    ),
    p_amount_paid,
    'Pago Stripe hora extra confirmado por webhook'
  );

  -- platform_income → admin wallet (bucket según moneda; wallets no tiene
  -- pending_balance_usd — la comisión admin siempre va directo a available,
  -- igual que ya ocurría en MXN)
  SELECT id INTO v_admin_id FROM public.profiles WHERE role = 'admin' ORDER BY created_at LIMIT 1;
  IF v_admin_id IS NOT NULL THEN
    INSERT INTO public.wallets (user_id, available_balance, pending_balance, total_earned)
    VALUES (v_admin_id, 0, 0, 0)
    ON CONFLICT (user_id) DO NOTHING;

    IF v_currency = 'USD' THEN
      UPDATE public.wallets
      SET available_balance_usd = COALESCE(available_balance_usd, 0) + v_admin_neto,
          total_earned_usd      = COALESCE(total_earned_usd, 0) + v_admin_neto,
          updated_at            = NOW()
      WHERE user_id = v_admin_id;
    ELSE
      UPDATE public.wallets
      SET available_balance = available_balance + v_admin_neto,
          total_earned      = COALESCE(total_earned, 0) + v_admin_neto,
          updated_at        = NOW()
      WHERE user_id = v_admin_id;
    END IF;

    INSERT INTO public.wallet_transactions (
      user_id, type, amount, reservation_id, description, currency_code
    ) VALUES (
      v_admin_id, 'platform_income', v_admin_neto, v_res_id,
      format('Comisión extra-hora $%s − Stripe $%s = $%s neto — extra %s',
        v_service_fee::TEXT, v_stripe_fee::TEXT, v_admin_neto::TEXT, p_extra_id),
      v_currency
    );
  END IF;

  IF v_owner_id IS NOT NULL THEN
    INSERT INTO public.notifications (user_id, type, title, body, data)
    VALUES (
      v_owner_id, 'extra_hour_approved_by_client',
      '💰 ' || v_extra.hours_added || 'h extra pagadas con tarjeta',
      'El cliente pagó $' || ROUND(v_extra.total_extra_cost)::TEXT ||
        ' ' || v_curr_label || '. Las ganancias ($' || ROUND(v_earnings)::TEXT || ') se liberan al terminar.',
      jsonb_build_object(
        'reservation_id', v_res_id, 'extra_hour_id', p_extra_id, 'screen', 'EventTimer'
      )
    );
  END IF;

  IF v_client_id IS NOT NULL THEN
    INSERT INTO public.notifications (user_id, type, title, body, data)
    VALUES (
      v_client_id, 'extra_hour_payment_confirmed',
      '✅ ' || v_extra.hours_added || 'h extra confirmadas',
      'Tu pago fue procesado. El evento se extiende automáticamente.',
      jsonb_build_object('reservation_id', v_res_id, 'screen', 'EventTimer')
    );
  END IF;

  RETURN jsonb_build_object(
    'ok', true, 'extra_id', p_extra_id,
    'earnings', v_earnings, 'group_id', v_group_id,
    'currency', v_currency,
    'service_fee', v_service_fee, 'stripe_fee', v_stripe_fee, 'admin_neto', v_admin_neto
  );

EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$$;

GRANT EXECUTE ON FUNCTION public.confirm_extra_hour_stripe_payment(UUID, TEXT, NUMERIC, TEXT, NUMERIC)
  TO authenticated, service_role;

-- ── B. release_extra_hours_partial — currency-aware, misma firma ─────────────

DROP FUNCTION IF EXISTS public.release_extra_hours_partial(UUID);

CREATE OR REPLACE FUNCTION public.release_extra_hours_partial(
  p_reservation_id UUID
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_group_id  UUID;
  v_currency  TEXT;
  v_wallet    RECORD;
  v_extra     RECORD;
  v_half      NUMERIC(12,2);
  v_released  INTEGER := 0;
  v_skipped   INTEGER := 0;
BEGIN
  -- reservations.currency_code = fuente única de la moneda. Una reserva
  -- tiene una sola moneda para todas sus filas de extra_hours.
  SELECT r.group_id, r.currency_code
  INTO   v_group_id, v_currency
  FROM   public.reservations r
  WHERE  r.id = p_reservation_id;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'reservation_not_found');
  END IF;

  SELECT *
  INTO   v_wallet
  FROM   public.group_wallets
  WHERE  group_id = v_group_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'wallet_not_found');
  END IF;

  FOR v_extra IN
    SELECT *
    FROM   public.extra_hours
    WHERE  reservation_id = p_reservation_id
      AND  status         = 'paid'
      AND  payout_status  = 'held'
    FOR UPDATE SKIP LOCKED
  LOOP
    v_half := ROUND(COALESCE(v_extra.group_extra_earnings, 0) * 0.5, 2);

    IF v_currency = 'USD' THEN
      UPDATE public.group_wallets
      SET
        pending_balance_usd   = GREATEST(0, COALESCE(pending_balance_usd,   0) - v_half),
        available_balance_usd = COALESCE(available_balance_usd, 0) + v_half,
        updated_at            = NOW()
      WHERE group_id = v_group_id
      RETURNING available_balance_usd INTO v_wallet.available_balance_usd;
    ELSE
      UPDATE public.group_wallets
      SET
        pending_balance   = GREATEST(0, COALESCE(pending_balance,   0) - v_half),
        available_balance = COALESCE(available_balance, 0) + v_half,
        updated_at        = NOW()
      WHERE group_id = v_group_id
      RETURNING available_balance INTO v_wallet.available_balance;
    END IF;

    UPDATE public.extra_hours
    SET
      payout_status    = 'half_released',
      half_released_at = NOW()
    WHERE id = v_extra.id;

    INSERT INTO public.wallet_transactions (
      group_wallet_id, group_id, type, amount,
      reservation_id,  description, balance_after, currency_code
    ) VALUES (
      v_wallet.id, v_group_id, 'credit_available', v_half,
      p_reservation_id,
      'Hora extra — liberación parcial 50% (inicio extras)',
      CASE WHEN v_currency = 'USD' THEN v_wallet.available_balance_usd ELSE v_wallet.available_balance END,
      v_currency
    );

    INSERT INTO public.financial_audit_logs (
      entity_type, entity_id, action, actor_id, actor_role,
      before_state, after_state, amount, notes
    ) VALUES (
      'extra_hour', v_extra.id, 'partial_release', auth.uid(), 'system',
      jsonb_build_object('payout_status', 'held'),
      jsonb_build_object('payout_status', 'half_released', 'currency', v_currency),
      v_half,
      '50% liberado al iniciar horas extra'
    );

    v_released := v_released + 1;
  END LOOP;

  SELECT COUNT(*)
  INTO   v_skipped
  FROM   public.extra_hours
  WHERE  reservation_id = p_reservation_id
    AND  status         = 'paid'
    AND  payout_status != 'held';

  RETURN jsonb_build_object(
    'ok',       true,
    'released', v_released,
    'skipped',  v_skipped
  );

EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$$;

GRANT EXECUTE ON FUNCTION public.release_extra_hours_partial(UUID)
  TO authenticated, service_role;

-- ── C. release_extra_hours_final — currency-aware, misma firma ───────────────

DROP FUNCTION IF EXISTS public.release_extra_hours_final(UUID);

CREATE OR REPLACE FUNCTION public.release_extra_hours_final(
  p_reservation_id UUID
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_group_id       UUID;
  v_currency       TEXT;
  v_curr_label     TEXT;
  v_owner_id       UUID;
  v_wallet         RECORD;
  v_extra          RECORD;
  v_amount         NUMERIC(12,2);
  v_label          TEXT;
  v_released       INTEGER        := 0;
  v_total_released NUMERIC(12,2)  := 0;
BEGIN
  SELECT r.group_id, r.currency_code
  INTO   v_group_id, v_currency
  FROM   public.reservations r
  WHERE  r.id = p_reservation_id;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'reservation_not_found');
  END IF;

  SELECT *
  INTO   v_wallet
  FROM   public.group_wallets
  WHERE  group_id = v_group_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', true, 'released', 0, 'reason', 'no_wallet');
  END IF;

  SELECT g.owner_id
  INTO   v_owner_id
  FROM   public.groups g
  WHERE  g.id = v_group_id;

  v_curr_label := CASE WHEN v_currency = 'USD' THEN 'USD' ELSE 'MXN' END;

  FOR v_extra IN
    SELECT *
    FROM   public.extra_hours
    WHERE  reservation_id = p_reservation_id
      AND  status         = 'paid'
      AND  payout_status  IN ('held', 'half_released')
    FOR UPDATE SKIP LOCKED
  LOOP
    IF v_extra.payout_status = 'held' THEN
      v_amount := ROUND(COALESCE(v_extra.group_extra_earnings, 0), 2);
      v_label  := 'Hora extra — liberación total (partial omitida)';
    ELSE
      v_amount := ROUND(COALESCE(v_extra.group_extra_earnings, 0) * 0.5, 2);
      v_label  := 'Hora extra — liberación final 50% restante';
    END IF;

    IF v_currency = 'USD' THEN
      UPDATE public.group_wallets
      SET
        pending_balance_usd   = GREATEST(0, COALESCE(pending_balance_usd,   0) - v_amount),
        available_balance_usd = COALESCE(available_balance_usd, 0) + v_amount,
        updated_at            = NOW()
      WHERE group_id = v_group_id
      RETURNING available_balance_usd INTO v_wallet.available_balance_usd;
    ELSE
      UPDATE public.group_wallets
      SET
        pending_balance   = GREATEST(0, COALESCE(pending_balance,   0) - v_amount),
        available_balance = COALESCE(available_balance, 0) + v_amount,
        updated_at        = NOW()
      WHERE group_id = v_group_id
      RETURNING available_balance INTO v_wallet.available_balance;
    END IF;

    UPDATE public.extra_hours
    SET
      payout_status = 'released',
      released_at   = NOW()
    WHERE id = v_extra.id;

    INSERT INTO public.wallet_transactions (
      group_wallet_id, group_id, type, amount,
      reservation_id,  description, balance_after, currency_code
    ) VALUES (
      v_wallet.id, v_group_id, 'credit_available', v_amount,
      p_reservation_id, v_label,
      CASE WHEN v_currency = 'USD' THEN v_wallet.available_balance_usd ELSE v_wallet.available_balance END,
      v_currency
    );

    INSERT INTO public.financial_audit_logs (
      entity_type, entity_id, action, actor_id, actor_role,
      before_state, after_state, amount, notes
    ) VALUES (
      'extra_hour', v_extra.id, 'final_release', auth.uid(), 'system',
      jsonb_build_object('payout_status', v_extra.payout_status),
      jsonb_build_object('payout_status', 'released', 'currency', v_currency),
      v_amount,
      v_label
    );

    v_total_released := v_total_released + v_amount;
    v_released       := v_released + 1;
  END LOOP;

  IF v_released > 0 AND v_owner_id IS NOT NULL THEN
    INSERT INTO public.notifications (user_id, type, title, body, data)
    VALUES (
      v_owner_id,
      'payment_released',
      '💸 Ganancias de extras disponibles',
      '$' || ROUND(v_total_released)::TEXT ||
        ' ' || v_curr_label || ' de horas extra están listos para retiro.',
      jsonb_build_object(
        'reservation_id', p_reservation_id,
        'amount',         v_total_released,
        'screen',         'GroupDashboard'
      )
    );
  END IF;

  RETURN jsonb_build_object(
    'ok',      true,
    'released', v_released,
    'amount',   v_total_released
  );

EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$$;

GRANT EXECUTE ON FUNCTION public.release_extra_hours_final(UUID)
  TO authenticated, service_role;

COMMIT;

-- ════════════════════════════════════════════════════════════════════
-- VERIFICACIONES (ejecutar separado después del COMMIT)
-- ════════════════════════════════════════════════════════════════════

-- V1: confirm_extra_hour_stripe_payment existe con la firma NUEVA (5 args, incluye p_currency)
SELECT COUNT(*) = 1 AS firma_nueva_existe
FROM   pg_proc p
JOIN   pg_namespace n ON n.oid = p.pronamespace
WHERE  n.nspname = 'public'
  AND  p.proname = 'confirm_extra_hour_stripe_payment'
  AND  pg_get_function_identity_arguments(p.oid) =
       'p_extra_id uuid, p_stripe_payment_id text, p_amount_paid numeric, p_currency text, p_stripe_fee numeric';
-- Esperado: true

-- V2: la firma VIEJA de 4 args ya no existe
SELECT COUNT(*) = 0 AS firma_vieja_eliminada
FROM   pg_proc p
JOIN   pg_namespace n ON n.oid = p.pronamespace
WHERE  n.nspname = 'public'
  AND  p.proname = 'confirm_extra_hour_stripe_payment'
  AND  pg_get_function_identity_arguments(p.oid) =
       'p_extra_id uuid, p_stripe_payment_id text, p_amount_paid numeric, p_stripe_fee numeric';
-- Esperado: true

-- V3: las tres funciones son SECURITY DEFINER
SELECT p.proname, p.prosecdef AS is_security_definer
FROM   pg_proc p
JOIN   pg_namespace n ON n.oid = p.pronamespace
WHERE  n.nspname = 'public'
  AND  p.proname IN ('confirm_extra_hour_stripe_payment', 'release_extra_hours_partial', 'release_extra_hours_final')
ORDER BY p.proname;
-- Esperado: las 3 con is_security_definer = true

-- V4: grant a service_role en las 3
SELECT routine_name, COUNT(*) > 0 AS grant_service_role
FROM   information_schema.role_routine_grants
WHERE  routine_schema = 'public'
  AND  routine_name IN ('confirm_extra_hour_stripe_payment', 'release_extra_hours_partial', 'release_extra_hours_final')
  AND  grantee = 'service_role'
GROUP BY routine_name
ORDER BY routine_name;
-- Esperado: las 3 con true

-- V5: ya no queda el hardcode de notificación " MXN." fijo (sin importar moneda)
SELECT
  routine_definition NOT LIKE '%'' MXN. Las ganancias%' AS confirm_sin_mxn_fijo
FROM information_schema.routines
WHERE routine_schema = 'public' AND routine_name = 'confirm_extra_hour_stripe_payment';
-- Esperado: true

SELECT
  routine_definition NOT LIKE '%MXN de horas extra están listos%' AS final_sin_mxn_fijo
FROM information_schema.routines
WHERE routine_schema = 'public' AND routine_name = 'release_extra_hours_final';
-- Esperado: true

-- V6: confirm_extra_hour_stripe_payment referencia currency_mismatch y el
-- bloqueo de auditoría, y las tres escriben currency_code en wallet_transactions
SELECT
  routine_definition LIKE '%currency_mismatch%'          AS tiene_currency_mismatch,
  routine_definition LIKE '%currency_mismatch_blocked%'  AS audita_bloqueo,
  routine_definition LIKE '%currency_code%'               AS graba_currency_en_wallet_tx
FROM information_schema.routines
WHERE routine_schema = 'public' AND routine_name = 'confirm_extra_hour_stripe_payment';
-- Esperado: true | true | true

SELECT
  routine_definition LIKE '%pending_balance_usd%'   AS partial_usa_bucket_usd,
  routine_definition LIKE '%currency_code%'          AS partial_graba_currency
FROM information_schema.routines
WHERE routine_schema = 'public' AND routine_name = 'release_extra_hours_partial';
-- Esperado: true | true

SELECT
  routine_definition LIKE '%pending_balance_usd%'   AS final_usa_bucket_usd,
  routine_definition LIKE '%currency_code%'          AS final_graba_currency
FROM information_schema.routines
WHERE routine_schema = 'public' AND routine_name = 'release_extra_hours_final';
-- Esperado: true | true

SELECT '541_extra_hour_currency_aware.sql: horas extra currency-aware + fail-closed ✅' AS status;
