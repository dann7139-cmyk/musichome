-- ============================================================
-- sql/218_fix_invitations_rls.sql
-- Fixes:
--   1. Re-aplica políticas anti-recursión de job_invitations
--      (mismo contenido que 23_fix_groups_rls_recursion.sql,
--      seguro ejecutar aunque ya esté aplicado)
--   2. Permite al talento leer eventos de sus invitaciones
--   3. Diagnóstico de grupo inactivo
-- Ejecutar en: Supabase Dashboard → SQL Editor
-- ============================================================

-- ── 1. Función SECURITY DEFINER para ownership sin recursión ─────────────────
CREATE OR REPLACE FUNCTION public.is_group_owner(p_group_id UUID)
RETURNS BOOLEAN
LANGUAGE sql
SECURITY DEFINER
STABLE
SET search_path = public
AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.groups
    WHERE id = p_group_id AND owner_id = auth.uid()
  );
$$;
GRANT EXECUTE ON FUNCTION public.is_group_owner(UUID) TO authenticated;

-- ── 2. Políticas de job_invitations sin recursión ────────────────────────────
DROP POLICY IF EXISTS "jinv_insert" ON public.job_invitations;
CREATE POLICY "jinv_insert"
  ON public.job_invitations FOR INSERT
  WITH CHECK (public.is_group_owner(group_id));

DROP POLICY IF EXISTS "jinv_select" ON public.job_invitations;
CREATE POLICY "jinv_select"
  ON public.job_invitations FOR SELECT
  USING (
    invited_user_id = auth.uid()
    OR public.is_group_owner(group_id)
  );

DROP POLICY IF EXISTS "jinv_delete" ON public.job_invitations;
CREATE POLICY "jinv_delete"
  ON public.job_invitations FOR DELETE
  USING (public.is_group_owner(group_id));

-- UPDATE: el talento invitado puede aceptar/rechazar
DROP POLICY IF EXISTS "jinv_update" ON public.job_invitations;
CREATE POLICY "jinv_update"
  ON public.job_invitations FOR UPDATE
  USING (invited_user_id = auth.uid())
  WITH CHECK (status IN ('accepted', 'rejected'));

-- Admin acceso total (idempotente)
DROP POLICY IF EXISTS "jinv_admin" ON public.job_invitations;
CREATE POLICY "jinv_admin"
  ON public.job_invitations FOR ALL
  USING (
    EXISTS (SELECT 1 FROM public.profiles WHERE id = auth.uid() AND role = 'admin')
  );

-- ── 3. El talento puede leer eventos a los que fue invitado ──────────────────
-- Sin esto el embed `event:events(...)` en JobBoardScreen devuelve null
-- y el talento no ve la fecha/dirección de la tocada.
DROP POLICY IF EXISTS "events_talent_select" ON public.events;
CREATE POLICY "events_talent_select"
  ON public.events FOR SELECT
  USING (
    EXISTS (
      SELECT 1 FROM public.job_invitations ji
      WHERE ji.event_id = events.id
        AND ji.invited_user_id = auth.uid()
    )
  );

-- ── 4. Diagnóstico: grupos inactivos o sin ciudad ────────────────────────────
-- Ejecuta esto para encontrar el grupo "Daniel Rivera":
--
-- SELECT id, name, is_active, city, state, owner_id, created_at
-- FROM public.groups
-- WHERE name ILIKE '%daniel%' OR name ILIKE '%rivera%'
-- ORDER BY created_at DESC
-- LIMIT 10;
--
-- Si aparece con is_active = false, actívalo:
-- UPDATE public.groups SET is_active = true WHERE name ILIKE '%Daniel Rivera%';
--
-- Si NO aparece, el grupo nunca completó su perfil (no existe en groups table).
-- Busca al usuario en profiles:
-- SELECT id, full_name, email, role FROM public.profiles
-- WHERE full_name ILIKE '%daniel%' AND role = 'group' LIMIT 5;
--
-- Si lo encuentras, crea su entrada en groups manualmente:
-- INSERT INTO public.groups (owner_id, name, genre, city, is_active)
-- SELECT p.id, p.full_name, 'grupo', null, true
-- FROM public.profiles p
-- WHERE p.full_name ILIKE '%Daniel Rivera%' AND p.role = 'group';

SELECT 'Fix invitations RLS + events_talent_select aplicado ✅' AS status;
