-- ══════════════════════════════════════════════════════════════════════════════
-- 46_fix_stuck_payment.sql
-- Busca automáticamente la reserva atascada en deposit_pending,
-- la actualiza a deposit_paid y envía notificaciones a todos los integrantes.
-- Ejecutar UNA SOLA VEZ en Supabase SQL Editor.
-- ══════════════════════════════════════════════════════════════════════════════

DO $$
DECLARE
  v_res_id     uuid;
  v_event_date text;
  v_member_id  uuid;
  v_count      int := 0;
BEGIN

  -- 1. Encontrar la reserva más reciente atascada en deposit_pending
  SELECT id, event_date
  INTO v_res_id, v_event_date
  FROM reservations
  WHERE payment_status = 'deposit_pending'
  ORDER BY created_at DESC
  LIMIT 1;

  IF v_res_id IS NULL THEN
    RAISE NOTICE '✅ No hay reservas atascadas en deposit_pending.';
    RETURN;
  END IF;

  RAISE NOTICE 'Reserva encontrada: %', v_res_id;

  -- 2. Actualizar a deposit_paid
  UPDATE reservations
  SET payment_status = 'deposit_paid'
  WHERE id = v_res_id;

  RAISE NOTICE '✅ payment_status actualizado a deposit_paid';

  -- 3. Notificar a todos los integrantes y dueño del grupo
  FOR v_member_id IN
    SELECT DISTINCT user_id
    FROM reservation_member_confirmations
    WHERE reservation_id = v_res_id
  LOOP
    INSERT INTO notifications (user_id, type, title, message, reference_id)
    VALUES (
      v_member_id,
      'reservation',
      '💰 ¡Anticipo pagado!',
      'El cliente pagó el anticipo del 50% para el evento del ' ||
        COALESCE(v_event_date, 'fecha pendiente') ||
        '. Revisa tu reserva en el panel.',
      v_res_id
    );
    v_count := v_count + 1;
  END LOOP;

  RAISE NOTICE '✅ Notificaciones enviadas a % persona(s)', v_count;

END;
$$;

SELECT 'Script ejecutado — revisa los NOTICE de arriba para ver el resultado ✅' AS status;
