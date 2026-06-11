-- ════════════════════════════════════════════════════════════════════
-- 78_notify_group_on_payment.sql
-- Actualiza simulate_deposit_paid para:
--   1. También transicionar status 'accepted' → 'confirmed' al pagar
--   2. Notificar al dueño del grupo y a todos los integrantes
-- ════════════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION public.simulate_deposit_paid(p_reservation_id UUID)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_group_id    UUID;
  v_event_date  DATE;
  v_address     TEXT;
  v_client_name TEXT;
  v_owner_id    UUID;
BEGIN
  UPDATE public.reservations
  SET
    payment_status = 'deposit_paid',
    status = CASE
      WHEN status IN ('pending', 'accepted') THEN 'confirmed'
      ELSE status
    END
  WHERE id = p_reservation_id
    AND client_id = auth.uid()
  RETURNING group_id, event_date, address
    INTO v_group_id, v_event_date, v_address;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_found');
  END IF;

  -- Nombre del cliente que pagó
  SELECT full_name INTO v_client_name
  FROM public.profiles
  WHERE id = auth.uid();

  -- Dueño del grupo
  SELECT owner_id INTO v_owner_id
  FROM public.groups
  WHERE id = v_group_id;

  -- Notificar al dueño del grupo
  IF v_owner_id IS NOT NULL THEN
    INSERT INTO public.notifications (user_id, type, title, body, data)
    VALUES (
      v_owner_id,
      'booking',
      '💰 ¡El anticipo fue pagado!',
      COALESCE(v_client_name, 'El cliente') || ' pagó el anticipo del evento del ' ||
        TO_CHAR(v_event_date, 'DD/MM/YYYY') ||
        '. Ya puedes ver la dirección exacta.',
      jsonb_build_object(
        'reservation_id', p_reservation_id,
        'screen',         'GroupReservations'
      )
    );
  END IF;

  -- Notificar a los integrantes del grupo (membership y job)
  INSERT INTO public.notifications (user_id, type, title, body, data)
  SELECT
    ji.invited_user_id,
    'booking',
    '💰 ¡El anticipo fue pagado!',
    COALESCE(v_client_name, 'El cliente') || ' pagó. Revisa la dirección del evento del ' ||
      TO_CHAR(v_event_date, 'DD/MM/YYYY') || '.',
    jsonb_build_object(
      'reservation_id', p_reservation_id,
      'screen',         'GroupReservations'
    )
  FROM public.job_invitations ji
  WHERE ji.group_id    = v_group_id
    AND ji.status      = 'accepted'
    AND ji.invited_user_id IS DISTINCT FROM v_owner_id;

  RETURN jsonb_build_object('ok', true);
END;
$$;

GRANT EXECUTE ON FUNCTION public.simulate_deposit_paid(UUID) TO authenticated;

SELECT '78_notify_group_on_payment: simulate_deposit_paid con notificaciones ✅' AS status;
