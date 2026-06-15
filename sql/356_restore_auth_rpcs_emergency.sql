-- ════════════════════════════════════════════════════════════════════
-- sql/356_restore_auth_rpcs_emergency.sql
--
-- EMERGENCIA: sql/355 reemplazó get_my_profile y get_my_group con
-- RAISE EXCEPTION placeholders. Login roto en producción.
--
-- Este archivo reconstruye ambas funciones desde el codebase TS:
--   - AuthContext.tsx:128   → get_my_profile
--   - DashboardScreen.tsx:529, ProfileScreen.tsx:199,
--     BiddingScreen.tsx:198, MemberEventsScreen.tsx:129
--                           → get_my_group
--
-- Ejecutar INMEDIATAMENTE en Supabase SQL Editor.
-- ════════════════════════════════════════════════════════════════════


-- ── get_my_profile ───────────────────────────────────────────────────────────
--
-- Retorna el perfil completo del usuario autenticado.
-- SECURITY DEFINER evita recursión en la política RLS de profiles
-- (que también llama a auth.uid()).
-- Llamada con .maybeSingle() → devuelve 0 o 1 filas.

CREATE OR REPLACE FUNCTION public.get_my_profile()
RETURNS SETOF public.profiles
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  RETURN QUERY
  SELECT *
  FROM   public.profiles
  WHERE  id = auth.uid();
END;
$$;

GRANT EXECUTE ON FUNCTION public.get_my_profile() TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_my_profile() TO service_role;


-- ── get_my_group ─────────────────────────────────────────────────────────────
--
-- Retorna SETOF public.groups (0 o 1 filas) para el usuario autenticado.
-- Lógica en dos pasos:
--   1. Dueño del grupo: groups.owner_id = auth.uid()
--   2. Talento miembro: job_invitations con invitation_type='membership'
--      y status='accepted' (para MemberEventsScreen / TalentStack)
--
-- SECURITY DEFINER necesario para evitar recursión RLS y para que
-- el talento pueda leer la fila del grupo que no le pertenece.
-- Llamada con .maybeSingle() → devuelve 0 o 1 filas.

CREATE OR REPLACE FUNCTION public.get_my_group()
RETURNS SETOF public.groups
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid UUID := auth.uid();
  v_row public.groups%ROWTYPE;
BEGIN
  -- 1. Intenta como dueño del grupo (role='group')
  SELECT g.* INTO v_row
  FROM   public.groups g
  WHERE  g.owner_id = v_uid
  LIMIT  1;

  IF FOUND THEN
    RETURN NEXT v_row;
    RETURN;
  END IF;

  -- 2. Intenta como talento miembro con invitación de membresía aceptada
  SELECT g.* INTO v_row
  FROM   public.groups g
  JOIN   public.job_invitations ji ON ji.group_id = g.id
  WHERE  ji.invited_user_id  = v_uid
    AND  ji.invitation_type  = 'membership'
    AND  ji.status           = 'accepted'
  ORDER  BY ji.created_at DESC
  LIMIT  1;

  IF FOUND THEN
    RETURN NEXT v_row;
  END IF;

  -- Si ningún path encontró nada → retorna 0 filas (maybeSingle() → null)
END;
$$;

GRANT EXECUTE ON FUNCTION public.get_my_group() TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_my_group() TO service_role;


-- ── Verificación inmediata ────────────────────────────────────────────────────
-- Esperado: ambas filas con usa_raise_exception = false

SELECT
  routine_name,
  routine_definition LIKE '%RAISE EXCEPTION%' AS usa_raise_exception,
  routine_definition LIKE '%auth.uid()%'       AS tiene_auth_uid
FROM information_schema.routines
WHERE routine_schema = 'public'
  AND routine_name IN ('get_my_profile', 'get_my_group')
ORDER BY routine_name;
