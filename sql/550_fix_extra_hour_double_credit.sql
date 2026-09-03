-- ============================================================
-- 550_fix_extra_hour_double_credit.sql
--
-- NOTA DE NUMERACIÓN: este fix se preparó originalmente como "549",
-- pero ese número ya fue tomado por sql/549_start_event_server_clock.sql
-- (aplicado en producción antes que este archivo se terminara de
-- preparar). Se renumera a 550 para no chocar con esa migración ya
-- ejecutada. No se modifica sql/549.
--
-- PROPÓSITO
--   Corregir el doble crédito confirmado en approve_extra_hour_payment_atomic:
--   la función deja extra_hours.status='paid' sin fijar payout_status,
--   que se queda en el default de tabla 'held' — el mismo valor que
--   usan release_extra_hours_partial/release_extra_hours_final como
--   parte de su filtro de selección (`status='paid' AND payout_status
--   IN ('held','half_released')`). Cuando el evento avanza (cruce de
--   horas contratadas, o finalización), esas funciones vuelven a
--   acreditar group_wallets.available_balance con el mismo monto:
--     - Rama SALDO: el dinero ya se acreditó aquí mismo, directo a
--       available_balance → segunda acreditación = DOBLE CRÉDITO real.
--     - Rama EFECTIVO: nunca se acreditó nada (el cliente pagó en mano
--       al grupo) → la "liberación" posterior acredita dinero que la
--       plataforma nunca procesó = CRÉDITO INDEBIDO de primera vez.
--
--   Confirmado que release_extra_hours_partial/_final están activamente
--   conectadas en producción (EventTimerScreen.tsx: se disparan
--   automáticamente al cruzar las horas contratadas y al finalizar el
--   evento) — no es un caso hipotético.
--
-- CAMBIO ÚNICO
--   Agregar `payout_status = 'released'` a los DOS UPDATE de
--   extra_hours dentro de approve_extra_hour_payment_atomic (rama
--   efectivo y rama saldo). Nada más cambia: mismas validaciones,
--   mismos montos, misma autorización, mismas notificaciones, mismo
--   financial_audit_logs. La función se transcribe completa —no
--   abreviada— para que el diff sea auditable línea por línea.
--
-- EXPLÍCITAMENTE FUERA DE ALCANCE
--   - confirm_extra_hour_stripe_payment: CERO cambios. Esa función ya
--     hace lo correcto (acredita pending_balance y fija
--     payout_status='held' explícitamente) — ver nota inline abajo.
--   - group_confirm_extra_hours: tiene la misma causa raíz (nunca fija
--     payout_status) pero no duplica hoy porque deja status='accepted'
--     (no 'paid'), por lo que el filtro de las funciones de liberación
--     no la alcanza. Queda para una ronda separada, ya acordada.
--   - Sin backfill: la auditoría de solo lectura (ver abajo) confirmó
--     0 filas actualmente en riesgo y 0 filas con duplicado ya
--     aplicado — este fix es puramente preventivo hacia adelante.
--
-- SEGURIDAD: PRE-CHECK DE VERSIÓN
--   Antes de reemplazar la función, se verifica que el md5() del
--   código fuente actualmente desplegado coincida EXACTAMENTE con el
--   que se auditó al preparar este fix. Si alguien modificó la función
--   entre la auditoría y esta ejecución, el archivo aborta completo
--   (RAISE EXCEPTION, rollback total) en vez de sobrescribir a ciegas
--   una versión distinta a la esperada.
--
-- NO EJECUTAR hasta autorización explícita. Este archivo se entrega
-- primero para revisión.
-- ============================================================

BEGIN;

-- ── Pre-check: la versión desplegada debe ser EXACTAMENTE la auditada ──
DO $$
DECLARE
  v_current_hash  TEXT;
  v_expected_hash CONSTANT TEXT := '03b5eda62d7e165f64deea78a50958f6';
BEGIN
  SELECT md5(prosrc) INTO v_current_hash
  FROM   pg_proc p
  JOIN   pg_namespace n ON n.oid = p.pronamespace
  WHERE  n.nspname = 'public' AND p.proname = 'approve_extra_hour_payment_atomic';

  IF v_current_hash IS NULL THEN
    RAISE EXCEPTION 'ABORT: approve_extra_hour_payment_atomic no existe en esta base — no se puede aplicar este fix';
  END IF;

  IF v_current_hash <> v_expected_hash THEN
    RAISE EXCEPTION 'ABORT: la definición actual de approve_extra_hour_payment_atomic (md5=%) no coincide con la versión auditada (md5=%). Alguien la modificó desde que se preparó este fix — revisar manualmente antes de reemplazarla.',
      v_current_hash, v_expected_hash;
  END IF;

  RAISE NOTICE 'Pre-check OK: versión desplegada coincide con la auditada (md5=%)', v_current_hash;
END $$;

-- ── Reemplazo: función completa, sin abreviar ──────────────────────────
CREATE OR REPLACE FUNCTION public.approve_extra_hour_payment_atomic(p_extra_hour_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
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

  -- ── NOTA DE ALCANCE: por qué 'released' es correcto aquí y por qué
  -- Stripe (confirm_extra_hour_stripe_payment, función distinta, NO
  -- tocada por este archivo) sigue usando 'held' ────────────────────
  -- confirm_extra_hour_stripe_payment acredita group_wallets.pending_balance
  -- (dinero RETENIDO) y fija payout_status='held' explícitamente,
  -- porque en ese flujo SÍ queda algo pendiente de liberar más tarde
  -- por release_extra_hours_partial/_final. Las dos ramas de ESTA
  -- función (efectivo y saldo) nunca pasan por pending_balance —
  -- o no se acredita nada (efectivo) o se acredita de forma inmediata
  -- y directa a available_balance (saldo) — así que dejarlas en 'held'
  -- (el default de tabla) es incorrecto: hace que las funciones de
  -- liberación las recojan más tarde y acrediten dinero que ya se
  -- acreditó (saldo) o que nunca existió para la plataforma (efectivo).
  IF v_extra.is_cash_payment THEN
    -- payout_status='released': el cliente pagó en efectivo DIRECTO al
    -- grupo — la plataforma nunca recibió ni procesó ese dinero, así
    -- que no hay nada que liberar después. Sin este campo, la fila
    -- quedaría en 'held' y sería recogida más tarde por
    -- release_extra_hours_partial/_final, acreditando a
    -- group_wallets.available_balance dinero que la plataforma nunca
    -- tuvo (crédito indebido, confirmado en la auditoría).
    UPDATE public.extra_hours
    SET    status = 'paid', payout_status = 'released'
    WHERE  id = p_extra_hour_id;
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

    -- payout_status='released': el crédito a group_wallets.available_balance
    -- ocurre AQUÍ MISMO, unas líneas abajo, de forma inmediata y directa
    -- (nunca pasa por pending_balance). Sin este campo, la fila quedaría
    -- en 'held' y sería recogida de nuevo más tarde por
    -- release_extra_hours_partial/_final, acreditando el mismo monto
    -- una segunda vez — el doble crédito confirmado, causa raíz de
    -- este fix.
    UPDATE public.extra_hours
    SET    status = 'paid', payout_status = 'released'
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

-- ============================================================
-- VERIFICACIÓN POST-FIX (ejecutar por separado después del COMMIT,
-- NO se auto-ejecuta — todo lo siguiente está comentado)
-- ============================================================

-- V1: la función debe existir, seguir con la misma firma, y su nuevo
-- código fuente debe contener 'released' en ambas ramas
-- SELECT prosrc LIKE '%is_cash_payment THEN%' AS tiene_rama_efectivo,
--        (SELECT COUNT(*) FROM regexp_matches(prosrc, 'payout_status = ''released''', 'g')) AS ocurrencias_released
-- FROM pg_proc WHERE proname = 'approve_extra_hour_payment_atomic' AND pronamespace='public'::regnamespace;
-- Esperado: tiene_rama_efectivo=true, ocurrencias_released=2

-- V2: confirmar que confirm_extra_hour_stripe_payment NO cambió (mismo
-- hash de antes de este archivo — comparar contra una captura previa)
-- SELECT md5(prosrc) FROM pg_proc
-- WHERE proname = 'confirm_extra_hour_stripe_payment' AND pronamespace='public'::regnamespace;

-- V3: tras la próxima aprobación real (saldo o efectivo) en producción,
-- confirmar que la fila queda payout_status='released' y NUNCA
-- payout_status='held'
-- SELECT id, status, payout_status, is_cash_payment, paid_at
-- FROM extra_hours
-- WHERE status='paid' AND paid_at > NOW() - INTERVAL '1 hour'
-- ORDER BY paid_at DESC;

-- V4: confirmar que release_extra_hours_partial/_final ya NO pueden
-- recoger ninguna fila aprobada por saldo/efectivo (debe seguir en 0,
-- igual que antes del fix — este fix es preventivo, no reduce nada
-- que ya existiera)
-- SELECT COUNT(*) AS at_risk_count
-- FROM extra_hours
-- WHERE status = 'paid' AND payout_status = 'held' AND stripe_payment_id IS NULL;
-- Esperado: 0

SELECT '550_fix_extra_hour_double_credit preparado — NO EJECUTADO' AS status;
