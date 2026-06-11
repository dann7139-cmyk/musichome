-- ============================================================
-- sql/21_group_owner_artist.sql
-- Dueño del grupo también es artista
--
-- 1. Permite a grupos leer job_board_profiles (para mostrar lineup)
-- 2. Permite a grupos leer e insertar su propio job_board_profiles
-- 3. Auto-crea job_board_profile cuando se crea un grupo (trigger)
--
-- Ejecutar en: Supabase Dashboard → SQL Editor
-- ============================================================

-- ── 1. Políticas en job_board_profiles ──────────────────────────────────────

-- Cada usuario puede leer/escribir su propio perfil artístico
DROP POLICY IF EXISTS "jbp_own_all"        ON public.job_board_profiles;
DROP POLICY IF EXISTS "jbp_public_select"  ON public.job_board_profiles;

CREATE POLICY "jbp_own_all"
  ON public.job_board_profiles FOR ALL
  USING  (user_id = auth.uid())
  WITH CHECK (user_id = auth.uid());

-- Cualquier autenticado puede ver perfiles visibles (para el buscador)
CREATE POLICY "jbp_public_select"
  ON public.job_board_profiles FOR SELECT
  USING (is_visible = true);

-- ── 2. Trigger: al crear grupo → crear job_board_profile del dueño ──────────

CREATE OR REPLACE FUNCTION public.handle_new_group()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  -- Insertar perfil artístico si no existe
  INSERT INTO public.job_board_profiles (
    user_id, instrument_or_role, experience_years,
    rating, total_jobs, availability_status, is_visible
  )
  VALUES (
    NEW.owner_id, 'Músico', 0,
    5.0, 0, 'available', false
  )
  ON CONFLICT (user_id) DO NOTHING;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trigger_new_group_artist ON public.groups;
CREATE TRIGGER trigger_new_group_artist
  AFTER INSERT ON public.groups
  FOR EACH ROW
  EXECUTE FUNCTION public.handle_new_group();

-- ── 3. Backfill: crear perfiles para grupos existentes sin job_board_profile ─

INSERT INTO public.job_board_profiles (
  user_id, instrument_or_role, experience_years,
  rating, total_jobs, availability_status, is_visible
)
SELECT
  g.owner_id, 'Músico', 0,
  5.0, 0, 'available', false
FROM public.groups g
WHERE NOT EXISTS (
  SELECT 1 FROM public.job_board_profiles jbp
  WHERE jbp.user_id = g.owner_id
)
ON CONFLICT (user_id) DO NOTHING;

-- ── 4. Verificación ──────────────────────────────────────────────────────────

SELECT
  g.name AS grupo,
  p.full_name AS dueño,
  jbp.instrument_or_role AS rol_artístico,
  jbp.is_visible
FROM public.groups g
JOIN public.profiles p ON p.id = g.owner_id
LEFT JOIN public.job_board_profiles jbp ON jbp.user_id = g.owner_id
ORDER BY g.created_at DESC
LIMIT 10;

SELECT 'Dueños de grupos registrados como artistas ✅' AS status;
