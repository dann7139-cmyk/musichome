-- ══════════════════════════════════════════════════════════════════════════════
-- 31_profiles_readable.sql
-- Permite que usuarios autenticados lean perfiles de otros usuarios.
-- Necesario para que el lineup del grupo muestre nombres y fotos de miembros.
-- Ejecutar en Supabase SQL Editor.
-- ══════════════════════════════════════════════════════════════════════════════

-- Cualquier usuario autenticado puede leer cualquier perfil.
-- (Las apps necesitan esto para mostrar nombres/fotos de otros usuarios.)
DROP POLICY IF EXISTS "profiles_authenticated_read" ON public.profiles;
CREATE POLICY "profiles_authenticated_read"
  ON public.profiles FOR SELECT
  TO authenticated
  USING (true);

SELECT 'Perfiles legibles por usuarios autenticados ✅' AS status;
