-- ============================================================
-- sql/438_c0_block_cancelled_payouts.sql
-- C0 — TAPAR LA FUGA DE DINERO de cancelaciones (diagnóstico 2026-07-05):
--
--   client_cancel_reservation (el único camino de cancelación con UI)
--   solo cambia status a 'cancelled' y NO toca payout_status; el cron
--   release_all_eligible_payments selecciona por payout_status='held'
--   sin filtrar canceladas → el dinero retenido de una reserva PAGADA
--   y CANCELADA se le LIBERA AL GRUPO 12h después de la fecha.
--
-- FIX (a prueba de 429 — NO redefine ninguna función de prod):
--   1. TRIGGER en reservations: cualquier transición a 'cancelled' de
--      una reserva pagada con payout held/half_released → 'blocked'.
--      Cubre TODOS los caminos de cancelación, presentes y futuros
--      (cliente, grupo cuando exista, admin, system_auto).
--   2. BACKFILL: canceladas-pagadas históricas que siguen en
--      held/half_released → 'blocked' antes de que el cron las tome.
--
--   'blocked' ya es el estado que usa mark_abandoned_reservations y
--   que el admin resuelve con sus herramientas (admin_held/release
--   manual) — el dinero queda protegido esperando el reembolso (C1)
--   o la decisión del admin. NO se toca dinero ya 'released' (eso es
--   terreno de disputas/427) ni 'refunded'.
--
-- ⚠️ DDL sobre reservations (tabla caliente con crons por minuto):
--   el bloque usa lock_timeout con reintentos. Córrelo a mitad de
--   minuto (segundos :20-:40). Si aún así marca timeout, reintenta.
-- ============================================================

-- ── PRE-CHECKS (solo lectura — córrelos ANTES y guarda el resultado) ─────────

-- P1: exposición ACTUAL de la fuga — canceladas pagadas aún liberables
SELECT COUNT(*)                                   AS reservas_en_riesgo,
       COALESCE(SUM(group_earnings), 0)           AS dinero_en_riesgo_mxn
FROM reservations
WHERE status = 'cancelled'
  AND payment_status IN ('paid', 'fully_paid', 'deposit_paid')
  AND payout_status IN ('held', 'half_released');

-- P2: fuga HISTÓRICA (informativo — canceladas cuyo dinero YA se liberó;
--     esas no se tocan aquí, son terreno de revisión manual/disputa)
SELECT id, folio, event_date, total_price, group_earnings, payout_status, cancelled_at
FROM reservations
WHERE status = 'cancelled'
  AND payment_status IN ('paid', 'fully_paid', 'deposit_paid')
  AND payout_status = 'released'
ORDER BY event_date DESC
LIMIT 20;

-- ── FIX ───────────────────────────────────────────────────────────────────────

DO $$
DECLARE
  v_intentos INT := 0;
BEGIN
  LOOP
    BEGIN
      SET LOCAL lock_timeout = '5s';

      -- 1. Función del trigger
      CREATE OR REPLACE FUNCTION public.block_payout_on_cancel()
      RETURNS TRIGGER
      LANGUAGE plpgsql
      AS $fn$
      BEGIN
        -- Reserva pagada que transiciona a 'cancelled' con dinero aún
        -- liberable → bloquear el payout. No toca released/refunded.
        IF NEW.status = 'cancelled'
           AND COALESCE(OLD.status, '') <> 'cancelled'
           AND NEW.payment_status IN ('paid', 'fully_paid', 'deposit_paid')
           AND COALESCE(NEW.payout_status, 'held') IN ('held', 'half_released')
        THEN
          NEW.payout_status := 'blocked';
        END IF;
        RETURN NEW;
      END;
      $fn$;

      -- 2. Trigger BEFORE UPDATE (modifica NEW en la misma escritura)
      DROP TRIGGER IF EXISTS trg_block_payout_on_cancel ON public.reservations;
      CREATE TRIGGER trg_block_payout_on_cancel
        BEFORE UPDATE OF status ON public.reservations
        FOR EACH ROW
        EXECUTE FUNCTION public.block_payout_on_cancel();

      EXIT;  -- éxito
    EXCEPTION WHEN lock_not_available OR deadlock_detected THEN
      v_intentos := v_intentos + 1;
      IF v_intentos >= 3 THEN RAISE; END IF;
      PERFORM pg_sleep(2);
    END;
  END LOOP;
END $$;

-- 3. Backfill: proteger las canceladas-pagadas que siguen liberables
UPDATE reservations
SET payout_status = 'blocked'
WHERE status = 'cancelled'
  AND payment_status IN ('paid', 'fully_paid', 'deposit_paid')
  AND payout_status IN ('held', 'half_released');

-- ── VERIFICACIONES ────────────────────────────────────────────────────────────

-- V1: trigger instalado y habilitado (tgenabled = 'O')
SELECT tgname, tgenabled,
       pg_get_triggerdef(oid) LIKE '%BEFORE UPDATE OF status%' AS es_before_update
FROM pg_trigger
WHERE tgrelid = 'public.reservations'::regclass
  AND tgname = 'trg_block_payout_on_cancel';
-- Esperado: trg_block_payout_on_cancel | O | true

-- V2: ya no queda NINGUNA cancelada-pagada liberable (el cron no las verá)
SELECT COUNT(*) AS deben_ser_cero
FROM reservations
WHERE status = 'cancelled'
  AND payment_status IN ('paid', 'fully_paid', 'deposit_paid')
  AND payout_status IN ('held', 'half_released');
-- Esperado: 0

-- V3 (funcional, sin tocar datos reales — simulación con ROLLBACK):
-- BEGIN;
-- UPDATE reservations SET status = 'cancelled'
-- WHERE id = (SELECT id FROM reservations
--             WHERE payment_status IN ('paid','fully_paid','deposit_paid')
--               AND payout_status = 'held' AND status <> 'cancelled'
--             LIMIT 1)
-- RETURNING id, status, payout_status;   -- payout_status debe salir 'blocked'
-- ROLLBACK;

SELECT '438_c0_block_cancelled_payouts.sql ejecutado ✅' AS status;
