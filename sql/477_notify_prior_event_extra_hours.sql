-- ============================================================
-- sql/477_notify_prior_event_extra_hours.sql
-- 🎵 SEGUNDO EVENTO DESPUÉS DE UNA TOCADA: avisar a los dos lados.
--
-- Cuando un cliente solicita al grupo DESPUÉS de un evento que ya tiene
-- ese día (programada o express):
--   1. Al DUEÑO del grupo: "te piden después de tu tocada — pregúntale a tu
--      cliente actual si querrá horas extra antes de comprometerte".
--   2. Al CLIENTE del primer evento: "¿vas a querer horas extra? están
--      solicitando a tu grupo para otro evento después del tuyo".
--
-- Solo notifica — no toca reservas, wallet ni candados. Idempotente por
-- solicitud (cada cotización/propuesta nueva genera su aviso).
-- ============================================================

BEGIN;

CREATE OR REPLACE FUNCTION public.notify_prior_event_extra_hours(
  p_group_id   UUID,
  p_event_date DATE,
  p_event_time TIME
)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_prior RECORD;
  v_owner UUID;
  v_gname TEXT;
BEGIN
  IF auth.uid() IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'unauthorized');
  END IF;
  IF p_group_id IS NULL OR p_event_date IS NULL OR p_event_time IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'missing_params');
  END IF;

  SELECT owner_id, name INTO v_owner, v_gname FROM groups WHERE id = p_group_id;
  IF v_owner IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'group_not_found');
  END IF;

  -- Último evento del grupo ese día que TERMINA antes de la hora solicitada
  SELECT r.id, r.client_id, r.event_time, r.hours_count
  INTO v_prior
  FROM reservations r
  WHERE r.group_id   = p_group_id
    AND r.event_date = p_event_date
    AND r.status IN ('accepted', 'confirmed', 'in_progress')
    AND r.event_time IS NOT NULL
    AND (r.event_time + make_interval(hours => COALESCE(r.hours_count, 3)::int))
        <= p_event_time + CASE WHEN p_event_time < '06:00'::time
                               THEN INTERVAL '24 hours' ELSE INTERVAL '0' END
    AND r.event_time < p_event_time + CASE WHEN p_event_time < '06:00'::time
                                           THEN INTERVAL '24 hours' ELSE INTERVAL '0' END
  ORDER BY r.event_time DESC
  LIMIT 1;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', true, 'notified', false, 'reason', 'no_prior_event');
  END IF;

  -- 1) Al dueño del grupo
  INSERT INTO notifications (user_id, type, title, body, data)
  VALUES (v_owner, 'reservation',
    '🎵 Te piden DESPUÉS de tu tocada de ese día',
    format('Un cliente quiere contratarte después de tu evento de las %s. Antes de comprometerte, pregúntale a tu cliente actual si querrá horas extra — ofrécelas desde la app en el temporizador.',
           to_char(v_prior.event_time, 'HH12:MI am')),
    jsonb_build_object('reservation_id', v_prior.id, 'screen', 'GroupEvents'));

  -- 2) Al cliente del primer evento
  IF v_prior.client_id IS NOT NULL THEN
    INSERT INTO notifications (user_id, type, title, body, data)
    VALUES (v_prior.client_id, 'reservation',
      '⏰ ¿Vas a querer horas extra?',
      format('%s está siendo solicitado para otro evento después del tuyo. Si crees que querrás extender tu evento con horas extra, decídelo pronto para que el grupo se organice.',
             COALESCE(v_gname, 'Tu grupo')),
      jsonb_build_object('reservation_id', v_prior.id, 'screen', 'Reservations'));
  END IF;

  RETURN jsonb_build_object('ok', true, 'notified', true, 'prior_reservation', v_prior.id);
END;
$$;

GRANT EXECUTE ON FUNCTION public.notify_prior_event_extra_hours(UUID, DATE, TIME) TO authenticated;

COMMIT;

-- ── VERIFICACIÓN ──────────────────────────────────────────────────────────────
SELECT proname FROM pg_proc WHERE proname = 'notify_prior_event_extra_hours';
-- Esperado: 1 fila

SELECT '477_notify_prior_event_extra_hours.sql ejecutado ✅' AS status;
