-- ============================================================
-- sql/20_get_my_profile_rpc.sql
-- RPC get_my_profile() — SECURITY DEFINER
--
-- Función que devuelve el perfil del usuario autenticado
-- sin pasar por RLS (evita recursión infinita en policies).
-- Usada por AuthContext.tsx en lugar de consultar profiles directo.
--
-- Ejecutar en: Supabase Dashboard → SQL Editor
-- ============================================================

-- ── 1. Crear (o reemplazar) la función ──────────────────────────────────────
-- Primero eliminar si existe (puede tener un tipo de retorno diferente)
DROP FUNCTION IF EXISTS public.get_my_profile();

CREATE OR REPLACE FUNCTION public.get_my_profile()
RETURNS public.profiles
LANGUAGE sql
SECURITY DEFINER
STABLE
SET search_path = public
AS $$
  SELECT *
  FROM public.profiles
  WHERE id = auth.uid()
  LIMIT 1;
$$;

-- Permitir que cualquier usuario autenticado ejecute esta función
GRANT EXECUTE ON FUNCTION public.get_my_profile() TO authenticated;

-- ── 2. Verificación ──────────────────────────────────────────────────────────
SELECT
  proname        AS funcion,
  prosecdef      AS security_definer,
  provolatile    AS volatilidad   -- 's' = STABLE
FROM pg_proc
WHERE proname = 'get_my_profile'
  AND pronamespace = 'public'::regnamespace;

SELECT 'get_my_profile() creada correctamente ✅' AS status;
