-- ════════════════════════════════════════════════════════════════════
-- sql/400 — payment_method en extra_hours + flujo grupo-primero
--
-- Contexto:
--   Antes: handlePayWithStripe cargaba la tarjeta del cliente SIN
--   que el grupo aceptara primero (BUG 1 crítico).
--   Ahora:
--     1. Cliente elige método → INSERT extra_hours (payment_method)
--     2. Grupo acepta → group_accept_extra_hour_stripe → 'pending_payment'
--     3. Cliente paga → Stripe → webhook → confirm (valida 'pending_payment')
--
-- Cambios:
--   A. ADD COLUMN payment_method TEXT DEFAULT 'balance'
--   B. CHECK payment_method IN ('balance','stripe')
--   C. Status CHECK ampliado: agrega 'pending_payment'
--   D. Backfill payment_method IS NULL → 'balance' (filas legadas)
--   E. CREATE RPC group_accept_extra_hour_stripe
--   F. DROP + RECREATE confirm_extra_hour_stripe_payment
--      (cambia validación status: 'awaiting_group_confirmation' → 'pending_payment')
--
-- NO TOCA:
--   confirm_full_payment_and_credit_wallet
--   release_group_earnings_atomic
--   release_extra_hours_partial / release_extra_hours_final
--   group_confirm_extra_hours
--   group_reject_extra_hour
-- ════════════════════════════════════════════════════════════════════

BEGIN;

-- ── A. Columna payment_method ─────────────────────────────────────────────────

ALTER TABLE public.extra_hours
  ADD COLUMN IF NOT EXISTS payment_method TEXT NOT NULL DEFAULT 'balance';

-- ── B. CHECK payment_method ───────────────────────────────────────────────────

DO $$
DECLARE v_con TEXT;
BEGIN
  FOR v_con IN
    SELECT c.conname
    FROM   pg_constraint c
    JOIN   pg_class      t ON t.oid = c.conrelid
    WHERE  t.relname       = 'extra_hours'
      AND  t.relnamespace  = (SELECT oid FROM pg_namespace WHERE nspname = 'public')
      AND  c.contype       = 'c'
      AND  pg_get_constraintdef(c.oid) LIKE '%payment_method%'
  LOOP
    EXECUTE format('ALTER TABLE public.extra_hours DROP CONSTRAINT IF EXISTS %I', v_con);
    RAISE NOTICE '[400] Dropped payment_method constraint: %', v_con;
  END LOOP;
END;
$$;

ALTER TABLE public.extra_hours
  ADD CONSTRAINT extra_hours_payment_method_check
    CHECK (payment_method IN ('balance', 'stripe'));

-- ── C. Status CHECK — ampliar con 'pending_payment' ──────────────────────────
-- Usamos el mismo patrón DO-loop de sql/397 para ser agnósticos al nombre
-- del constraint (puede llamarse extra_hours_status_check o chk_extra_hours_status).

DO $$
DECLARE v_con TEXT;
BEGIN
  FOR v_con IN
    SELECT c.conname
    FROM   pg_constraint c
    JOIN   pg_class      t ON t.oid = c.conrelid
    WHERE  t.relname       = 'extra_hours'
      AND  t.relnamespace  = (SELECT oid FROM pg_namespace WHERE nspname = 'public')
      AND  c.contype       = 'c'
      AND  pg_get_constraintdef(c.oid) LIKE '%status%'
      AND  c.conname NOT LIKE '%payout_status%'
      AND  c.conname NOT LIKE '%payment_method%'
  LOOP
    EXECUTE format('ALTER TABLE public.extra_hours DROP CONSTRAINT IF EXISTS %I', v_con);
    RAISE NOTICE '[400] Dropped status constraint: %', v_con;
  END LOOP;
END;
$$;

ALTER TABLE public.extra_hours
  ADD CONSTRAINT extra_hours_status_check
    CHECK (status IN (
      'pending',
      'client_requested',
      'awaiting_group_confirmation',
      'pending_payment',            -- NUEVO: grupo aceptó, esperando pago del cliente
      'accepted',
      'rejected',
      'cancelled',
      'expired',
      'paid'
    ));

-- ── D. Backfill payment_method para filas legadas ────────────────────────────
-- Las filas creadas antes de sql/400 tienen payment_method='balance' por
-- DEFAULT pero filas muy antiguas pueden tener NULL si el DEFAULT no aplicó.
-- Este UPDATE cubre ambos casos de forma idempotente.

UPDATE public.extra_hours
SET    payment_method = 'balance'
WHERE  payment_method IS NULL
   OR  payment_method NOT IN ('balance', 'stripe');

-- ── E. RPC group_accept_extra_hour_stripe ────────────────────────────────────
--
-- Llamada por el grupo (owner) cuando acepta una hora extra de tipo 'stripe'.
-- El flujo de balance sigue usando group_confirm_extra_hours (sin cambios).
--
-- Validaciones:
--   1. Fila existe y está en 'awaiting_group_confirmation'
--   2. payment_method = 'stripe'  (balance usa otra RPC)
--   3. Caller es el owner del grupo de la reserva
--
-- Efectos:
--   - extra_hours.status → 'pending_payment'
--   - INSERT notification 'extra_hour_payment_required' al cliente

DROP FUNCTION IF EXISTS public.group_accept_extra_hour_stripe(UUID);

CREATE OR REPLACE FUNCTION public.group_accept_extra_hour_stripe(
  p_extra_id UUID
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_extra       RECORD;
  v_res         RECORD;
  v_owner_id    UUID;
BEGIN
  -- ── 1. Lock extra_hour ────────────────────────────────────────────
  SELECT *
  INTO   v_extra
  FROM   public.extra_hours
  WHERE  id = p_extra_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_found');
  END IF;

  -- ── 2. Validar status ─────────────────────────────────────────────
  IF v_extra.status = 'pending_payment' THEN
    RETURN jsonb_build_object('ok', true, 'skipped', true, 'reason', 'already_accepted');
  END IF;

  IF v_extra.status <> 'awaiting_group_confirmation' THEN
    RETURN jsonb_build_object(
      'ok',     false,
      'error',  'wrong_status',
      'status', v_extra.status
    );
  END IF;

  -- ── 3. Validar payment_method ─────────────────────────────────────
  IF v_extra.payment_method <> 'stripe' THEN
    RETURN jsonb_build_object(
      'ok',    false,
      'error', 'use_group_confirm_extra_hours_for_balance'
    );
  END IF;

  -- ── 4. Obtener reserva + validar que el caller es el owner ────────
  SELECT r.id, r.client_id, r.group_id
  INTO   v_res
  FROM   public.reservations r
  WHERE  r.id = v_extra.reservation_id;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'reservation_not_found');
  END IF;

  SELECT g.owner_id INTO v_owner_id
  FROM   public.groups g
  WHERE  g.id = v_res.group_id;

  IF v_owner_id IS DISTINCT FROM auth.uid() THEN
    RETURN jsonb_build_object('ok', false, 'error', 'unauthorized');
  END IF;

  -- ── 5. Actualizar status ──────────────────────────────────────────
  UPDATE public.extra_hours
  SET    status = 'pending_payment'
  WHERE  id = p_extra_id;

  -- ── 6. Notificar al cliente ───────────────────────────────────────
  IF v_res.client_id IS NOT NULL THEN
    INSERT INTO public.notifications (user_id, type, title, body, data)
    VALUES (
      v_res.client_id,
      'extra_hour_payment_required',
      '✅ Grupo aceptó — Paga ahora',
      'El grupo aceptó ' || v_extra.hours_added || 'h extra. Tienes 20 min para confirmar el pago.',
      jsonb_build_object(
        'reservation_id', v_res.id,
        'extra_hour_id',  p_extra_id,
        'hours',          v_extra.hours_added,
        'amount',         v_extra.total_extra_cost,
        'msi_months',     COALESCE(v_extra.msi_months, 1)
      )
    );
  END IF;

  RETURN jsonb_build_object(
    'ok',           true,
    'extra_id',     p_extra_id,
    'reservation_id', v_res.id,
    'client_id',    v_res.client_id
  );

EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$$;

GRANT EXECUTE ON FUNCTION public.group_accept_extra_hour_stripe(UUID)
  TO authenticated;

-- ── F. DROP + RECREATE confirm_extra_hour_stripe_payment ─────────────────────
--
-- Único cambio vs sql/398:
--   ANTES: valida status IN ('awaiting_group_confirmation')
--   AHORA: valida status IN ('pending_payment')
--
-- Razón: el webhook ahora solo llega cuando el grupo YA aceptó y el cliente
-- inició el pago. Filas en 'awaiting_group_confirmation' nunca deberían llegar
-- al webhook en el nuevo flujo.
--
-- Todo lo demás (lock, wallet, audit, notificaciones) idéntico a sql/398.

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
-- VERIFICACIONES (ejecutar separado, después del COMMIT)
-- ════════════════════════════════════════════════════════════════════

-- V1: Columna payment_method existe con valor correcto
SELECT
  COUNT(*) FILTER (WHERE column_name = 'payment_method') > 0  AS col_payment_method_existe,
  data_type                                                     AS tipo
FROM information_schema.columns
WHERE table_schema = 'public'
  AND table_name   = 'extra_hours'
  AND column_name  = 'payment_method'
GROUP BY data_type;
-- Esperado: true | character varying  (o text)

-- V2: Status constraint incluye 'pending_payment' y NO incluye typos
SELECT
  pg_get_constraintdef(c.oid) LIKE '%pending_payment%' AS incluye_pending_payment,
  pg_get_constraintdef(c.oid) LIKE '%paid%'            AS incluye_paid,
  pg_get_constraintdef(c.oid)                           AS constraint_completo
FROM   pg_constraint c
JOIN   pg_class      t ON t.oid = c.conrelid
WHERE  t.relname    = 'extra_hours'
  AND  c.conname    = 'extra_hours_status_check';
-- Esperado: true | true | (ver texto completo)

-- V3: RPC group_accept_extra_hour_stripe existe y es SECURITY DEFINER
SELECT
  p.proname          AS funcion,
  p.prosecdef        AS security_definer,
  n.nspname          AS schema
FROM   pg_proc p
JOIN   pg_namespace n ON n.oid = p.pronamespace
WHERE  n.nspname = 'public'
  AND  p.proname = 'group_accept_extra_hour_stripe';
-- Esperado: group_accept_extra_hour_stripe | true | public

-- V4: confirm_extra_hour_stripe_payment ya NO valida 'awaiting_group_confirmation'
--     y SÍ valida 'pending_payment'
SELECT
  routine_definition LIKE '%pending_payment%'              AS valida_pending_payment,
  routine_definition NOT LIKE '%awaiting_group_confirmation%' AS no_valida_awaiting,
  routine_definition LIKE '%extra_hour_approved_by_client%' AS notifica_grupo,
  routine_definition LIKE '%extra_hour_payment_confirmed%'  AS notifica_cliente
FROM information_schema.routines
WHERE routine_schema = 'public'
  AND routine_name   = 'confirm_extra_hour_stripe_payment';
-- Esperado: true | true | true | true
