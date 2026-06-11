-- ============================================================
-- sql/259_profiles_country.sql
--
-- Agrega la columna `country TEXT` a profiles para permitir
-- filtrado geográfico por país en talentos y clientes,
-- de la misma forma que ya existe en groups.
--
-- Necesario para el filtro país/estado en el panel admin.
-- Los perfiles existentes quedan con country = NULL (no se rompe
-- nada — el filtro simplemente no los mostrará como opción).
--
-- IDEMPOTENTE: Sí (ADD COLUMN IF NOT EXISTS).
-- ROLLBACK: ALTER TABLE public.profiles DROP COLUMN IF EXISTS country;
-- ============================================================

ALTER TABLE public.profiles
  ADD COLUMN IF NOT EXISTS country TEXT;

COMMENT ON COLUMN public.profiles.country IS
  'País del perfil (ej. "México", "Colombia"). NULL = no especificado.';

-- Verificación
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE  table_schema = 'public'
      AND  table_name   = 'profiles'
      AND  column_name  = 'country'
  ) THEN
    RAISE EXCEPTION '[259] profiles.country no encontrada ❌';
  END IF;
  RAISE NOTICE '[259] profiles.country: existe ✅';
END;
$$;

SELECT '259_profiles_country.sql aplicado correctamente ✅' AS status;
