-- ══════════════════════════════════════════════════════════════════════════════
-- 44_fix_confirmation_notification.sql
-- Actualiza confirm_member_attendance para que la notificación al cliente
-- le indique claramente que debe pagar el anticipo del 50% para confirmar su lugar.
-- Ejecutar en Supabase SQL Editor.
-- ══════════════════════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION confirm_member_attendance(
  p_reservation_id uuid,
  p_status         text   -- 'confirmed' | 'declined'
) RETURNS void LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_total      int;
  v_confirmed  int;
  v_client_id  uuid;
  v_event_date text;
  v_res_status text;
  v_group_name text;
BEGIN
  -- 1. Actualizar la fila del usuario actual
  UPDATE reservation_member_confirmations
  SET status       = p_status,
      confirmed_at = CASE WHEN p_status = 'confirmed' THEN now() ELSE NULL END
  WHERE reservation_id = p_reservation_id
    AND user_id = auth.uid();

  -- 2. Sólo si el usuario confirmó (no declinó), checar si todos confirmaron
  IF p_status = 'confirmed' THEN
    SELECT COUNT(*) INTO v_total
    FROM reservation_member_confirmations
    WHERE reservation_id = p_reservation_id;

    SELECT COUNT(*) INTO v_confirmed
    FROM reservation_member_confirmations
    WHERE reservation_id = p_reservation_id
      AND status = 'confirmed';

    -- 3. Si todos confirman → reserva confirmada
    IF v_total > 0 AND v_confirmed = v_total THEN
      SELECT r.status, r.client_id, r.event_date, g.name
      INTO v_res_status, v_client_id, v_event_date, v_group_name
      FROM reservations r
      JOIN groups g ON g.id = r.group_id
      WHERE r.id = p_reservation_id;

      IF v_res_status IN ('pending', 'pending_group_confirmation', 'pending_payment') THEN
        UPDATE reservations
        SET status = 'confirmed'
        WHERE id = p_reservation_id;

        -- 4. Notificar al cliente: indicar que debe pagar el anticipo
        IF v_client_id IS NOT NULL THEN
          INSERT INTO notifications (user_id, type, title, message, reference_id)
          VALUES (
            v_client_id,
            'reservation',
            '✅ ¡Reserva confirmada! Paga el anticipo',
            '¡Buenas noticias! ' || COALESCE(v_group_name, 'El grupo') ||
            ' confirmó tu reserva para el ' || v_event_date ||
            '. Para asegurar tu lugar, entra a "Mis Reservas" y paga el anticipo del 50%. ¡No pierdas tu fecha! 🎶',
            p_reservation_id
          );
        END IF;
      END IF;
    END IF;
  END IF;
END;
$$;

SELECT 'confirm_member_attendance actualizado: notificación con aviso de anticipo ✅' AS status;
