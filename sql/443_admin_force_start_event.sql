-- ============================================================
-- sql/443_admin_force_start_event.sql
-- Opción B — Red de seguridad: el admin puede FORZAR el inicio de un
-- evento atorado (GPS roto, grupo que no pudo marcar llegada, etc.).
--
-- Diseño (espeja confirmStart de EventTimerScreen):
--   · status = 'in_progress', event_started_at = NOW(), break_type,
--     music_minutes. NO toca payout/wallet — el candado GPS del 50%
--     (release_half_on_arrival) sigue exigiendo la llegada real.
--   · AUDITADO: financial_audit_logs con actor_id = admin, action
--     'force_start' (quién y cuándo).
--   · Notifica al grupo y al cliente.
--
-- Función NUEVA — no redefine nada sensible (no toca release_half_on_arrival
-- ni las funciones de wallet).
-- ============================================================

BEGIN;

CREATE OR REPLACE FUNCTION public.admin_force_start_event(p_reservation_id UUID)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_admin_id   UUID := auth.uid();
  v_res        RECORD;
  v_hours      NUMERIC;
  v_break      TEXT;
  v_break_min  INT;
  v_music_min  INT;
  v_group_name TEXT;
BEGIN
  -- Gate admin
  IF NOT EXISTS (SELECT 1 FROM profiles WHERE id = v_admin_id AND role = 'admin') THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_admin');
  END IF;

  SELECT * INTO v_res FROM reservations WHERE id = p_reservation_id FOR UPDATE;
  IF NOT FOUND THEN RETURN jsonb_build_object('ok', false, 'error', 'not_found'); END IF;

  -- Solo eventos confirmados que aún no inician
  IF v_res.event_started_at IS NOT NULL OR v_res.status = 'completed' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'already_started',
      'status', v_res.status);
  END IF;
  IF v_res.status NOT IN ('confirmed', 'accepted') THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_startable', 'status', v_res.status);
  END IF;

  -- Duración contratada y break (reusa el existente o 'B' por defecto)
  v_hours := GREATEST(COALESCE(v_res.hours_count,
                        (SELECT duration_hours FROM quotes WHERE id = v_res.quote_id), 3), 1);
  v_break := COALESCE(v_res.break_type, 'B');
  v_break_min := CASE v_break
    WHEN 'A' THEN 15 * GREATEST(v_hours::INT - 1, 0)   -- 15 min cada hora
    WHEN 'D' THEN 0                                     -- sin descanso
    ELSE 15                                             -- 'B' descanso único
  END;
  v_music_min := (v_hours * 60)::INT - v_break_min;

  UPDATE reservations SET
    status           = 'in_progress',
    event_started_at = NOW(),
    break_type       = v_break,
    music_minutes    = v_music_min,
    updated_at       = NOW()
  WHERE id = p_reservation_id;

  -- Auditoría: quién forzó y cuándo
  INSERT INTO financial_audit_logs
    (entity_type, entity_id, action, actor_id, actor_role, amount, notes)
  VALUES ('reservation', p_reservation_id, 'force_start', v_admin_id, 'admin', 0,
    format('Inicio forzado por admin. break=%s music_min=%s (el 50%% sigue requiriendo llegada GPS)',
           v_break, v_music_min));

  SELECT name INTO v_group_name FROM groups WHERE id = v_res.group_id;

  -- Notificar al grupo
  INSERT INTO notifications (user_id, type, title, body, data)
  SELECT g.owner_id, 'event_auto_started',
    '⏰ Un administrador inició tu evento',
    'El evento se marcó como iniciado. Abre la app para ver el timer. Recuerda marcar tu llegada para liberar tu pago.',
    jsonb_build_object('reservation_id', p_reservation_id, 'screen', 'EventTimer', 'forced', true)
  FROM groups g WHERE g.id = v_res.group_id;

  -- Notificar al cliente
  IF v_res.client_id IS NOT NULL THEN
    INSERT INTO notifications (user_id, type, title, body, data)
    VALUES (v_res.client_id, 'event_auto_started',
      '🎵 ¡Tu evento ha iniciado!',
      COALESCE(v_group_name, 'El grupo') || ' está por comenzar. ¡Disfrútalo!',
      jsonb_build_object('reservation_id', p_reservation_id, 'screen', 'LiveEvent'));
  END IF;

  RETURN jsonb_build_object('ok', true, 'status', 'in_progress',
    'break_type', v_break, 'music_minutes', v_music_min);
END;
$$;

GRANT EXECUTE ON FUNCTION public.admin_force_start_event(UUID) TO authenticated;

COMMIT;

-- ── VERIFICACIONES ────────────────────────────────────────────────────────────
-- V1: la función existe y no toca release_half_on_arrival ni wallets
SELECT
  routine_definition LIKE '%''in_progress''%'              AS marca_in_progress,
  routine_definition LIKE '%force_start%'                  AS auditada,
  routine_definition NOT LIKE '%release_half_on_arrival%'  AS no_toca_gps,
  routine_definition NOT LIKE '%group_wallets%'            AS no_toca_wallet
FROM information_schema.routines
WHERE routine_schema = 'public' AND routine_name = 'admin_force_start_event';
-- Esperado: true | true | true | true

SELECT '443_admin_force_start_event.sql ejecutado ✅' AS status;
