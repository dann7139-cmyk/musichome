-- ============================================================
-- sql/23_fix_groups_rls_recursion.sql
-- Fix: "infinite recursion detected in policy for relation groups"
--
-- El problema ocurre porque la policy jinv_insert en job_invitations
-- hace un SELECT a groups, pero groups también tiene RLS activo.
-- Al evaluar el SELECT, Supabase evalúa las policies de groups,
-- que a su vez pueden disparar otra query que regresa a groups → loop.
--
-- Solución: función SECURITY DEFINER que consulta groups sin RLS.
-- Las policies de job_invitations llaman a esta función en lugar
-- de hacer el SELECT directo.
--
-- Ejecutar en: Supabase Dashboard → SQL Editor
-- ============================================================

-- ── 1. Función SECURITY DEFINER: comprueba ownership sin RLS ────────────────
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

-- ── 2. Reemplazar policies de job_invitations que consultaban groups ─────────

-- INSERT: solo el dueño del grupo puede enviar invitaciones
DROP POLICY IF EXISTS "jinv_insert" ON public.job_invitations;
CREATE POLICY "jinv_insert"
  ON public.job_invitations FOR INSERT
  WITH CHECK (public.is_group_owner(group_id));

-- SELECT: el talento invitado O el dueño del grupo pueden ver
DROP POLICY IF EXISTS "jinv_select" ON public.job_invitations;
CREATE POLICY "jinv_select"
  ON public.job_invitations FOR SELECT
  USING (
    invited_user_id = auth.uid()
    OR public.is_group_owner(group_id)
  );

-- DELETE: solo el dueño del grupo puede retirar una invitación pendiente
DROP POLICY IF EXISTS "jinv_delete" ON public.job_invitations;
CREATE POLICY "jinv_delete"
  ON public.job_invitations FOR DELETE
  USING (public.is_group_owner(group_id));

-- UPDATE y admin siguen igual (no tienen recursión)
-- jinv_update: solo el invited_user puede aceptar/rechazar
-- jinv_admin:  acceso total para admins (ya definido en 10_job_board.sql)

-- ── 3. Verificación ──────────────────────────────────────────────────────────
SELECT
  polname AS policy,
  polcmd  AS command
FROM pg_policy
WHERE polrelid = 'public.job_invitations'::regclass
ORDER BY polname;

SELECT 'Fix recursion groups RLS aplicado correctamente ✅' AS status;
