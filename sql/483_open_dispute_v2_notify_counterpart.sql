-- ============================================================
-- sql/483_open_dispute_v2_notify_counterpart.sql
-- ⚠️ DISPUTAS: notificar también a la CONTRAPARTE (auditoría 2026-07-13).
--
-- Antes open_dispute solo avisaba a los admins. Ahora:
--   • Cliente abre → el DUEÑO del grupo recibe aviso (tap → sus eventos)
--   • Grupo abre  → el CLIENTE recibe aviso (tap → sus eventos)
--   • Admins reciben el suyo como siempre (tap → cola de disputas)
--
-- Misma firma open_dispute(p_reservation_id, p_reason) — el frontend
-- nuevo ("Reportar un problema" del cliente) la llama tal cual.
-- Recordatorio: una disputa abierta BLOQUEA la liberación del pago.
-- ============================================================

BEGIN;

CREATE OR REPLACE FUNCTION open_dispute(
  p_reservation_id UUID,
  p_reason         TEXT
)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_caller_id   UUID := auth.uid();
  v_reservation RECORD;
  v_dispute_id  UUID;
  v_owner       UUID;
  v_gname       TEXT;
  v_is_client   BOOLEAN;
BEGIN
  IF v_caller_id IS NULL THEN
    RAISE EXCEPTION 'unauthorized: sesión requerida';
  END IF;

  SELECT * INTO v_reservation FROM reservations WHERE id = p_reservation_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Reserva no encontrada'; END IF;

  SELECT owner_id, name INTO v_owner, v_gname FROM groups WHERE id = v_reservation.group_id;
  v_is_client := (v_reservation.client_id = v_caller_id);

  IF NOT v_is_client AND v_owner IS DISTINCT FROM v_caller_id THEN
    RAISE EXCEPTION 'unauthorized: no eres parte de esta reserva';
  END IF;

  IF EXISTS (
    SELECT 1 FROM disputes
    WHERE reservation_id = p_reservation_id AND status IN ('open','under_review')
  ) THEN
    RAISE EXCEPTION 'Ya existe una disputa abierta para esta reserva';
  END IF;

  INSERT INTO disputes (reservation_id, opened_by, reason, status)
  VALUES (p_reservation_id, v_caller_id, p_reason, 'open')
  RETURNING id INTO v_dispute_id;

  -- Admins → cola de disputas
  INSERT INTO notifications (user_id, type, title, body, data)
  SELECT id, 'dispute', '⚠️ Nueva disputa abierta',
    format('%s abrió una disputa del evento %s (%s): "%s". El pago queda bloqueado hasta resolverla.',
           CASE WHEN v_is_client THEN 'El cliente' ELSE COALESCE(v_gname, 'El grupo') END,
           COALESCE(v_reservation.folio, p_reservation_id::text),
           v_reservation.event_date, LEFT(p_reason, 120)),
    jsonb_build_object('screen','AdminDisputes','dispute_id',v_dispute_id,'reservation_id',p_reservation_id)
  FROM profiles WHERE role = 'admin';

  -- Contraparte → se entera y puede preparar su versión
  IF v_is_client AND v_owner IS NOT NULL THEN
    INSERT INTO notifications (user_id, type, title, body, data)
    VALUES (v_owner, 'dispute',
      '⚠️ El cliente reportó un problema con tu evento',
      format('Evento %s del %s: "%s". El equipo de Daricefy revisará el caso con la evidencia del temporizador — el pago queda en pausa mientras tanto. Si tienes algo que aportar, contáctanos desde Soporte.',
             COALESCE(v_reservation.folio, ''), v_reservation.event_date, LEFT(p_reason, 120)),
      jsonb_build_object('reservation_id', p_reservation_id, 'dispute_id', v_dispute_id, 'screen', 'GroupReservations'));
  ELSIF NOT v_is_client AND v_reservation.client_id IS NOT NULL THEN
    INSERT INTO notifications (user_id, type, title, body, data)
    VALUES (v_reservation.client_id, 'dispute',
      '⚠️ El grupo reportó un problema con el evento',
      format('Evento %s del %s: "%s". El equipo de Daricefy revisará el caso con la evidencia del temporizador. Si tienes algo que aportar, contáctanos desde Soporte.',
             COALESCE(v_reservation.folio, ''), v_reservation.event_date, LEFT(p_reason, 120)),
      jsonb_build_object('reservation_id', p_reservation_id, 'dispute_id', v_dispute_id, 'screen', 'Reservations'));
  END IF;

  RETURN jsonb_build_object('ok', true, 'dispute_id', v_dispute_id);
END;
$$;

GRANT EXECUTE ON FUNCTION open_dispute(UUID, TEXT) TO authenticated;

COMMIT;

-- ── VERIFICACIÓN ──────────────────────────────────────────────────────────────
SELECT prosrc LIKE '%reportó un problema%' AS notifica_contraparte
FROM pg_proc WHERE proname = 'open_dispute';
-- Esperado: true

SELECT '483_open_dispute_v2_notify_counterpart.sql ejecutado ✅' AS status;
