-- ============================================================
-- sql/440_close_dispatches_on_request_fulfilled.sql
-- BUG: una solicitud exprés aceptada/pagada (event_requests.status ya no
-- es 'open') deja sus express_dispatches en 'pending_broadcast' — nadie
-- los cierra. El carrusel del grupo los sigue mostrando con "Cotizar"
-- aunque el evento ya sea una reserva confirmada.
--
-- FIX:
--   1) TRIGGER en event_requests: cuando el status deja el conjunto
--      "abierto", marca sus dispatches activos como 'taken' → dispara
--      el realtime UPDATE → el carrusel los quita (en TODOS los grupos).
--   2) BACKFILL: cierra los dispatches ya obsoletos (limpia el estado
--      actual, incluido el que se ve hoy en el dashboard).
--
-- El frontend ya filtra por request.status (ExpressContext), esto es el
-- lado servidor para que sea consistente y quite tarjetas ya montadas.
-- ============================================================

BEGIN;

CREATE OR REPLACE FUNCTION public.close_dispatches_on_request_change()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  -- La solicitud dejó de estar abierta (aceptada / cancelada / expirada)
  IF NEW.status IS DISTINCT FROM OLD.status
     AND NEW.status NOT IN ('open', 'en_negociacion', 'negotiating')
  THEN
    UPDATE public.express_dispatches
    SET status = 'taken'
    WHERE request_id = NEW.id
      AND status IN ('pending_broadcast', 'quoting');
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_close_dispatches_on_request_change ON public.event_requests;
CREATE TRIGGER trg_close_dispatches_on_request_change
  AFTER UPDATE OF status ON public.event_requests
  FOR EACH ROW
  EXECUTE FUNCTION public.close_dispatches_on_request_change();

-- Backfill: cerrar dispatches activos cuya solicitud ya no está abierta
UPDATE public.express_dispatches ed
SET status = 'taken'
FROM public.event_requests er
WHERE ed.request_id = er.id
  AND ed.status IN ('pending_broadcast', 'quoting')
  AND er.status NOT IN ('open', 'en_negociacion', 'negotiating');

COMMIT;

-- ── PRE-CHECK (informativo — cuántos dispatches obsoletos había) ──────────────
-- (Córrelo ANTES del backfill si quieres ver el tamaño del problema; tras
--  correr el archivo, este SELECT debe dar 0.)
SELECT COUNT(*) AS dispatches_obsoletos_restantes
FROM public.express_dispatches ed
JOIN public.event_requests er ON er.id = ed.request_id
WHERE ed.status IN ('pending_broadcast', 'quoting')
  AND er.status NOT IN ('open', 'en_negociacion', 'negotiating');
-- Esperado: 0

-- ── VERIFICACIONES ────────────────────────────────────────────────────────────
-- V1: trigger instalado y habilitado
SELECT tgname, tgenabled
FROM pg_trigger
WHERE tgrelid = 'public.event_requests'::regclass
  AND tgname  = 'trg_close_dispatches_on_request_change';
-- Esperado: trg_close_dispatches_on_request_change | O

SELECT '440_close_dispatches_on_request_fulfilled.sql ejecutado ✅' AS status;
