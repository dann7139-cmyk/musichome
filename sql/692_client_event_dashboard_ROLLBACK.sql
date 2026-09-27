-- ═══════════════════════════════════════════════════════════════════════════
-- ROLLBACK de sql/692 — SOLO en caso de reversión deliberada
-- ═══════════════════════════════════════════════════════════════════════════
--
-- sql/692 fue puramente ADITIVO y de SOLO LECTURA: creó UNA función que no
-- escribe nada. Revertirlo es borrarla.
--
-- CONSECUENCIA: MyEventScreen dejaría de cargar (recibiría PGRST202). Nada más
-- se afecta: ninguna reserva, cotización, evento ni total cambia, porque esta
-- función nunca escribió nada.
-- ═══════════════════════════════════════════════════════════════════════════

BEGIN;

DROP FUNCTION IF EXISTS public.client_get_event_dashboard(UUID);

NOTIFY pgrst, 'reload schema';

COMMIT;
