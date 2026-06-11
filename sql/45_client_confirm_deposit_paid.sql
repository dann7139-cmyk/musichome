-- ══════════════════════════════════════════════════════════════════════════════
-- 45_client_confirm_deposit_paid.sql
-- RPC que el cliente llama después de que Stripe confirma el pago exitoso.
-- Actualiza payment_status a 'deposit_paid' directamente, sin depender del webhook.
-- Notifica al dueño del grupo Y a todos los integrantes confirmados.
-- Ejecutar en Supabase SQL Editor.
-- ══════════════════════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION public.client_confirm_deposit_paid(p_reservation_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_group_id    uuid;
  v_event_date  text;
  v_group_name  text;
  v_member_id   uuid;
BEGIN
  -- 1. Actualizar payment_status si la reserva pertenece al cliente
  UPDATE public.reservations
  SET payment_status = 'deposit_paid'
  WHERE id          = p_reservation_id
    AND client_id   = auth.uid()
    AND status      IN ('accepted', 'confirmed')
    AND (payment_status IS NULL OR payment_status = 'deposit_pending');

  -- 2. Obtener datos de la reserva
  SELECT r.group_id, r.event_date, g.name
  INTO v_group_id, v_event_date, v_group_name
  FROM public.reservations r
  LEFT JOIN groups g ON g.id = r.group_id
  WHERE r.id = p_reservation_id;

  IF v_group_id IS NULL THEN RETURN; END IF;

  -- 3. Notificar a todos los que tienen fila en reservation_member_confirmations
  --    (incluye dueño + integrantes confirmados)
  FOR v_member_id IN
    SELECT DISTINCT user_id
    FROM reservation_member_confirmations
    WHERE reservation_id = p_reservation_id
  LOOP
    INSERT INTO notifications (user_id, type, title, message, reference_id)
    VALUES (
      v_member_id,
      'reservation',
      '💰 ¡Anticipo pagado!',
      'El cliente pagó el anticipo del 50% para el evento del ' ||
        COALESCE(v_event_date, 'fecha pendiente') ||
        '. Revisa tu reserva en el panel.',
      p_reservation_id
    );
  END LOOP;
END;
$$;

GRANT EXECUTE ON FUNCTION public.client_confirm_deposit_paid(uuid) TO authenticated;

SELECT 'client_confirm_deposit_paid creado ✅' AS status;
