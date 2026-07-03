-- ════════════════════════════════════════════════════════════════════
-- sql/399 — RPCs de liberación de pago de horas extra (modelo 50/50)
--
-- release_extra_hours_partial — llamada desde EventTimerScreen cuando
--   el timer cruza el tiempo contractual original y hay extras 'paid'.
--   Libera 50% de group_extra_earnings → available_balance.
--   Marca payout_status = 'half_released'.
--
-- release_extra_hours_final — llamada desde finishEvent().
--   Si payout_status='half_released': libera el otro 50%.
--   Si payout_status='held' (partial omitida por crash/no red): libera 100%.
--   Marca payout_status = 'released'.
--   Notifica al grupo del payout final.
--
-- Ambas son idempotentes: si payout_status ya no es 'held'/'half_released',
-- la operación retorna sin modificar nada.
--
-- Locking order: group_wallets primero → extra_hours (SKIP LOCKED).
-- El SKIP LOCKED es el mecanismo anti-deadlock frente a
-- confirm_extra_hour_stripe_payment que puede correr concurrentemente.
-- ════════════════════════════════════════════════════════════════════

BEGIN;

DROP FUNCTION IF EXISTS public.release_extra_hours_partial(UUID);
DROP FUNCTION IF EXISTS public.release_extra_hours_final(UUID);

-- ─────────────────────────────────────────────────────────────────
-- release_extra_hours_partial
-- ─────────────────────────────────────────────────────────────────

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
  v_wallet    RECORD;
  v_extra     RECORD;
  v_half      NUMERIC(12,2);
  v_released  INTEGER := 0;
  v_skipped   INTEGER := 0;
BEGIN
  -- ── Obtener group_id ──────────────────────────────────────────────
  SELECT r.group_id
  INTO   v_group_id
  FROM   public.reservations r
  WHERE  r.id = p_reservation_id;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'reservation_not_found');
  END IF;

  -- ── Lock group_wallet primero (orden de locks consistente) ────────
  SELECT *
  INTO   v_wallet
  FROM   public.group_wallets
  WHERE  group_id = v_group_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'wallet_not_found');
  END IF;

  -- ── Iterar extras elegibles ───────────────────────────────────────
  FOR v_extra IN
    SELECT *
    FROM   public.extra_hours
    WHERE  reservation_id = p_reservation_id
      AND  status         = 'paid'
      AND  payout_status  = 'held'
    FOR UPDATE SKIP LOCKED
  LOOP
    v_half := ROUND(COALESCE(v_extra.group_extra_earnings, 0) * 0.5, 2);

    -- Mover 50% pending → available
    UPDATE public.group_wallets
    SET
      pending_balance   = GREATEST(0, COALESCE(pending_balance,   0) - v_half),
      available_balance = COALESCE(available_balance, 0) + v_half,
      updated_at        = NOW()
    WHERE group_id = v_group_id
    RETURNING available_balance INTO v_wallet.available_balance;

    UPDATE public.extra_hours
    SET
      payout_status    = 'half_released',
      half_released_at = NOW()
    WHERE id = v_extra.id;

    INSERT INTO public.wallet_transactions (
      group_wallet_id, group_id, type, amount,
      reservation_id,  description, balance_after
    ) VALUES (
      v_wallet.id, v_group_id, 'credit_available', v_half,
      p_reservation_id,
      'Hora extra — liberación parcial 50% (inicio extras)',
      v_wallet.available_balance
    );

    INSERT INTO public.financial_audit_logs (
      entity_type, entity_id, action, actor_id, actor_role,
      before_state, after_state, amount, notes
    ) VALUES (
      'extra_hour', v_extra.id, 'partial_release', auth.uid(), 'system',
      jsonb_build_object('payout_status', 'held'),
      jsonb_build_object('payout_status', 'half_released'),
      v_half,
      '50% liberado al iniciar horas extra'
    );

    v_released := v_released + 1;
  END LOOP;

  -- Contar omitidas (ya procesadas o no hay)
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

-- ─────────────────────────────────────────────────────────────────
-- release_extra_hours_final
-- ─────────────────────────────────────────────────────────────────

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
  v_owner_id       UUID;
  v_wallet         RECORD;
  v_extra          RECORD;
  v_amount         NUMERIC(12,2);
  v_label          TEXT;
  v_released       INTEGER        := 0;
  v_total_released NUMERIC(12,2)  := 0;
BEGIN
  -- ── Obtener group_id ──────────────────────────────────────────────
  SELECT r.group_id
  INTO   v_group_id
  FROM   public.reservations r
  WHERE  r.id = p_reservation_id;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'reservation_not_found');
  END IF;

  -- ── Lock group_wallet primero ─────────────────────────────────────
  SELECT *
  INTO   v_wallet
  FROM   public.group_wallets
  WHERE  group_id = v_group_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', true, 'released', 0, 'reason', 'no_wallet');
  END IF;

  -- Obtener owner_id para notificación (sin lock en groups)
  SELECT g.owner_id
  INTO   v_owner_id
  FROM   public.groups g
  WHERE  g.id = v_group_id;

  -- ── Iterar extras: held (100%) o half_released (50% restante) ────
  FOR v_extra IN
    SELECT *
    FROM   public.extra_hours
    WHERE  reservation_id = p_reservation_id
      AND  status         = 'paid'
      AND  payout_status  IN ('held', 'half_released')
    FOR UPDATE SKIP LOCKED
  LOOP
    IF v_extra.payout_status = 'held' THEN
      -- Partial nunca corrió (crash / sin red): liberar 100%
      v_amount := ROUND(COALESCE(v_extra.group_extra_earnings, 0), 2);
      v_label  := 'Hora extra — liberación total (partial omitida)';
    ELSE
      -- Liberar el 50% restante
      v_amount := ROUND(COALESCE(v_extra.group_extra_earnings, 0) * 0.5, 2);
      v_label  := 'Hora extra — liberación final 50% restante';
    END IF;

    UPDATE public.group_wallets
    SET
      pending_balance   = GREATEST(0, COALESCE(pending_balance,   0) - v_amount),
      available_balance = COALESCE(available_balance, 0) + v_amount,
      updated_at        = NOW()
    WHERE group_id = v_group_id
    RETURNING available_balance INTO v_wallet.available_balance;

    UPDATE public.extra_hours
    SET
      payout_status = 'released',
      released_at   = NOW()
    WHERE id = v_extra.id;

    INSERT INTO public.wallet_transactions (
      group_wallet_id, group_id, type, amount,
      reservation_id,  description, balance_after
    ) VALUES (
      v_wallet.id, v_group_id, 'credit_available', v_amount,
      p_reservation_id, v_label, v_wallet.available_balance
    );

    INSERT INTO public.financial_audit_logs (
      entity_type, entity_id, action, actor_id, actor_role,
      before_state, after_state, amount, notes
    ) VALUES (
      'extra_hour', v_extra.id, 'final_release', auth.uid(), 'system',
      jsonb_build_object('payout_status', v_extra.payout_status),
      jsonb_build_object('payout_status', 'released'),
      v_amount,
      v_label
    );

    v_total_released := v_total_released + v_amount;
    v_released       := v_released + 1;
  END LOOP;

  -- ── Notificar al grupo del payout final ───────────────────────────
  IF v_released > 0 AND v_owner_id IS NOT NULL THEN
    INSERT INTO public.notifications (user_id, type, title, body, data)
    VALUES (
      v_owner_id,
      'payment_released',
      '💸 Ganancias de extras disponibles',
      '$' || ROUND(v_total_released)::TEXT ||
        ' MXN de horas extra están listos para retiro.',
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

-- V1: Ambas funciones existen
SELECT
  COUNT(*) FILTER (WHERE p.proname = 'release_extra_hours_partial') > 0 AS partial_existe,
  COUNT(*) FILTER (WHERE p.proname = 'release_extra_hours_final')   > 0 AS final_existe
FROM   pg_proc p
JOIN   pg_namespace n ON n.oid = p.pronamespace
WHERE  n.nspname = 'public'
  AND  p.proname IN ('release_extra_hours_partial', 'release_extra_hours_final');
-- Esperado: true | true

-- V2: Ambas son SECURITY DEFINER
SELECT p.proname, p.prosecdef AS is_security_definer
FROM   pg_proc p
JOIN   pg_namespace n ON n.oid = p.pronamespace
WHERE  n.nspname = 'public'
  AND  p.proname IN ('release_extra_hours_partial', 'release_extra_hours_final');
-- Esperado: ambas con is_security_definer = true

-- V3: release_extra_hours_final maneja 'held' (100%) y 'half_released' (50%)
SELECT
  routine_definition LIKE '%payout_status = ''held''%'   AS maneja_held_100pct,
  routine_definition LIKE '%half_released%'               AS maneja_half_50pct,
  routine_definition LIKE '%payment_released%'            AS notifica_grupo
FROM information_schema.routines
WHERE routine_schema = 'public'
  AND routine_name   = 'release_extra_hours_final';
-- Esperado: true | true | true

-- V4: wallet_transactions usa 'credit_available' (no 'extra_hour') en ambas
SELECT
  (SELECT routine_definition FROM information_schema.routines
   WHERE  routine_schema = 'public' AND routine_name = 'release_extra_hours_partial')
   LIKE '%credit_available%' AS partial_usa_credit_available,
  (SELECT routine_definition FROM information_schema.routines
   WHERE  routine_schema = 'public' AND routine_name = 'release_extra_hours_final')
   LIKE '%credit_available%' AS final_usa_credit_available;
-- Esperado: true | true
