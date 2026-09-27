-- ═══════════════════════════════════════════════════════════════════════════
-- 702 — cierra `validate_arrival_code`: le retira EXECUTE a `authenticated`
-- ═══════════════════════════════════════════════════════════════════════════
-- MIGRACIÓN MÍNIMA Y AISLADA. Toca UNA sola función y solo su ACL. No incluye
-- `validate_start_code`, ni `release_half_on_arrival`, ni
-- `release_group_earnings_atomic` (esas viven en `700`, que sigue sin aplicarse
-- porque rompería la app instalada). No cambia cuerpos de función, ni tablas, ni
-- datos, ni policies, ni RLS, ni nada económico.
--
-- ── POR QUÉ SE PUEDE APLICAR YA, A DIFERENCIA DE 700 ───────────────────────
-- `validate_arrival_code(uuid, text)` **no tiene ningún llamador vivo**.
-- Verificado de forma exhaustiva el 2026-09-27:
--   · app móvil (`src/`)           → 0
--   · web (`web/src/`)             → 0
--   · Edge Functions               → 0
--   · funciones SQL (`pg_proc`)    → 0
--   · triggers (`pg_trigger`)      → 0
--   · crons (`cron.job`)           → 0
--   · vistas, policies RLS y defaults de columna → 0
-- Solo aparece en archivos de migración: su propia definición (`sql/381`), un
-- comentario en `sql/385` y las migraciones de este endurecimiento.
-- La app usa `validate_start_code` (EventTimerScreen), que es OTRA función.
--
-- ── QUÉ RIESGO CIERRA ──────────────────────────────────────────────────────
-- Es la única de las cuatro primitivas de llegada/payout que SÍ escribe:
-- pone `group_arrived_at = NOW()` si el código coincide, sin comprobar NADA
-- sobre quién llama. Y `group_arrived_at` es precisamente una de las guardas de
-- `release_group_earnings_atomic`. Dejarla abierta a `authenticated` permitía a
-- cualquier usuario con sesión marcar la llegada de una reserva ajena.
-- Tras esto queda en `postgres | service_role`, como las 13 de `sql/694`.
--
-- `anon` ya se le había quitado en `sql/694`; esto retira lo que faltaba.
-- ═══════════════════════════════════════════════════════════════════════════

BEGIN;

REVOKE EXECUTE ON FUNCTION public.validate_arrival_code(UUID, TEXT) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.validate_arrival_code(UUID, TEXT) TO postgres, service_role;

NOTIFY pgrst, 'reload schema';

COMMIT;
