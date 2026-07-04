-- ============================================================
-- sql/434_unify_availability_trigger.sql
-- LOTE 2 · Unificar los DOS triggers de disponibilidad en UNO
--
-- Convivían en reservations:
--   · trigger_prevent_double_booking (sql/100): INSERT + UPDATE de
--     group_id/event_date. Bloquea si hay reserva en estados
--     NOT IN (cancelled, rejected, expired) → INCLUYE completed.
--     Error: mensaje largo en español (NO mapeable en frontend).
--   · trg_enforce_group_availability (sql/431): solo INSERT.
--     date_blocked + date_taken (mapeables) + advisory lock.
--
-- Problemas de la convivencia:
--   1. Si el único conflicto del día es una reserva COMPLETED, el 431
--      pasa pero el viejo revienta con el mensaje crudo → el mapeo
--      del frontend no lo captura.
--   2. El viejo bloquea "2ª tocada tras evento completado el mismo
--      día" — exactamente lo que el Lote 3 va a permitir.
--   3. El 431 no cubría UPDATE (reprogramación) — el viejo sí.
--
-- FIX: un solo trigger — el 431 extendido a INSERT OR UPDATE OF
--   group_id/event_date (con exclusión del propio id para updates)
--   — y RETIRO del viejo (trigger + función + su pre-check queda
--   cubierto: client_accept_proposal ya valida antes con
--   'group_unavailable', y el índice de soporte de sql/100 SE QUEDA).
--
-- ⚠️ DDL sobre reservations (tabla caliente): correr a mitad de
--   minuto (segundos :20-:40); si sale lock timeout, reintentar.
-- ============================================================

BEGIN;
SET LOCAL lock_timeout = '5s';

-- 1. Función unificada (v2): igual al 431 + exclusión del propio id
--    para que los UPDATE no se auto-detecten como conflicto
CREATE OR REPLACE FUNCTION public.enforce_group_availability()
RETURNS TRIGGER
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NEW.group_id IS NULL OR NEW.event_date IS NULL THEN
    RETURN NEW;
  END IF;

  IF NEW.status IS NOT NULL AND NEW.status NOT IN (
    'pending','pending_payment','pending_group_confirmation',
    'accepted','confirmed','in_progress','en_negociacion'
  ) THEN
    RETURN NEW;
  END IF;

  -- En UPDATE, si no cambió ni grupo ni fecha, no validar
  IF TG_OP = 'UPDATE'
     AND NEW.group_id = OLD.group_id
     AND NEW.event_date = OLD.event_date THEN
    RETURN NEW;
  END IF;

  PERFORM pg_advisory_xact_lock(hashtext(NEW.group_id::text || NEW.event_date::text));

  IF EXISTS (
    SELECT 1 FROM group_unavailability
    WHERE group_id = NEW.group_id AND date = NEW.event_date
  ) THEN
    RAISE EXCEPTION 'date_blocked';
  END IF;

  IF EXISTS (
    SELECT 1 FROM reservations
    WHERE group_id   = NEW.group_id
      AND event_date = NEW.event_date
      AND id        != COALESCE(NEW.id, '00000000-0000-0000-0000-000000000000'::UUID)
      AND status IN ('pending','pending_payment','pending_group_confirmation',
                     'confirmed','in_progress')
  ) THEN
    RAISE EXCEPTION 'date_taken';
  END IF;

  RETURN NEW;
END;
$$;

-- 2. Trigger unificado: ahora también cubre reprogramaciones
DROP TRIGGER IF EXISTS trg_enforce_group_availability ON public.reservations;
CREATE TRIGGER trg_enforce_group_availability
  BEFORE INSERT OR UPDATE OF group_id, event_date ON public.reservations
  FOR EACH ROW
  EXECUTE FUNCTION public.enforce_group_availability();

-- 3. Retirar el trigger viejo (el índice idx_reservations_group_date_active
--    de sql/100 SE QUEDA — sigue sirviendo a las consultas del nuevo)
DROP TRIGGER IF EXISTS trigger_prevent_double_booking ON public.reservations;
DROP FUNCTION IF EXISTS public.prevent_double_booking();

COMMIT;

-- ── Verificaciones ────────────────────────────────────────────────────────────
-- V1: queda UN solo trigger de disponibilidad, que cubre INSERT y UPDATE
SELECT tgname, tgenabled,
       pg_get_triggerdef(oid) LIKE '%INSERT OR UPDATE%' AS cubre_update
FROM pg_trigger
WHERE tgrelid = 'public.reservations'::regclass
  AND tgname IN ('trg_enforce_group_availability', 'trigger_prevent_double_booking');
-- Esperado: SOLO trg_enforce_group_availability | 'O' | true

-- V2: la función excluye el propio id (updates seguros)
SELECT
  routine_definition LIKE '%id        != COALESCE(NEW.id%' AS excluye_propio_id,
  routine_definition LIKE '%TG_OP = ''UPDATE''%'            AS optimiza_updates
FROM information_schema.routines
WHERE routine_schema = 'public' AND routine_name = 'enforce_group_availability';
-- Esperado: true | true

SELECT '434_unify_availability_trigger.sql ejecutado ✅' AS status;
