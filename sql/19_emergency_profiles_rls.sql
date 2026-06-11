-- ============================================================
-- sql/19_emergency_profiles_rls.sql
-- EMERGENCY FIX — elimina y recrea TODAS las policies de profiles
-- desde cero sin ninguna recursión posible
--
-- Ejecutar en: Supabase Dashboard → SQL Editor
-- ============================================================

-- ── 1. Eliminar TODAS las policies de profiles ──────────────────────────────
DO $$
DECLARE
  r RECORD;
BEGIN
  FOR r IN
    SELECT policyname FROM pg_policies WHERE tablename = 'profiles'
  LOOP
    EXECUTE format('DROP POLICY IF EXISTS %I ON public.profiles', r.policyname);
    RAISE NOTICE 'Eliminada policy: %', r.policyname;
  END LOOP;
END;
$$;


-- ── 2. Función is_admin() — SECURITY DEFINER (sin recursión) ────────────────
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


-- ── 3. Recrear policies de profiles limpias ─────────────────────────────────

-- a) Cada usuario lee su propio perfil
CREATE POLICY "profiles_select_own"
  ON public.profiles FOR SELECT
  USING (id = auth.uid());

-- b) Cada usuario actualiza su propio perfil
CREATE POLICY "profiles_update_own"
  ON public.profiles FOR UPDATE
  USING (id = auth.uid());

-- c) Admin lee TODOS los perfiles (usa is_admin → sin recursión)
CREATE POLICY "profiles_admin_select"
  ON public.profiles FOR SELECT
  USING (public.is_admin());

-- d) Admin actualiza cualquier perfil
CREATE POLICY "profiles_admin_update"
  ON public.profiles FOR UPDATE
  USING (public.is_admin());

-- e) Grupos pueden leer perfiles de clientes que tienen reservas con ellos
CREATE POLICY "profiles_group_reads_client"
  ON public.profiles FOR SELECT
  USING (
    EXISTS (
      SELECT 1 FROM public.reservations r
      JOIN public.groups g ON g.id = r.group_id
      WHERE r.client_id = profiles.id
        AND g.owner_id = auth.uid()
    )
  );

-- f) Clientes pueden leer perfiles de grupos (para ver info de su reserva)
CREATE POLICY "profiles_client_reads_group_owner"
  ON public.profiles FOR SELECT
  USING (
    EXISTS (
      SELECT 1 FROM public.groups g
      JOIN public.reservations r ON r.group_id = g.id
      WHERE g.owner_id = profiles.id
        AND r.client_id = auth.uid()
    )
  );


-- ── 4. Verificación final ────────────────────────────────────────────────────

SELECT policyname, cmd
FROM pg_policies
WHERE tablename = 'profiles'
ORDER BY policyname;

SELECT 'Policies de profiles recreadas sin recursión ✅' AS status;
