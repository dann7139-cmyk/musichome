-- ═══════════════════════════════════════════════════════════════════════════
-- ROLLBACK de 710 — devuelve `event_requests` al estado permisivo anterior
-- ═══════════════════════════════════════════════════════════════════════════
-- ⚠️  Correrlo REABRE el agujero: `er_service_all` vuelve a aplicar a PUBLIC con
-- USING(true)/WITH CHECK(true), y `anon` recupera los grants de tabla. Con eso,
-- cualquiera con la publishable key vuelve a poder leer, insertar, modificar y
-- borrar solicitudes de eventos ajenas. Solo tiene sentido si el hardening rompe
-- un flujo real que no se detectó.
-- ═══════════════════════════════════════════════════════════════════════════

BEGIN;

DROP POLICY IF EXISTS "er_group_reservation_select" ON public.event_requests;
DROP POLICY IF EXISTS "er_group_dispatched_select"  ON public.event_requests;
DROP POLICY IF EXISTS "er_group_genre_split_select" ON public.event_requests;

DROP POLICY IF EXISTS "er_service_all" ON public.event_requests;
CREATE POLICY "er_service_all"
  ON public.event_requests
  FOR ALL
  USING (true)
  WITH CHECK (true);

DROP POLICY IF EXISTS "groups_see_open_requests" ON public.event_requests;
CREATE POLICY "groups_see_open_requests"
  ON public.event_requests
  FOR SELECT
  TO authenticated
  USING (
    status = 'open'
    AND expires_at > now()
    AND (
      express_window_until IS NULL
      OR express_window_until < now()
      OR EXISTS (
        SELECT 1
        FROM public.express_dispatches ed
        JOIN public.groups g ON g.id = ed.group_id
        WHERE ed.request_id = event_requests.id
          AND g.owner_id    = auth.uid()
          AND ed.status     <> ALL (ARRAY['ignored'::text, 'expired'::text, 'taken'::text])
      )
    )
  );

GRANT SELECT, INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER
  ON public.event_requests TO anon;

COMMENT ON TABLE public.event_requests IS NULL;

COMMIT;
