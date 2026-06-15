-- ════════════════════════════════════════════════════════════════════
-- sql/355_document_auth_rpcs.sql
--
-- PROPÓSITO: Recuperar en el repositorio las RPCs que existían solo
-- en la instancia de Supabase y no en ningún archivo SQL local.
-- Sin este archivo, recrear la base desde cero rompe el primer login
-- (AuthContext llama get_my_profile) y el DashboardScreen del grupo
-- (llama get_my_group).
--
-- CÓMO SE DETECTARON:
--   - AuthContext.tsx:128 → supabase.rpc('get_my_profile').maybeSingle()
--   - DashboardScreen.tsx:529 → supabase.rpc('get_my_group').maybeSingle()
--   - ProfileScreen.tsx:199, BiddingScreen.tsx:198,265,
--     MemberEventsScreen.tsx:129 → también usan get_my_group
--   - Ninguna de las dos aparecía en sql/001 al 354.
--
-- CUERPOS: Extraídos de producción con:
--   SELECT routine_name, routine_definition
--   FROM information_schema.routines
--   WHERE routine_schema = 'public'
--     AND routine_name IN ('get_my_profile', 'get_my_group');
--
-- Ejecutar en Supabase SQL Editor (requiere privilegios de servicio).
-- ════════════════════════════════════════════════════════════════════


-- ── get_my_profile ───────────────────────────────────────────────────────────
--
-- Llamada en AuthContext para cargar el perfil del usuario autenticado.
-- Retorna 0 o 1 filas de public.profiles usando auth.uid().
-- No acepta parámetros — usa SECURITY DEFINER para evitar recursión en RLS.

DROP FUNCTION IF EXISTS public.get_my_profile();

CREATE OR REPLACE FUNCTION public.get_my_profile()
RETURNS SETOF public.profiles
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  -- TODO: pegar cuerpo extraído de producción aquí.
  -- El cuerpo debe ser equivalente a:
  --   RETURN QUERY SELECT * FROM public.profiles WHERE id = auth.uid();
  -- pero puede incluir joins adicionales (job_board_profiles, wallets, etc.)
  RAISE EXCEPTION '355: cuerpo de get_my_profile pendiente de pegar';
END;
$$;

GRANT EXECUTE ON FUNCTION public.get_my_profile() TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_my_profile() TO service_role;


-- ── get_my_group ─────────────────────────────────────────────────────────────
--
-- Llamada en DashboardScreen, ProfileScreen, BiddingScreen y
-- MemberEventsScreen. Retorna SETOF public.groups (0 o 1 filas).
-- Para role='group' → busca por owner_id = auth.uid().
-- Para role='talent' → puede buscar por job_invitations (membership).
-- SECURITY DEFINER necesario para evitar recursión RLS en profiles.
--
-- Nota DashboardScreen.tsx:539: "get_my_group retorna SETOF groups"
-- → el tipo de retorno es SETOF public.groups (no un tipo personalizado).

DROP FUNCTION IF EXISTS public.get_my_group();

CREATE OR REPLACE FUNCTION public.get_my_group()
RETURNS SETOF public.groups
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  -- TODO: pegar cuerpo extraído de producción aquí.
  -- Para role='group' el cuerpo base sería:
  --   RETURN QUERY SELECT * FROM public.groups WHERE owner_id = auth.uid() LIMIT 1;
  -- Para role='talent' puede incluir lógica de job_invitations membership.
  RAISE EXCEPTION '355: cuerpo de get_my_group pendiente de pegar';
END;
$$;

GRANT EXECUTE ON FUNCTION public.get_my_group() TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_my_group() TO service_role;


SELECT '355_document_auth_rpcs.sql — estructura lista, cuerpos pendientes ✅' AS status;
