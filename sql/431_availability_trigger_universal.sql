-- ============================================================
-- sql/431_availability_trigger_universal.sql
-- LOTE 2 · Candado UNIVERSAL de disponibilidad
--
-- Trigger BEFORE INSERT en reservations: valida día bloqueado y día
-- ocupado EN LA PUERTA DE LA TABLA — cubre TODAS las rutas de
-- creación de reservas de un solo golpe:
--   · create_booking_with_event (defensa doble con el candado 430,
--     que se queda como pre-check amable con jsonb)
--   · client_accept_proposal (propuestas exprés/abiertas)
--   · el INSERT client-side de ClientQuoteDetailScreen (aceptar
--     cotización — hoy NO pasaba por ningún RPC: puerta trasera)
--   · cualquier ruta futura, por construcción.
--
-- Errores: RAISE EXCEPTION con mensaje EXACTO 'date_blocked' /
-- 'date_taken' → mapeable en frontend, y los RPCs con handler
-- EXCEPTION WHEN OTHERS lo devuelven como {ok:false, error:'date_…'}.
--
-- Solo valida reservas que NACEN activas (imports/cancelled pasan).
-- NO toca: candado del 430, available_now, CalendarScreen, extras.
-- ============================================================

BEGIN;

CREATE OR REPLACE FUNCTION public.enforce_group_availability()
RETURNS TRIGGER
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  -- Sin grupo o sin fecha: nada que validar
  IF NEW.group_id IS NULL OR NEW.event_date IS NULL THEN
    RETURN NEW;
  END IF;

  -- Solo estados que nacen activos (una importación de histórico
  -- completed/cancelled no debe rebotar)
  IF NEW.status IS NOT NULL AND NEW.status NOT IN (
    'pending','pending_payment','pending_group_confirmation',
    'accepted','confirmed','in_progress','en_negociacion'
  ) THEN
    RETURN NEW;
  END IF;

  -- Anti-carreras: serializa inserciones del mismo grupo+fecha
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
      AND status IN ('pending','pending_payment','pending_group_confirmation',
                     'confirmed','in_progress')
  ) THEN
    RAISE EXCEPTION 'date_taken';
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_enforce_group_availability ON public.reservations;

CREATE TRIGGER trg_enforce_group_availability
  BEFORE INSERT ON public.reservations
  FOR EACH ROW
  EXECUTE FUNCTION public.enforce_group_availability();

COMMIT;

-- ── Verificaciones ────────────────────────────────────────────────────────────
-- V1: trigger instalado
SELECT tgname, tgenabled FROM pg_trigger
WHERE tgname = 'trg_enforce_group_availability';
-- Esperado: 1 fila, tgenabled = 'O'

-- V2: la función valida ambos casos
SELECT
  routine_definition LIKE '%date_blocked%' AS valida_bloqueo,
  routine_definition LIKE '%date_taken%'   AS valida_ocupado,
  routine_definition LIKE '%en_negociacion%' AS cubre_propuestas
FROM information_schema.routines
WHERE routine_schema = 'public' AND routine_name = 'enforce_group_availability';
-- Esperado: true | true | true

-- V3 (funcional, se revierte solo): intentar insertar sobre día bloqueado
-- BEGIN;
--   INSERT INTO group_unavailability (group_id, date)
--   SELECT id, '2027-01-15' FROM groups LIMIT 1;
--   INSERT INTO reservations (group_id, client_id, event_date, status, total_price)
--   SELECT id, owner_id, '2027-01-15', 'pending', 100 FROM groups LIMIT 1;
-- ROLLBACK;
-- Esperado: ERROR date_blocked (y el ROLLBACK limpia el bloqueo de prueba)

SELECT '431_availability_trigger_universal.sql ejecutado ✅' AS status;
