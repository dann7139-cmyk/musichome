-- ============================================================
-- sql/16_admin_talents.sql
-- Admin: acceso de lectura a todos los perfiles de talento
-- + miembros de grupos (membership invitations aceptadas)
-- Ejecutar en: Supabase Dashboard → SQL Editor
-- ============================================================

-- ── 1. RLS: admin puede leer TODOS los job_board_profiles ──────────────────

-- Los talentos ya tienen políticas propias en sql/10.
-- search_talents() (SECURITY DEFINER) devuelve solo is_visible=TRUE.
-- El admin necesita ver TODOS, incluyendo ocultos.

DROP POLICY IF EXISTS "job_board_profiles_admin_select" ON public.job_board_profiles;

CREATE POLICY "job_board_profiles_admin_select"
  ON public.job_board_profiles
  FOR SELECT
  USING (
    EXISTS (
      SELECT 1 FROM public.profiles
      WHERE id = auth.uid() AND role = 'admin'
    )
  );


-- ── 2. RLS: admin puede leer TODAS las job_invitations ─────────────────────

DROP POLICY IF EXISTS "job_invitations_admin_select" ON public.job_invitations;

CREATE POLICY "job_invitations_admin_select"
  ON public.job_invitations
  FOR SELECT
  USING (
    EXISTS (
      SELECT 1 FROM public.profiles
      WHERE id = auth.uid() AND role = 'admin'
    )
  );


-- ── 3. RLS: admin puede leer TODOS los profiles (ya debería existir) ────────
-- Si no existe una política de admin en profiles, crearla:

DROP POLICY IF EXISTS "profiles_admin_select" ON public.profiles;

CREATE POLICY "profiles_admin_select"
  ON public.profiles
  FOR SELECT
  USING (
    EXISTS (
      SELECT 1 FROM public.profiles p
      WHERE p.id = auth.uid() AND p.role = 'admin'
    )
  );


-- ── 4. Vista de diagnóstico para admin: talentos con estado ─────────────────
-- (No expuesta via API, solo para consultas manuales en el dashboard)

DROP VIEW IF EXISTS admin_talent_overview;

CREATE VIEW admin_talent_overview AS
SELECT
  p.id              AS user_id,
  p.full_name,
  p.email,
  p.created_at      AS registered_at,
  jp.instrument_or_role,
  jp.experience_years,
  jp.bio,
  jp.rating,
  jp.total_jobs,
  jp.availability_status,
  jp.is_visible,
  -- Membresías aceptadas
  (
    SELECT json_agg(json_build_object(
      'group_id',   ji.group_id,
      'group_name', g.name,
      'accepted_at', ji.updated_at
    ))
    FROM public.job_invitations ji
    JOIN public.groups g ON g.id = ji.group_id
    WHERE ji.invited_user_id = p.id
      AND ji.invitation_type = 'membership'
      AND ji.status = 'accepted'
  ) AS group_memberships,
  -- Invitaciones pendientes
  (
    SELECT COUNT(*)
    FROM public.job_invitations ji
    WHERE ji.invited_user_id = p.id
      AND ji.status = 'pending'
  ) AS pending_invitations
FROM public.profiles p
JOIN public.job_board_profiles jp ON jp.user_id = p.id
WHERE p.role = 'talent'
ORDER BY p.created_at DESC;


-- ── 5. Validación: verificar que todo esté correcto ─────────────────────────

-- a) Contar talentos registrados
SELECT COUNT(*) AS total_talents
FROM public.profiles
WHERE role = 'talent';

-- b) Contar perfiles de job board
SELECT COUNT(*) AS job_board_profiles_count
FROM public.job_board_profiles;

-- c) Talentos SIN perfil de job_board (debería ser 0 si el trigger funciona)
SELECT p.id, p.email, p.full_name, p.created_at
FROM public.profiles p
LEFT JOIN public.job_board_profiles jp ON jp.user_id = p.id
WHERE p.role = 'talent'
  AND jp.user_id IS NULL;

-- d) Distribución de invitation_type
SELECT invitation_type, status, COUNT(*) AS total
FROM public.job_invitations
GROUP BY invitation_type, status
ORDER BY invitation_type, status;

-- e) Miembros de grupos (membership aceptada)
SELECT
  g.name        AS group_name,
  p.full_name   AS talent_name,
  jp.instrument_or_role,
  ji.created_at AS invited_at
FROM public.job_invitations ji
JOIN public.groups g    ON g.id  = ji.group_id
JOIN public.profiles p  ON p.id  = ji.invited_user_id
JOIN public.job_board_profiles jp ON jp.user_id = ji.invited_user_id
WHERE ji.invitation_type = 'membership'
  AND ji.status = 'accepted'
ORDER BY g.name, p.full_name;
