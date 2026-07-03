-- ═══════════════════════════════════════════════════════════════
-- 385 — validate_start_code RPC
-- Valida el código de 4 dígitos del cliente para INICIAR el evento.
-- A diferencia de validate_arrival_code, NO toca group_arrived_at:
--   · validate_arrival_code → se llama al "Llegué" (setea group_arrived_at)
--   · validate_start_code   → se llama al "Iniciar" (solo valida el código)
-- SECURITY DEFINER: bypasses RLS en reservations.
-- ═══════════════════════════════════════════════════════════════

BEGIN;

CREATE OR REPLACE FUNCTION validate_start_code(
  p_reservation_id UUID,
  p_code           TEXT
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_stored_code TEXT;
BEGIN
  SELECT arrival_code
  INTO   v_stored_code
  FROM   reservations
  WHERE  id = p_reservation_id;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'Reserva no encontrada');
  END IF;

  IF v_stored_code IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'Esta reserva no tiene código de inicio asignado');
  END IF;

  IF v_stored_code <> p_code THEN
    RETURN jsonb_build_object('ok', false, 'error', 'Código inválido');
  END IF;

  RETURN jsonb_build_object('ok', true);
END;
$$;

GRANT EXECUTE ON FUNCTION validate_start_code(UUID, TEXT) TO authenticated;

COMMIT;

-- ═══════════════════════════════════════════════════════════════
-- VERIFICACIONES (ejecutar separado después del COMMIT)
-- ═══════════════════════════════════════════════════════════════

-- V1: función existe con SECURITY DEFINER
SELECT proname, pronargs, prosecdef AS is_security_definer
FROM   pg_proc
WHERE  proname = 'validate_start_code';
-- Esperado: 1 fila, is_security_definer = true

-- V2: GRANT aplicado a authenticated
SELECT grantee, privilege_type
FROM   information_schema.routine_privileges
WHERE  routine_name = 'validate_start_code'
  AND  grantee = 'authenticated';
-- Esperado: 1 fila con privilege_type = 'EXECUTE'

-- V3: prueba con código incorrecto (debe retornar ok=false, NO modificar DB)
-- SELECT validate_start_code('UUID-DE-RESERVA-REAL'::UUID, '0000');
-- Esperado: {"ok": false, "error": "Código inválido"}

-- V4: prueba con código correcto — verifica que group_arrived_at NO cambia
-- SELECT validate_start_code('UUID-DE-RESERVA-REAL'::UUID, arrival_code)
-- FROM reservations WHERE id = 'UUID-DE-RESERVA-REAL'::UUID;
-- Esperado: {"ok": true}
-- Confirmar: SELECT group_arrived_at FROM reservations WHERE id = 'UUID-...';
-- Esperado: group_arrived_at SIN CAMBIOS (columna no tocada por esta función)
