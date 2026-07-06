-- ============================================================
-- sql/450_arrival_verified_flag_and_force_start.sql
-- Opción A (parte 1 de 2): flag arrival_verified + force-start lo setea.
--
-- CONTEXTO: el release full (release_group_earnings_atomic) no checa
-- group_arrived_at → un evento que llega a in_progress SIN llegada GPS se
-- paga solo. Opción A: el release exigirá (group_arrived_at IS NOT NULL
-- OR arrival_verified). Este flag lo pone el admin al FORZAR el inicio
-- (ya confirmó presencia por teléfono).
--
-- Esta parte NO cambia comportamiento de pago todavía (el gate va en la
-- parte 2, sobre el functiondef de PROD de release_group_earnings_atomic).
-- Es seguro correrla antes: solo agrega la columna y hace que force-start
-- la marque hacia adelante.
--
-- admin_force_start_event: basado en el functiondef vigente (sql/443, que
-- corriste verbatim). Solo AGREGA arrival_verified=true al UPDATE y ajusta
-- la nota de auditoría. Todo lo demás intacto.
-- ============================================================

BEGIN;

-- ─── 1. Columna arrival_verified ──────────────────────────────────────────────
ALTER TABLE public.reservations
  ADD COLUMN IF NOT EXISTS arrival_verified BOOLEAN DEFAULT false;

-- ─── 2. admin_force_start_event → marca arrival_verified=true ──────────────────
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
    arrival_verified = true,           -- [450] admin confirmó presencia al forzar
    updated_at       = NOW()
  WHERE id = p_reservation_id;

  -- Auditoría: quién forzó y cuándo
  INSERT INTO financial_audit_logs
    (entity_type, entity_id, action, actor_id, actor_role, amount, notes)
  VALUES ('reservation', p_reservation_id, 'force_start', v_admin_id, 'admin', 0,
    format('Inicio forzado por admin (presencia verificada -> arrival_verified=true). break=%s music_min=%s',
           v_break, v_music_min));

  SELECT name INTO v_group_name FROM groups WHERE id = v_res.group_id;

  -- Notificar al grupo
  INSERT INTO notifications (user_id, type, title, body, data)
  SELECT g.owner_id, 'event_auto_started',
    '⏰ Un administrador inició tu evento',
    'El evento se marcó como iniciado. Abre la app para ver el timer.',
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
    'break_type', v_break, 'music_minutes', v_music_min, 'arrival_verified', true);
END;
$$;

GRANT EXECUTE ON FUNCTION public.admin_force_start_event(UUID) TO authenticated;

COMMIT;

-- ── VERIFICACIONES (correr por separado después del COMMIT) ─────────────────────
-- V1: columna existe con default false
SELECT column_name, data_type, column_default
FROM information_schema.columns
WHERE table_name = 'reservations' AND column_name = 'arrival_verified';
-- Esperado: arrival_verified | boolean | false

-- V2: force-start setea arrival_verified y conserva su lógica
SELECT
  prosrc LIKE '%arrival_verified = true%'  AS marca_verificado,   -- true
  prosrc LIKE '%force_start%'              AS conserva_auditoria, -- true
  prosrc LIKE '%not_startable%'            AS conserva_guards,    -- true
  prosrc NOT LIKE '%release_half_on_arrival%' AS no_toca_gps,     -- true
  prosrc NOT LIKE '%group_wallets%'        AS no_toca_wallet      -- true
FROM pg_proc WHERE proname = 'admin_force_start_event';
-- Esperado: true | true | true | true | true

SELECT '450_arrival_verified_flag_and_force_start.sql ejecutado ✅' AS status;
