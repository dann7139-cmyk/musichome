-- ═══════════════════════════════════════════════════════════════════════════
-- ROLLBACK de 702 — devuelve EXECUTE de validate_arrival_code a authenticated
-- ═══════════════════════════════════════════════════════════════════════════
-- Restaura la ACL que tenía justo antes de `702`, que es la que dejó `sql/694`:
-- `postgres | authenticated | service_role` (sin PUBLIC y sin anon).
-- Correrlo solo si apareciera un llamador legítimo que la búsqueda no encontró.
-- OJO: NO se devuelve PUBLIC ni anon a propósito — eso lo cerró `sql/694` por
-- otras razones y no debe reabrirse aquí.
-- ═══════════════════════════════════════════════════════════════════════════

BEGIN;

GRANT EXECUTE ON FUNCTION public.validate_arrival_code(UUID, TEXT) TO authenticated;

NOTIFY pgrst, 'reload schema';

COMMIT;
