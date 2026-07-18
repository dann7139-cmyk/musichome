-- ============================================================
-- sql/517_f1_rollback.sql — ROLLBACK COMPLETO DE F1
--
-- ⚠️ Ejecutar SOLO si decides revertir F1. Deja la base EXACTAMENTE
-- como antes de sql/514/516:
--   1. Quita el constraint de exclusión (si se creó).
--   2. Quita los triggers y funciones nuevos.
--   3. RESTAURA el trigger original de sql/434 (cuerpo completo).
--   4. Las columnas event_tz/busy_range se conservan (inofensivas,
--      nada las lee) — descomenta el paso 5 si también las quieres
--      fuera.
-- ============================================================

BEGIN;

-- 1. Constraint (si existe)
ALTER TABLE public.reservations DROP CONSTRAINT IF EXISTS excl_group_busy_range;

-- 2. Triggers y funciones nuevos de F1
DROP TRIGGER  IF EXISTS trg_01_set_busy_range        ON public.reservations;
DROP TRIGGER  IF EXISTS trg_recompute_range_on_extra ON public.extra_hours;
DROP TRIGGER  IF EXISTS trg_block_vs_reservations    ON public.group_unavailability;
DROP FUNCTION IF EXISTS public.set_reservation_busy_range();
DROP FUNCTION IF EXISTS public.recompute_range_on_extra();
DROP FUNCTION IF EXISTS public.block_vs_reservations();
DROP FUNCTION IF EXISTS public.count_events_local_day(UUID, DATE, UUID);
DROP FUNCTION IF EXISTS public.make_busy_range(DATE, TIME, TEXT, NUMERIC, INT);
DROP FUNCTION IF EXISTS public.tz_for_event(TEXT, TEXT);
DROP FUNCTION IF EXISTS public.estados_que_cuentan_limite();
DROP INDEX    IF EXISTS idx_res_busy_range;
-- estados_que_ocupan() se elimina al final (el trigger restaurado no la usa)

-- 3. RESTAURAR el trigger original (sql/434 — candado por día)
CREATE OR REPLACE FUNCTION public.enforce_group_availability()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.group_id IS NULL OR NEW.event_date IS NULL THEN
    RETURN NEW;
  END IF;

  IF TG_OP = 'UPDATE'
     AND OLD.group_id  IS NOT DISTINCT FROM NEW.group_id
     AND OLD.event_date IS NOT DISTINCT FROM NEW.event_date THEN
    RETURN NEW;
  END IF;

  PERFORM pg_advisory_xact_lock(hashtext(NEW.group_id::text || NEW.event_date::text));

  IF EXISTS (
    SELECT 1 FROM group_unavailability gu
    WHERE gu.group_id = NEW.group_id AND gu.date = NEW.event_date
  ) THEN
    RAISE EXCEPTION 'date_blocked';
  END IF;

  IF EXISTS (
    SELECT 1 FROM reservations r
    WHERE r.group_id = NEW.group_id
      AND r.event_date = NEW.event_date
      AND r.id <> NEW.id
      AND r.status IN ('pending','pending_payment','pending_group_confirmation',
                       'confirmed','in_progress')
  ) THEN
    RAISE EXCEPTION 'date_taken';
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_02_enforce_group_availability ON public.reservations;
CREATE TRIGGER trg_enforce_group_availability
  BEFORE INSERT OR UPDATE OF group_id, event_date
  ON public.reservations
  FOR EACH ROW EXECUTE FUNCTION public.enforce_group_availability();

DROP FUNCTION IF EXISTS public.estados_que_ocupan();

-- 4. (opcional) columnas — inofensivas si se quedan
-- ALTER TABLE public.reservations DROP COLUMN IF EXISTS busy_range;
-- ALTER TABLE public.reservations DROP COLUMN IF EXISTS event_tz;

COMMIT;

SELECT '517_f1_rollback.sql — F1 revertido; trigger original 434 restaurado' AS status;
