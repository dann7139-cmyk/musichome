-- ═══════════════════════════════════════════════════════════════════════════
-- 700 — ETAPA 2.5 (b): cierra las primitivas de llegada y payout
-- ═══════════════════════════════════════════════════════════════════════════
-- ⛔ NO APLICAR TODAVÍA. Rompe la app instalada: EventTimerScreen llama hoy
-- DIRECTAMENTE a `release_half_on_arrival` (línea 1688),
-- `release_group_earnings_atomic` (línea 1964) y `validate_start_code`
-- (línea 1868). No hay OTA (`expo-updates` ausente, `app.json` sin bloque
-- `updates`), así que un build distribuido conserva su bundle hasta que el
-- usuario reinstale desde la tienda.
--
-- REQUISITOS antes de aplicar:
--   1. `sql/699` aplicado (las 3 envolturas + el helper).
--   2. Una versión de la app que llame a las envolturas, publicada Y adoptada.
--   3. `sql/701` en verde.
--
-- ── QUÉ CIERRA ─────────────────────────────────────────────────────────────
-- Tras esto, las cuatro primitivas solo las puede ejecutar `postgres` (los
-- crons) y `service_role` (webhooks/edge). El proveedor pasa por las envolturas
-- de sql/699, que verifican que sea el DUEÑO del grupo de ESA reserva. Con ello:
--   · desaparece el oráculo de fuerza bruta del código (`validate_start_code`
--     era ejecutable incluso por `anon`);
--   · un proveedor deja de poder operar la reserva de otro grupo pasando un
--     `reservation_id` ajeno;
--   · la primitiva financiera deja de ser invocable por un `authenticated`
--     arbitrario.
--
-- NO cambia ninguna regla económica: las guardas de payout, pago, disputa,
-- llegada, moneda e idempotencia siguen intactas dentro de las primitivas.
--
-- `validate_arrival_code` entra aquí aunque **no tiene ningún llamador vivo**
-- (la app usa `validate_start_code`): es la única de las cuatro cuya revocación
-- no rompería la app instalada, y podría aplicarse por separado antes que el
-- resto si se quiere reducir superficie ya mismo.
-- ═══════════════════════════════════════════════════════════════════════════

BEGIN;

DO $guard$
BEGIN
  IF to_regprocedure('public.group_validate_start_code(uuid, text)') IS NULL
  OR to_regprocedure('public.group_confirm_arrival(uuid, double precision, double precision)') IS NULL
  OR to_regprocedure('public.group_release_earnings(uuid)') IS NULL THEN
    RAISE EXCEPTION 'Faltan las envolturas de sql/699: aplica 699 antes de 700';
  END IF;
END
$guard$;

REVOKE EXECUTE ON FUNCTION public.validate_start_code(UUID, TEXT)   FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.validate_arrival_code(UUID, TEXT) FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.release_half_on_arrival(UUID, DOUBLE PRECISION, DOUBLE PRECISION)
  FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.release_group_earnings_atomic(UUID, UUID)
  FROM PUBLIC, anon, authenticated;

-- Constancia explícita de que el backend no pierde nada.
GRANT EXECUTE ON FUNCTION public.validate_start_code(UUID, TEXT)   TO postgres, service_role;
GRANT EXECUTE ON FUNCTION public.validate_arrival_code(UUID, TEXT) TO postgres, service_role;
GRANT EXECUTE ON FUNCTION public.release_half_on_arrival(UUID, DOUBLE PRECISION, DOUBLE PRECISION)
  TO postgres, service_role;
GRANT EXECUTE ON FUNCTION public.release_group_earnings_atomic(UUID, UUID)
  TO postgres, service_role;

NOTIFY pgrst, 'reload schema';

COMMIT;
