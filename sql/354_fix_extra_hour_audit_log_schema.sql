-- ════════════════════════════════════════════════════════════════════
-- sql/354_fix_extra_hour_audit_log_schema.sql
--
-- BUG CRÍTICO: approve_extra_hour_payment_atomic (sql/183 y sql/353)
-- usaba columnas que no existen en financial_audit_logs de producción:
--   before_balance, after_balance, reservation_id, extra_hour_id
--
-- El schema real de producción es:
--   entity_type TEXT, entity_id UUID, action TEXT, actor_id UUID,
--   actor_role TEXT, before_state JSONB, after_state JSONB,
--   amount NUMERIC, notes TEXT, created_at TIMESTAMPTZ
--
-- Impacto: cualquier aprobación de hora extra fallaba con error 42703
-- (column does not exist) y hacía rollback de toda la transacción,
-- dejando extra_hours.status sin cambiar y saldo sin descontar.
-- Con 0 extras en producción no había daño real, pero era una bomba.
--
-- Fix: reescritura completa de approve_extra_hour_payment_atomic con
-- el INSERT correcto y las notificaciones de sql/353.
-- ════════════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION public.approve_extra_hour_payment_atomic(
  p_extra_hour_id UUID
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_extra          RECORD;
  v_reservation    RECORD;
  v_caller_id      UUID    := auth.uid();
  v_before_balance NUMERIC;
  v_after_balance  NUMERIC;
  v_action         TEXT;
  v_group_owner_id UUID;
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

  -- Dueño del grupo para notificación
  SELECT owner_id INTO v_group_owner_id
  FROM   public.groups
  WHERE  id = v_reservation.group_id;

  v_before_balance := COALESCE(v_reservation.client_available_balance, 0);

  IF v_extra.is_cash_payment THEN
    UPDATE public.extra_hours SET status = 'paid' WHERE id = p_extra_hour_id;
    v_after_balance := v_before_balance;
    v_action        := 'extra_approved_cash';
  ELSE
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

    v_action := 'extra_approved_balance';
  END IF;

  -- ── Auditoría con schema real de financial_audit_logs ────────────────────
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

  -- ── Notificaciones (de sql/353, intactas) ────────────────────────────────
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
$$;

GRANT EXECUTE ON FUNCTION public.approve_extra_hour_payment_atomic(UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION public.approve_extra_hour_payment_atomic(UUID) TO service_role;

SELECT '354_fix_extra_hour_audit_log_schema.sql ejecutado ✅' AS status;

-- ── Verificación ──────────────────────────────────────────────────────────────

-- Confirma que la función ya no referencia columnas inexistentes
-- Esperado: false (no menciona 'before_balance'), true (sí menciona 'before_state')
SELECT
  routine_definition LIKE '%before_balance%' AS usa_columna_vieja,
  routine_definition LIKE '%before_state%'   AS usa_columna_correcta
FROM information_schema.routines
WHERE routine_schema = 'public'
  AND routine_name   = 'approve_extra_hour_payment_atomic';

-- Query corregido para Bug #7 — con el schema real
-- (Con 0 extras en producción devolverá total_logs_extras=0, lo cual es correcto)
SELECT
  COUNT(*)                                      AS total_logs_extras,
  COALESCE(COUNT(before_state) > 0, false)      AS guarda_before_state,
  COALESCE(COUNT(after_state)  > 0, false)      AS guarda_after_state
FROM public.financial_audit_logs
WHERE action IN ('extra_approved_balance', 'extra_approved_cash');
