-- ============================================================
-- 211_events_talent_rls.sql
-- Permite al talento invitado leer el evento y la reserva
-- asociados a su invitación de trabajo.
-- ============================================================

-- Talento puede leer eventos a los que fue invitado
DROP POLICY IF EXISTS "events_invited_talent_select" ON public.events;
CREATE POLICY "events_invited_talent_select" ON public.events
  FOR SELECT USING (
    EXISTS (
      SELECT 1 FROM public.job_invitations
      WHERE event_id = events.id
        AND invited_user_id = auth.uid()
    )
  );

-- Talento puede leer la reserva ligada a su evento invitado
DROP POLICY IF EXISTS "reservations_invited_talent_select" ON public.reservations;
CREATE POLICY "reservations_invited_talent_select" ON public.reservations
  FOR SELECT USING (
    event_id IS NOT NULL AND EXISTS (
      SELECT 1 FROM public.job_invitations
      WHERE event_id = reservations.event_id
        AND invited_user_id = auth.uid()
    )
  );

SELECT 'RLS para talento invitado creado ✅' AS status;
