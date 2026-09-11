-- sql/640_admin_force_complete_event.sql
--
-- Válvula de escape para eventos atorados por el código de "servicio
-- terminado" (sql/639). Si el cliente nunca le da el código al proveedor
-- (se le olvida, no quiere, hay un conflicto), el evento se quedaría
-- atorado para siempre y el 50% restante del pago del grupo nunca se
-- liberaría — no había ninguna forma de resolverlo.
--
-- admin_force_complete_event(reservation_id, reason): mismo patrón que
-- admin_force_start_event (sql ya existente) — admin o admin_ops
-- (acotado a su país) cierran el evento a mano, se libera el pago
-- (misma RPC que usa el flujo normal, release_group_earnings_atomic +
-- release_extra_hours_final), y queda registrado en
-- financial_audit_logs con el motivo. Notifica a cliente y grupo.
--
-- Uso esperado: el proveedor contacta a soporte (botón que ya existe en
-- EventTimerScreen) → admin busca el ticket en AdminTicketSearchScreen
-- (ahí ya se ve el teléfono del proveedor y del cliente para llamarles)
-- → si corresponde, fuerza el cierre desde ahí.
-- ============================================================

BEGIN;

CREATE OR REPLACE FUNCTION public.admin_force_complete_event(p_reservation_id uuid, p_reason text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $function$
DECLARE
  v_admin_id     UUID := auth.uid();
  v_caller_role  TEXT;
  v_res          RECORD;
  v_duration     INT;
  v_release      jsonb;
  v_extra        jsonb;
  v_group_name   TEXT;
BEGIN
  SELECT role INTO v_caller_role FROM profiles WHERE id = v_admin_id;
  IF v_caller_role NOT IN ('admin', 'admin_ops') THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_admin');
  END IF;

  SELECT * INTO v_res FROM reservations WHERE id = p_reservation_id FOR UPDATE;
  IF NOT FOUND THEN RETURN jsonb_build_object('ok', false, 'error', 'not_found'); END IF;

  IF v_caller_role = 'admin_ops' AND NOT EXISTS (
    SELECT 1 FROM groups g WHERE g.id = v_res.group_id
      AND country_code_of(g.country) = admin_ops_country()
  ) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_admin');
  END IF;

  IF v_res.status = 'completed' THEN
    RETURN jsonb_build_object('ok', true, 'skipped', true, 'reason', 'already_completed');
  END IF;

  IF v_res.event_started_at IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'event_not_started');
  END IF;

  v_duration := GREATEST(0, EXTRACT(EPOCH FROM (NOW() - v_res.event_started_at))::INT / 60);

  UPDATE reservations
  SET status                  = 'completed',
      event_ended_at          = NOW(),
      actual_duration_minutes = COALESCE(actual_duration_minutes, v_duration),
      updated_at              = NOW()
  WHERE id = p_reservation_id;

  INSERT INTO financial_audit_logs
    (entity_type, entity_id, action, actor_id, actor_role, amount, notes)
  VALUES ('reservation', p_reservation_id, 'force_complete', v_admin_id, v_caller_role, 0,
    format('Cierre forzado por admin. Motivo: %s', COALESCE(p_reason, 'sin especificar')));

  v_release := release_group_earnings_atomic(p_reservation_id, v_admin_id);
  v_extra   := release_extra_hours_final(p_reservation_id);

  SELECT name INTO v_group_name FROM groups WHERE id = v_res.group_id;

  IF v_res.client_id IS NOT NULL THEN
    INSERT INTO notifications (user_id, type, title, body, data)
    VALUES (v_res.client_id, 'event_finalized', '✅ Tu evento fue cerrado',
      'Un administrador confirmó el fin de tu evento.',
      jsonb_build_object('reservation_id', p_reservation_id, 'screen', 'LiveEvent'));
  END IF;

  INSERT INTO notifications (user_id, type, title, body, data)
  SELECT g.owner_id, 'event_finalized', '✅ Evento cerrado por soporte',
    'Un administrador cerró tu evento y liberó tu pago.',
    jsonb_build_object('reservation_id', p_reservation_id, 'screen', 'EventTimer')
  FROM groups g WHERE g.id = v_res.group_id;

  RETURN jsonb_build_object(
    'ok', true, 'duration_min', v_duration,
    'release', v_release, 'extra_release', v_extra
  );
END;
$function$;

COMMIT;

-- ── VERIFICACIÓN ────────────────────────────────────────────
SELECT proname FROM pg_proc WHERE proname = 'admin_force_complete_event';
-- Esperado: 1 fila

SELECT '640_admin_force_complete_event.sql ejecutado ✅' AS status;
