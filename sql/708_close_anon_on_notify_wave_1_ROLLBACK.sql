-- ═══════════════════════════════════════════════════════════════════════════
-- ROLLBACK de 708 — devuelve el ACL original de `notify_wave_1`
-- ═══════════════════════════════════════════════════════════════════════════
-- ⚠️  Correrlo REABRE la función a cualquiera con la anon key (que va dentro del
-- binario de la app, o sea es pública). Solo tiene sentido si aparece un flujo
-- legítimo sin sesión que la necesite.
--
-- Restaura exactamente el ACL que había antes de sql/708:
--   {=X/postgres, postgres=X/postgres, anon=X/postgres,
--    authenticated=X/postgres, service_role=X/postgres}
-- El cuerpo de la función nunca se tocó, así que no hay nada que recrear.
-- ═══════════════════════════════════════════════════════════════════════════

BEGIN;

GRANT EXECUTE ON FUNCTION
  public.notify_wave_1(UUID, DOUBLE PRECISION, DOUBLE PRECISION, DOUBLE PRECISION, BOOLEAN)
  TO PUBLIC, anon, authenticated, service_role;

COMMENT ON FUNCTION public.notify_wave_1(UUID, DOUBLE PRECISION, DOUBLE PRECISION, DOUBLE PRECISION, BOOLEAN) IS
  'sql/704 dejo esta unica firma (top 3). ROLLBACK de sql/708: EXECUTE reabierto a PUBLIC y anon.';

NOTIFY pgrst, 'reload schema';

COMMIT;
