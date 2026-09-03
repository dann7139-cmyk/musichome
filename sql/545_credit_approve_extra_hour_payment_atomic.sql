-- ============================================================
-- sql/545_credit_approve_extra_hour_payment_atomic.sql
--
-- BUG CONFIRMADO (auditoría 2026-08-09): approve_extra_hour_payment_atomic
-- descuenta reservations.client_available_balance con éxito (débito real,
-- confirmado, sin errores de esquema) pero nunca acredita group_wallets ni
-- wallets del admin — no por columnas rotas, sino porque la función nunca
-- incluyó ese paso desde su creación (sql/183/353/354). Reachability
-- confirmada: ExtraHoursScreen.tsx (botón real en EventTimerScreen) →
-- trigger trg_notify_extra_hour_proposed → notificación con ruteo correcto
-- a ClientExtraHoursScreen.tsx → este RPC. Camino 100% alcanzable con uso
-- normal de la app, sin ningún estado especial. extra_hours = 0 filas en
-- producción — sin impacto histórico, riesgo puramente prospectivo pero
-- activo.
--
-- CORRECCIÓN (alcance exacto autorizado):
--   Fusiona el crédito (grupo + comisión admin) DENTRO del branch
--   NOT is_cash_payment, en la misma transacción que el débito al
--   cliente — antes de marcar extra_hours='paid' queda todo en el mismo
--   bloque; si el crédito falla, TODO se revierte (incluido el débito),
--   porque esta función NO tiene EXCEPTION WHEN OTHERS — cualquier
--   RAISE EXCEPTION aborta la transacción completa de Postgres.
--
--   Monto: exactamente el ya persistido en extra_hours
--   (group_extra_earnings para el grupo, total_extra_cost menos ese
--   valor para Daricefy) — SIN recalcular el modelo de comisión.
--
--   Moneda: extra_hours.currency_code, con guard fail-closed. Usa
--   RAISE EXCEPTION (no RETURN jsonb ok:false) porque
--   ClientExtraHoursScreen.tsx —sin cambios en esta ronda— solo revisa
--   `error` de la respuesta del RPC, no `data.ok`; un RETURN ok:false
--   pasaría desapercibido para el usuario.
--
--   El flujo is_cash_payment=true queda BYTE IDÉNTICO — efectivo nunca
--   toca ningún wallet (el grupo ya recibe el dinero en mano).
--
--   Sin escritura a financial_ledger — se mantiene financial_audit_logs
--   exactamente como estaba.
--
-- NO CAMBIA:
--   - auth.uid() = reservations.client_id (autorización intacta).
--   - Locks FOR UPDATE sobre extra_hours y reservations (sin cambios).
--   - Guard de idempotencia status='paid' → skipped (sin cambios).
--   - ExtraHoursScreen.tsx (10%/20%, currency_code faltante en su
--     INSERT) — documentado como hallazgo separado, no tocado aquí.
--   - ClientExtraHoursScreen.tsx — sin ningún cambio de archivo.
-- ============================================================

BEGIN;

CREATE OR REPLACE FUNCTION public.approve_extra_hour_payment_atomic(p_extra_hour_id uuid)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE
  v_extra          RECORD;
  v_reservation    RECORD;
  v_caller_id      UUID    := auth.uid();
  v_before_balance NUMERIC;
  v_after_balance  NUMERIC;
  v_action         TEXT;
  v_group_owner_id UUID;
  v_gw             RECORD;
  v_admin_id       UUID;
  v_group_amount   NUMERIC(12,2);
  v_admin_amount   NUMERIC(12,2);
  v_gw_bal_after   NUMERIC(14,2);
BEGIN
  IF v_caller_id IS NULL THEN
    RAISE EXCEPTION 'unauthorized: sesión requerida';
  END IF;

  SELECT * INTO v_extra
  FROM   public.extra_hours
  WHERE  id = p_extra_hour_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Hora extra no encontrada: %', p_extra_hour_id;
  END IF;

  IF v_extra.status = 'paid' THEN
    RETURN jsonb_build_object('ok', true, 'skipped', true, 'reason', 'already_paid');
  END IF;

  IF v_extra.status = 'rejected' THEN
    RAISE EXCEPTION 'Esta hora extra fue rechazada y no puede aprobarse';
  END IF;

  SELECT * INTO v_reservation
  FROM   public.reservations
  WHERE  id = v_extra.reservation_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Reserva no encontrada para esta hora extra';
  END IF;

  IF v_reservation.client_id != v_caller_id THEN
    RAISE EXCEPTION 'unauthorized: solo el cliente de la reserva puede aprobar horas extra';
  END IF;

  SELECT owner_id INTO v_group_owner_id
  FROM   public.groups
  WHERE  id = v_reservation.group_id;

  v_before_balance := COALESCE(v_reservation.client_available_balance, 0);

  IF v_extra.is_cash_payment THEN
    UPDATE public.extra_hours SET status = 'paid' WHERE id = p_extra_hour_id;
    v_after_balance := v_before_balance;
    v_action        := 'extra_approved_cash';
  ELSE
    -- Moneda real de la hora extra — fail-closed, sin fallback silencioso.
    -- RAISE EXCEPTION (no RETURN) porque el frontend solo revisa `error`.
    IF v_extra.currency_code IS NULL OR v_extra.currency_code NOT IN ('MXN', 'USD') THEN
      RAISE EXCEPTION 'unsupported_currency: %', v_extra.currency_code;
    END IF;

    IF v_before_balance < COALESCE(v_extra.total_extra_cost, 0) THEN
      RAISE EXCEPTION 'Saldo insuficiente: disponible=$%, requerido=$%',
        v_before_balance, v_extra.total_extra_cost;
    END IF;

    UPDATE public.extra_hours
    SET    status = 'paid'
    WHERE  id = p_extra_hour_id;

    UPDATE public.reservations
    SET    client_available_balance =
             GREATEST(0, COALESCE(client_available_balance, 0) - COALESCE(v_extra.total_extra_cost, 0))
    WHERE  id = v_reservation.id
    RETURNING client_available_balance INTO v_after_balance;

    -- ── Acreditar al grupo (bucket según moneda, nunca mezclado) ──────
    v_group_amount := COALESCE(v_extra.group_extra_earnings, 0);
    v_admin_amount := COALESCE(v_extra.total_extra_cost, 0) - v_group_amount;

    PERFORM public.ensure_group_wallet(v_reservation.group_id);
    SELECT * INTO v_gw FROM public.group_wallets WHERE group_id = v_reservation.group_id FOR UPDATE;

    IF v_extra.currency_code = 'USD' THEN
      v_gw_bal_after := COALESCE(v_gw.available_balance_usd, 0) + v_group_amount;
      UPDATE public.group_wallets
      SET available_balance_usd = v_gw_bal_after,
          total_earned_usd      = COALESCE(total_earned_usd, 0) + v_group_amount,
          updated_at            = NOW()
      WHERE id = v_gw.id;
    ELSE
      v_gw_bal_after := COALESCE(v_gw.available_balance, 0) + v_group_amount;
      UPDATE public.group_wallets
      SET available_balance = v_gw_bal_after,
          total_earned      = COALESCE(total_earned, 0) + v_group_amount,
          updated_at        = NOW()
      WHERE id = v_gw.id;
    END IF;

    INSERT INTO public.wallet_transactions
      (group_wallet_id, group_id, type, amount, reservation_id, description, balance_after, currency_code)
    VALUES
      (v_gw.id, v_reservation.group_id, 'extra_hour', v_group_amount, v_reservation.id,
       'Ganancia hora extra (aprobada por cliente) · reserva ' || v_reservation.id::TEXT,
       v_gw_bal_after, v_extra.currency_code);

    -- ── Comisión Daricefy (wallets admin — directo a available, sin pending) ──
    v_admin_id := public.get_platform_admin_id();
    IF v_admin_id IS NOT NULL THEN
      INSERT INTO public.wallets (user_id) VALUES (v_admin_id) ON CONFLICT (user_id) DO NOTHING;

      IF v_extra.currency_code = 'USD' THEN
        UPDATE public.wallets
        SET available_balance_usd = COALESCE(available_balance_usd, 0) + v_admin_amount,
            total_earned_usd      = COALESCE(total_earned_usd, 0) + v_admin_amount,
            updated_at            = NOW()
        WHERE user_id = v_admin_id;
      ELSE
        UPDATE public.wallets
        SET available_balance = available_balance + v_admin_amount,
            total_earned      = COALESCE(total_earned, 0) + v_admin_amount,
            updated_at        = NOW()
        WHERE user_id = v_admin_id;
      END IF;

      INSERT INTO public.wallet_transactions
        (user_id, type, amount, reservation_id, description, currency_code)
      VALUES
        (v_admin_id, 'commission', v_admin_amount, v_reservation.id,
         'Comisión hora extra (aprobada por cliente) · reserva ' || v_reservation.id::TEXT,
         v_extra.currency_code);
    END IF;

    v_action := 'extra_approved_balance';
  END IF;

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
    p_extra_hour_id,
    v_action,
    v_caller_id,
    'client',
    jsonb_build_object(
      'client_available_balance', v_before_balance,
      'extra_hour_status',        v_extra.status,
      'reservation_id',           v_reservation.id
    ),
    jsonb_build_object(
      'client_available_balance', COALESCE(v_after_balance, v_before_balance),
      'extra_hour_status',        'paid',
      'reservation_id',           v_reservation.id
    ),
    COALESCE(v_extra.total_extra_cost, 0),
    CASE v_action
      WHEN 'extra_approved_cash'    THEN 'Hora extra aprobada (efectivo) · reserva ' || v_reservation.id::TEXT
      WHEN 'extra_approved_balance' THEN 'Hora extra aprobada (saldo) · reserva '   || v_reservation.id::TEXT
    END
  );

  IF v_extra.is_cash_payment THEN

    IF v_group_owner_id IS NOT NULL THEN
      INSERT INTO public.notifications (user_id, type, title, body, data)
      VALUES (
        v_group_owner_id,
        'extra_hour_approved_by_client',
        '✅ Cliente acordó hora extra en efectivo',
        'El cliente acordó pago en efectivo de $' ||
          COALESCE(v_extra.total_extra_cost, 0)::TEXT ||
          ' MXN. Confirma cuando lo recibas.',
        jsonb_build_object(
          'screen',         'EventTimer',
          'reservation_id', v_reservation.id,
          'extra_hour_id',  p_extra_hour_id
        )
      );
    END IF;

    INSERT INTO public.notifications (user_id, type, title, body, data)
    VALUES (
      v_caller_id,
      'reservation',
      '💵 Hora extra — pago en efectivo',
      'Acordaste pagar $' || COALESCE(v_extra.total_extra_cost, 0)::TEXT ||
        ' MXN en efectivo al grupo. No se descontó de tu saldo.',
      jsonb_build_object(
        'screen',         'ClientExtraHours',
        'reservation_id', v_reservation.id,
        'extra_hour_id',  p_extra_hour_id
      )
    );

  ELSE

    IF v_group_owner_id IS NOT NULL THEN
      INSERT INTO public.notifications (user_id, type, title, body, data)
      VALUES (
        v_group_owner_id,
        'extra_hour_approved_by_client',
        '✅ Cliente aprobó hora extra',
        'El cliente aprobó y pagó ' || COALESCE(v_extra.hours_added, 1)::TEXT ||
          'h extra ($' || COALESCE(v_extra.total_extra_cost, 0)::TEXT ||
          ' MXN). Confirma para continuar el evento.',
        jsonb_build_object(
          'screen',         'EventTimer',
          'reservation_id', v_reservation.id,
          'extra_hour_id',  p_extra_hour_id
        )
      );
    END IF;

    INSERT INTO public.notifications (user_id, type, title, body, data)
    VALUES (
      v_caller_id,
      'extra_hour_payment_confirmed',
      '💳 Cobro confirmado',
      'Se descontaron $' || COALESCE(v_extra.total_extra_cost, 0)::TEXT ||
        ' MXN de tu saldo por ' || COALESCE(v_extra.hours_added, 1)::TEXT ||
        'h extra. Saldo restante: $' ||
        COALESCE(v_after_balance, 0)::TEXT || ' MXN.',
      jsonb_build_object(
        'screen',         'ClientExtraHours',
        'reservation_id', v_reservation.id,
        'extra_hour_id',  p_extra_hour_id
      )
    );

  END IF;

  RETURN jsonb_build_object(
    'ok',             true,
    'skipped',        false,
    'is_cash',        v_extra.is_cash_payment,
    'amount',         COALESCE(v_extra.total_extra_cost, 0),
    'before_balance', v_before_balance,
    'after_balance',  COALESCE(v_after_balance, v_before_balance)
  );
END;
$function$;

COMMIT;

-- ════════════════════════════════════════════════════════════════════
-- VERIFICACIONES (ejecutar separado después del COMMIT)
-- ════════════════════════════════════════════════════════════════════

-- V1: firma sin cambios
SELECT COUNT(*) = 1 AS firma_correcta
FROM   pg_proc p
JOIN   pg_namespace n ON n.oid = p.pronamespace
WHERE  n.nspname = 'public'
  AND  p.proname = 'approve_extra_hour_payment_atomic'
  AND  pg_get_function_identity_arguments(p.oid) = 'p_extra_hour_id uuid';
-- Esperado: true

-- V2: SECURITY DEFINER
SELECT prosecdef FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'public' AND p.proname = 'approve_extra_hour_payment_atomic';
-- Esperado: true

-- V3: contiene el guard de moneda, usa el monto persistido, soporta bucket USD,
-- sigue sin financial_ledger, sigue sin RETURN-based error (usa RAISE EXCEPTION)
SELECT
  routine_definition LIKE '%unsupported_currency%'    AS tiene_guard_moneda,
  routine_definition LIKE '%RAISE EXCEPTION%unsupported_currency%' AS guard_usa_raise,
  routine_definition NOT LIKE '%financial_ledger%'     AS sin_financial_ledger,
  routine_definition LIKE '%group_extra_earnings%'     AS usa_monto_persistido,
  routine_definition LIKE '%available_balance_usd%'    AS soporta_bucket_usd
FROM information_schema.routines
WHERE routine_schema = 'public' AND routine_name = 'approve_extra_hour_payment_atomic';
-- Esperado: true | true | true | true | true

-- V4: autorización y flujo cash sin cambios
SELECT
  routine_definition LIKE '%solo el cliente de la reserva puede aprobar%' AS mantiene_guard_client,
  routine_definition LIKE '%extra_approved_cash%'                         AS mantiene_flujo_cash
FROM information_schema.routines
WHERE routine_schema = 'public' AND routine_name = 'approve_extra_hour_payment_atomic';
-- Esperado: true | true

SELECT '545_credit_approve_extra_hour_payment_atomic ✅' AS status;
