-- ════════════════════════════════════════════════════════════════════════════
-- 127_contact_protection_extend.sql
-- Extiende el blindaje de contacto a event_requests.comments
-- y a las notas de propuestas (proposal_data->>'notes').
--
-- ESTADO PREVIO (ya implementado):
--   42  → contact_violation_logs
--   112 → text_has_contact_info() + trigger en reservation_messages
--          + dirección enmascarada + auto-advertencias
--   phoneFilter.ts → filtro client-side
--   ChatScreen.tsx → bloqueo UI + log
--
-- LO QUE AGREGA ESTE ARCHIVO:
--   1. Trigger BEFORE INSERT/UPDATE en event_requests
--      bloquea comentarios con datos de contacto.
--   2. Trigger BEFORE INSERT en reservations
--      bloquea proposal_data->>'notes' con datos de contacto.
--
-- Ejecutar DESPUÉS de 126_surge_pricing.sql
-- ════════════════════════════════════════════════════════════════════════════


-- ── 1. Trigger en event_requests.comments ────────────────────────────────────

CREATE OR REPLACE FUNCTION public.trg_filter_event_request_comments()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF public.text_has_contact_info(NEW.comments) THEN
    RAISE EXCEPTION
      'contact_info_blocked: Por seguridad no puedes compartir datos de contacto en los comentarios.';
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_filter_request_comments ON public.event_requests;
CREATE TRIGGER trg_filter_request_comments
  BEFORE INSERT OR UPDATE OF comments ON public.event_requests
  FOR EACH ROW
  EXECUTE FUNCTION public.trg_filter_event_request_comments();


-- ── 2. Trigger en proposal_data notes (reservations) ─────────────────────────

CREATE OR REPLACE FUNCTION public.trg_filter_proposal_notes()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_notes TEXT;
BEGIN
  v_notes := NEW.proposal_data->>'notes';
  IF public.text_has_contact_info(v_notes) THEN
    RAISE EXCEPTION
      'contact_info_blocked: Por seguridad no puedes compartir datos de contacto en las notas.';
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_filter_proposal_notes ON public.event_requests;
CREATE TRIGGER trg_filter_proposal_notes
  BEFORE INSERT OR UPDATE OF proposal_data ON public.event_requests
  FOR EACH ROW
  EXECUTE FUNCTION public.trg_filter_proposal_notes();


SELECT '127_contact_protection_extend.sql ejecutado ✅' AS status;
SELECT 'Trigger: event_requests.comments — bloquea datos de contacto' AS t1;
SELECT 'Trigger: event_requests.proposal_data->notes — bloquea datos de contacto' AS t2;
