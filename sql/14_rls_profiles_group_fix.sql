-- ============================================================
-- DARICEFY - 14_rls_profiles_group_fix.sql
-- FASE 2 PASO 2 — Fix: grupos no pueden leer perfil del cliente
--
-- Problema: profiles_select_own solo permite ver el propio perfil.
-- Un group owner que abre ConfirmBookingScreen no puede leer el
-- perfil del cliente que hizo la reserva → clientProfile = null.
--
-- Solución: política adicional que permite a un owner de grupo
-- leer el perfil de cualquier cliente que tenga una reserva con
-- alguno de sus grupos.
-- ============================================================

DROP POLICY IF EXISTS "profiles_group_reads_client" ON public.profiles;

CREATE POLICY "profiles_group_reads_client"
  ON public.profiles FOR SELECT
  USING (
    EXISTS (
      SELECT 1
      FROM public.reservations r
      JOIN public.groups g ON g.id = r.group_id
      WHERE r.client_id = profiles.id
        AND g.owner_id = auth.uid()
    )
  );

SELECT 'Política profiles_group_reads_client creada ✅' AS status;
