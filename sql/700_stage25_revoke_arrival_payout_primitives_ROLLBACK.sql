-- ═══════════════════════════════════════════════════════════════════════════
-- ROLLBACK de 700 — devuelve el EXECUTE de las 4 primitivas a los roles de la app
-- ═══════════════════════════════════════════════════════════════════════════
-- ⚠️  Esto REABRE el agujero: vuelve a permitir que cualquiera con la llave anon
-- use `validate_start_code` como oráculo de fuerza bruta, y que un
-- `authenticated` arbitrario marque llegada y libere pagos de reservas ajenas.
-- Correrlo solo si el cierre rompió un flujo legítimo no detectado.
--
-- Restaura la ACL previa: `=X/postgres` (PUBLIC) + anon + authenticated +
-- service_role, que es lo que tenían las cuatro.
-- ═══════════════════════════════════════════════════════════════════════════

BEGIN;

GRANT EXECUTE ON FUNCTION public.validate_start_code(UUID, TEXT)   TO PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.validate_arrival_code(UUID, TEXT) TO PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.release_half_on_arrival(UUID, DOUBLE PRECISION, DOUBLE PRECISION)
  TO PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.release_group_earnings_atomic(UUID, UUID)
  TO PUBLIC, anon, authenticated;

NOTIFY pgrst, 'reload schema';

COMMIT;
