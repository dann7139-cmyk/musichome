-- ═══════════════════════════════════════════════════════════════
-- 389 — complete_event RPC + columnas de finalización
--
-- Contexto del bug:
--   finishEvent() en EventTimerScreen usaba .update({ finished_at, actual_duration_minutes })
--   Ambas columnas no existen → PostgREST devuelve 400 → status nunca cambia a 'completed'.
--   Además no había try-catch → setShowCelebration(true) nunca se ejecutaba.
--
-- Cambios:
--   1. ADD COLUMN break_type TEXT (IF NOT EXISTS — no-op si ya la escribió confirmStart)
--   2. ADD COLUMN actual_duration_minutes INT (nueva)
--   3. RPC complete_event — SECURITY DEFINER, usa event_ended_at correcto
-- ═══════════════════════════════════════════════════════════════

BEGIN;

-- ─── 1. Columnas de finalización ──────────────────────────────────────────────

ALTER TABLE reservations
  ADD COLUMN IF NOT EXISTS break_type              TEXT,
  ADD COLUMN IF NOT EXISTS actual_duration_minutes INT;

-- ─── 2. RPC complete_event ────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION complete_event(
  p_reservation_id UUID
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_caller_id  UUID        := auth.uid();
  v_started_at TIMESTAMPTZ;
  v_duration   INT;
  v_status     TEXT;
BEGIN
  IF v_caller_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'unauthorized: sesión requerida');
  END IF;

  -- Validar que el caller es el group owner de esta reserva
  IF NOT EXISTS (
    SELECT 1
    FROM   reservations r
    JOIN   groups g ON g.id = r.group_id
    WHERE  r.id = p_reservation_id
      AND  g.owner_id = v_caller_id
  ) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'unauthorized: solo el grupo puede finalizar el evento');
  END IF;

  -- Leer estado actual y timestamp de inicio
  SELECT status, event_started_at
  INTO   v_status, v_started_at
  FROM   reservations
  WHERE  id = p_reservation_id;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'Reserva no encontrada');
  END IF;

  -- Si ya está completada, retornar éxito idempotente
  IF v_status = 'completed' THEN
    RETURN jsonb_build_object('ok', true, 'completed_at', NOW(), 'note', 'already_completed');
  END IF;

  -- Calcular duración real en minutos desde event_started_at
  v_duration := CASE
    WHEN v_started_at IS NOT NULL
    THEN GREATEST(0, EXTRACT(EPOCH FROM (NOW() - v_started_at))::INT / 60)
    ELSE NULL
  END;

  UPDATE reservations
  SET status                   = 'completed',
      event_ended_at           = NOW(),
      actual_duration_minutes  = COALESCE(actual_duration_minutes, v_duration),
      updated_at               = NOW()
  WHERE id = p_reservation_id;

  RETURN jsonb_build_object(
    'ok',           true,
    'completed_at', NOW(),
    'duration_min', v_duration
  );
END;
$$;

GRANT EXECUTE ON FUNCTION complete_event(UUID) TO authenticated;

COMMIT;

-- ═══════════════════════════════════════════════════════════════
-- VERIFICACIONES (ejecutar separado después del COMMIT)
-- ═══════════════════════════════════════════════════════════════

-- V1: columnas existen en reservations
SELECT column_name, data_type
FROM information_schema.columns
WHERE table_name = 'reservations'
  AND column_name IN ('break_type', 'actual_duration_minutes')
ORDER BY column_name;
-- Esperado: 2 filas

-- V2: complete_event existe con 1 param y SECURITY DEFINER
SELECT proname, pronargs, prosecdef AS is_security_definer
FROM pg_proc
WHERE proname = 'complete_event';
-- Esperado: 1 fila, pronargs=1, is_security_definer=true

-- V3: GRANT aplicado a authenticated
SELECT grantee, privilege_type
FROM information_schema.routine_privileges
WHERE routine_name = 'complete_event'
  AND grantee = 'authenticated';
-- Esperado: 1 fila con EXECUTE

-- V4: llamada idempotente con reserva ya completada no lanza error
-- SELECT complete_event('UUID-DE-RESERVA-YA-COMPLETADA'::UUID);
-- Esperado: {"ok": true, "note": "already_completed"}
-- Llamada con UUID inexistente:
-- SELECT complete_event(gen_random_uuid());
-- Esperado: {"ok": false, "error": "Reserva no encontrada"}
