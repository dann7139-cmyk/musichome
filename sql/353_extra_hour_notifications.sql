-- ════════════════════════════════════════════════════════════════════
-- sql/353_extra_hour_notifications.sql
--
-- Ronda 2 — Notificaciones faltantes en flujo de horas extra.
--
-- Bugs resueltos:
--   #3 — Cuando el grupo inserta en extra_hours, el cliente no recibía
--        notificación. Ahora un TRIGGER la dispara en el INSERT.
--   #4 — Cuando el cliente aprueba y paga, el grupo no recibía
--        notificación. Ahora approve_extra_hour_payment_atomic la envía.
--   #5 — El cliente no recibía confirmación de cobro tras aprobar.
--        Ahora approve_extra_hour_payment_atomic la envía.
--
-- Parte A: constraint notifications_type_check + 3 tipos nuevos.
-- Parte B: trigger notify_extra_hour_proposed (INSERT en extra_hours).
-- Parte C: reescritura de approve_extra_hour_payment_atomic con notifs.
--
-- Requiere: sql/352 ejecutado.
-- ════════════════════════════════════════════════════════════════════

-- ── A. Constraint: + 3 tipos de horas extra ──────────────────────────────────

DO $$
BEGIN
  ALTER TABLE public.notifications
    DROP CONSTRAINT IF EXISTS notifications_type_check;

  ALTER TABLE public.notifications
    ADD CONSTRAINT notifications_type_check CHECK (type IN (
      -- Legacy / genéricos
      'reservation', 'payment', 'review', 'verification', 'system',
      'financial', 'admin_alert', 'admin', 'general',
      -- Reservas (booking flow)
      'booking', 'booking_received', 'booking_accepted', 'booking_confirmed',
      'booking_rejected', 'booking_auto_cancelled', 'booking_expired_no_payment',
      'booking_cancelled',
      -- Pagos y wallet
      'deposit_received', 'payment_released', 'payment_received',
      'payment_mismatch', 'payout', 'wallet',
      -- Recordatorios de evento
      'event_reminder_24h', 'event_upcoming_24h',
      'event_reminder_morning', 'event_reminder_1h',
      'event_reminder_3h',    'event_reminder_2h',
      -- Ciclo de vida del evento
      'event_completed', 'event_started', 'overtime_requested',
      'event_auto_started', 'event_no_show_alert',
      -- Disputas
      'dispute_opened', 'dispute_received', 'dispute',
      -- Bolsa de trabajo
      'job_invitation',
      -- Cotizaciones
      'new_quote_request', 'quote_received',
      'quote_accepted',    'quote_cancelled', 'quote_sent_to_client',
      -- Chat
      'chat',
      -- Marketing / visibilidad (grupos)
      'ad_space_available', 'high_demand', 'no_ads_in_city', 'first_ad_reminder',
      -- Anuncios (publicados por grupo)
      'ad_payment_confirmed', 'ad_approved', 'ad_rejected',
      'ad_expiring_soon',     'ad_expired',
      -- Re-engagement (clientes)
      'new_city_groups', 'group_nearby',
      -- Competencia de bids
      'bid_displaced', 'bid_expiring_soon', 'bid_expiry_reminder',
      -- Zona / demanda express
      'zone_demand', 'express_dispatch',
      -- Admin / KYC / anti-fraude
      'fraud_alert', 'referral_reward',
      -- Proximidad al evento (349)
      'request_expired_proximity', 'quote_expired_proximity',
      -- Horas extra (353)
      'extra_hour_proposed',           -- grupo propone → cliente
      'extra_hour_approved_by_client', -- cliente aprueba → grupo
      'extra_hour_payment_confirmed'   -- cobro descontado → cliente
    )) NOT VALID;

  RAISE NOTICE '[353] notifications_type_check recreado con 60 tipos ✅';
END;
$$;

-- ── B. Trigger: notificar al recibir INSERT en extra_hours ────────────────────
--
-- 'pending'                    → grupo propuso → notificar al CLIENTE.
-- 'awaiting_group_confirmation'→ cliente solicitó → notificar al GRUPO (dueño).
-- Cualquier otro status (ej. 'paid' creado por RPC interna) → no dispara.

CREATE OR REPLACE FUNCTION public.notify_extra_hour_proposed()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_client_id      UUID;
  v_group_owner_id UUID;
BEGIN
  -- Obtener client_id y group owner en un solo query
  SELECT r.client_id, g.owner_id
  INTO   v_client_id, v_group_owner_id
  FROM   public.reservations r
  JOIN   public.groups g ON g.id = r.group_id
  WHERE  r.id = NEW.reservation_id;

  IF NOT FOUND THEN
    RETURN NEW;  -- reserva no encontrada: no bloquear el INSERT
  END IF;

  IF NEW.status = 'pending' THEN
    -- Grupo propuso al cliente
    IF v_client_id IS NOT NULL THEN
      INSERT INTO public.notifications (user_id, type, title, body, data)
      VALUES (
        v_client_id,
        'extra_hour_proposed',
        '⏰ Hora extra propuesta',
        'El grupo propuso ' || NEW.hours_added || 'h extra por $' ||
          NEW.total_extra_cost::TEXT || ' MXN. Revisa y aprueba.',
        jsonb_build_object(
          'screen',         'ClientExtraHours',
          'reservation_id', NEW.reservation_id,
          'extra_hour_id',  NEW.id
        )
      );
    END IF;

  ELSIF NEW.status = 'awaiting_group_confirmation' THEN
    -- Cliente solicitó al grupo
    IF v_group_owner_id IS NOT NULL THEN
      INSERT INTO public.notifications (user_id, type, title, body, data)
      VALUES (
        v_group_owner_id,
        'reservation',
        '⏰ El cliente quiere ' || NEW.hours_added || 'h extra',
        'El cliente solicita ' || NEW.hours_added || 'h extra por $' ||
          NEW.total_extra_cost::TEXT || ' MXN. Confirma para extender el evento.',
        jsonb_build_object(
          'screen',         'EventTimer',
          'reservation_id', NEW.reservation_id,
          'extra_hour_id',  NEW.id
        )
      );
    END IF;
  END IF;

  RETURN NEW;

EXCEPTION WHEN OTHERS THEN
  -- El trigger no debe bloquear el INSERT original
  RAISE WARNING '[353] notify_extra_hour_proposed falló: %', SQLERRM;
  RETURN NEW;
END;
$$;

-- DROP + CREATE para idempotencia al re-ejecutar el SQL
DROP TRIGGER IF EXISTS trg_notify_extra_hour_proposed ON public.extra_hours;

CREATE TRIGGER trg_notify_extra_hour_proposed
  AFTER INSERT ON public.extra_hours
  FOR EACH ROW
  WHEN (NEW.status IN ('pending', 'awaiting_group_confirmation'))
  EXECUTE FUNCTION public.notify_extra_hour_proposed();

-- ── C. approve_extra_hour_payment_atomic — agrega notificaciones ──────────────
--
-- Cambios vs sql/183:
--   1. DECLARE v_group_owner_id UUID
--   2. SELECT group owner después del FOR UPDATE en reservations
--   3. Notificaciones al grupo y al cliente (distintas según cash vs saldo)
--   No cambia: FOR UPDATE, idempotencia, ownership check, audit log.

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
  v_group_owner_id UUID;   -- nuevo: para notificación al grupo
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

  -- Obtener dueño del grupo (para notificación)
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

  -- Auditoría (igual que en sql/183 — no cambia)
  INSERT INTO public.financial_audit_logs (
    actor_id, action, amount, reservation_id, extra_hour_id,
    before_balance, after_balance
  ) VALUES (
    v_caller_id, v_action,
    COALESCE(v_extra.total_extra_cost, 0),
    v_reservation.id, p_extra_hour_id,
    v_before_balance,
    COALESCE(v_after_balance, v_before_balance)
  );

  -- ── Notificaciones (nuevas en 353) ───────────────────────────────────────
  IF v_extra.is_cash_payment THEN

    -- Grupo: el cliente acordó pagar en efectivo
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

    -- Cliente: confirmación de acuerdo en efectivo (sin descuento de saldo)
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

    -- Grupo: el cliente aprobó y ya se descontó el saldo
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

    -- Cliente: confirmación de cobro con saldo restante
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

SELECT '353_extra_hour_notifications.sql ejecutado ✅' AS status;

-- ════════════════════════════════════════════════════════════════════
-- TESTS (ejecutar después del bloque anterior)
-- ════════════════════════════════════════════════════════════════════

-- Test A: constraint tiene los 3 tipos nuevos
-- Esperado: true | true | true
SELECT
  pg_get_constraintdef(c.oid) LIKE '%extra_hour_proposed%'            AS t1,
  pg_get_constraintdef(c.oid) LIKE '%extra_hour_approved_by_client%'  AS t2,
  pg_get_constraintdef(c.oid) LIKE '%extra_hour_payment_confirmed%'   AS t3
FROM pg_constraint c
WHERE c.conname  = 'notifications_type_check'
  AND c.conrelid = 'public.notifications'::regclass;

-- Test B: trigger existe
-- Esperado: 1 fila con tgname = 'trg_notify_extra_hour_proposed'
SELECT tgname
FROM pg_trigger
WHERE tgname = 'trg_notify_extra_hour_proposed';

-- Test C: approve_extra_hour_payment_atomic tiene el tipo nuevo
-- Esperado: true
SELECT routine_definition LIKE '%extra_hour_approved_by_client%' AS tiene_notif_grupo
FROM information_schema.routines
WHERE routine_schema = 'public'
  AND routine_name   = 'approve_extra_hour_payment_atomic';
