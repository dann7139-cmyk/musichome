-- ═══════════════════════════════════════════════════════════════
-- 381 — validate_arrival_code RPC
-- Valida el código de 4 dígitos del cliente y marca la llegada del grupo.
-- SECURITY DEFINER: bypasses RLS (evita recursión infinita en policies de reservations).
-- Ejecutar en Supabase SQL Editor
-- ═══════════════════════════════════════════════════════════════

BEGIN;

-- ─── RLS DIAGNOSTIC (ejecutar primero para identificar recursión) ─────────────
-- SELECT policyname, cmd, qual, with_check
-- FROM pg_policies WHERE tablename = 'reservations';
-- Buscar cualquier policy cuyo qual/with_check referencie la misma tabla reservations.
-- Fix: SECURITY DEFINER en esta función bypassa todas las policies de reservations.

-- ─── FUNCIÓN PRINCIPAL ────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION validate_arrival_code(
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
  v_arrived_at  TIMESTAMPTZ;
BEGIN
  -- Leer código y estado de llegada sin activar RLS (SECURITY DEFINER)
  SELECT arrival_code, group_arrived_at
  INTO   v_stored_code, v_arrived_at
  FROM   reservations
  WHERE  id = p_reservation_id;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'Reserva no encontrada');
  END IF;

  -- Idempotente: si el grupo ya marcó llegada, retornar ok sin error
  IF v_arrived_at IS NOT NULL THEN
    RETURN jsonb_build_object('ok', true, 'already_arrived', true);
  END IF;

  -- Sin código asignado (reserva creada antes del backfill)
  IF v_stored_code IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'Esta reserva no tiene código de inicio asignado');
  END IF;

  -- Comparación estricta
  IF v_stored_code <> p_code THEN
    RETURN jsonb_build_object('ok', false, 'error', 'Código inválido');
  END IF;

  -- Código correcto → marcar llegada (atómico dentro del transaction del caller)
  UPDATE reservations
  SET    group_arrived_at = NOW()
  WHERE  id = p_reservation_id;

  RETURN jsonb_build_object('ok', true);
END;
$$;

-- Permitir a usuarios autenticados llamar la función
GRANT EXECUTE ON FUNCTION validate_arrival_code(UUID, TEXT) TO authenticated;

COMMIT;

-- ═══════════════════════════════════════════════════════════════
-- VERIFICACIONES (ejecutar separado, después del COMMIT)
-- ═══════════════════════════════════════════════════════════════

-- V1: función existe con firma correcta
SELECT proname, pronargs, prosecdef AS is_security_definer
FROM   pg_proc
WHERE  proname = 'validate_arrival_code';
-- Esperado: 1 fila, is_security_definer = true

-- V2: permisos otorgados a authenticated
SELECT grantee, privilege_type
FROM   information_schema.routine_privileges
WHERE  routine_name = 'validate_arrival_code'
  AND  grantee = 'authenticated';
-- Esperado: 1 fila con privilege_type = 'EXECUTE'

-- V3: prueba con código incorrecto (debe retornar ok=false)
-- Reemplaza 'UUID-DE-RESERVA-REAL' con un id real de tu tabla
-- SELECT validate_arrival_code('UUID-DE-RESERVA-REAL'::UUID, '0000');
-- Esperado: {"ok": false, "error": "Código inválido"}

-- V4: prueba con código correcto (debe retornar ok=true y actualizar group_arrived_at)
-- SELECT validate_arrival_code('UUID-DE-RESERVA-REAL'::UUID, arrival_code)
-- FROM reservations WHERE id = 'UUID-DE-RESERVA-REAL'::UUID;
-- Esperado: {"ok": true}
-- Verificar: SELECT group_arrived_at FROM reservations WHERE id = 'UUID-...';
