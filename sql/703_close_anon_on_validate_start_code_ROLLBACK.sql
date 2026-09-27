-- ═══════════════════════════════════════════════════════════════════════════
-- ROLLBACK de 703 — devuelve PUBLIC y anon a validate_start_code
-- ═══════════════════════════════════════════════════════════════════════════
-- ⚠️  Esto REABRE el oráculo anónimo: cualquiera con la llave pública podría
-- volver a enumerar por fuerza bruta el código de 4 dígitos de cualquier reserva
-- sin tener cuenta. Correrlo solo si apareciera un flujo legítimo anónimo que la
-- auditoría no encontró.
-- ═══════════════════════════════════════════════════════════════════════════

BEGIN;

GRANT EXECUTE ON FUNCTION public.validate_start_code(UUID, TEXT) TO PUBLIC, anon;

NOTIFY pgrst, 'reload schema';

COMMIT;
