-- ============================================================
-- sql/18_fix_profiles_admin_rls.sql
-- FIX: infinite recursion en policy "profiles_admin_select"
--
-- Causa: la policy consultaba SELECT FROM profiles dentro
-- de una policy de profiles → bucle infinito.
--
-- Solución: función SECURITY DEFINER que bypasea RLS
-- al leer profiles, rompiendo el ciclo.
--
-- Ejecutar en: Supabase Dashboard → SQL Editor
-- ============================================================

-- ── 1. Eliminar la policy recursiva ────────────────────────────────────────

DROP POLICY IF EXISTS "profiles_admin_select" ON public.profiles;


-- ── 2. Función helper is_admin() — SECURITY DEFINER ────────────────────────
--    Al correr como owner del schema (bypasea RLS) no hay recursión.

CREATE OR REPLACE FUNCTION public.is_admin()
RETURNS boolean
LANGUAGE sql
SECURITY DEFINER
STABLE
SET search_path = public
AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.profiles
    WHERE id = auth.uid() AND role = 'admin'
  );
$$;


-- ── 3. Recrear la policy usando el helper (sin recursión) ──────────────────

CREATE POLICY "profiles_admin_select"
  ON public.profiles
  FOR SELECT
  USING (public.is_admin());


-- ── 4. Actualizar las otras policies de sql/16 para consistencia ───────────
--    (job_board_profiles y job_invitations no tienen recursión,
--     pero se actualiza por legibilidad y performance)

DROP POLICY IF EXISTS "job_board_profiles_admin_select" ON public.job_board_profiles;
CREATE POLICY "job_board_profiles_admin_select"
  ON public.job_board_profiles
  FOR SELECT
  USING (public.is_admin());

DROP POLICY IF EXISTS "job_invitations_admin_select" ON public.job_invitations;
CREATE POLICY "job_invitations_admin_select"
  ON public.job_invitations
  FOR SELECT
  USING (public.is_admin());


-- ── 5. Verificación ────────────────────────────────────────────────────────

-- Confirma que la función existe
SELECT proname, prosecdef
FROM pg_proc
WHERE proname = 'is_admin' AND pronamespace = 'public'::regnamespace;

-- Confirma que la policy quedó correcta (no debe contener "FROM profiles")
SELECT policyname, qual
FROM pg_policies
WHERE tablename = 'profiles' AND policyname = 'profiles_admin_select';

SELECT 'Fix recursión aplicado ✅' AS status;
