-- ============================================================
-- sql/25_search_talents_filter_grouped.sql
-- Actualiza search_talents para excluir talentos que ya
-- pertenecen a un grupo (membresía aceptada, event_id IS NULL).
-- También excluye dueños de grupos (role = 'group').
--
-- Regla:
--   - Si job_invitations tiene status='accepted' Y event_id IS NULL
--     → el talento ya es integrante de un grupo → no aparece en búsqueda
--   - Si profiles.role = 'group' → es dueño de grupo → no aparece
--
-- Además: cuando un talento acepta una membresía, su
-- job_board_profiles.is_visible se pone en FALSE automáticamente
-- mediante un trigger (ver abajo).
--
-- Ejecutar en: Supabase Dashboard → SQL Editor
-- ============================================================

-- ── 1. Trigger: al aceptar membresía, ocultar del job board ──────────────────

CREATE OR REPLACE FUNCTION public.hide_talent_on_group_join()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  -- Solo actuar cuando status cambia a 'accepted' Y es membresía (event_id IS NULL)
  IF NEW.status = 'accepted' AND NEW.event_id IS NULL AND OLD.status <> 'accepted' THEN
    UPDATE public.job_board_profiles
    SET is_visible = FALSE
    WHERE user_id = NEW.invited_user_id;
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trigger_hide_talent_on_group_join ON public.job_invitations;
CREATE TRIGGER trigger_hide_talent_on_group_join
  AFTER UPDATE ON public.job_invitations
  FOR EACH ROW
  EXECUTE FUNCTION public.hide_talent_on_group_join();

-- ── 2. Trigger: al rechazar/cancelar membresía, volver a mostrar ─────────────

CREATE OR REPLACE FUNCTION public.show_talent_on_group_leave()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  -- Si se borra una invitación aceptada de membresía → volver a visible
  IF OLD.status = 'accepted' AND OLD.event_id IS NULL THEN
    UPDATE public.job_board_profiles
    SET is_visible = TRUE
    WHERE user_id = OLD.invited_user_id;
  END IF;
  RETURN OLD;
END;
$$;

DROP TRIGGER IF EXISTS trigger_show_talent_on_group_leave ON public.job_invitations;
CREATE TRIGGER trigger_show_talent_on_group_leave
  AFTER DELETE ON public.job_invitations
  FOR EACH ROW
  EXECUTE FUNCTION public.show_talent_on_group_leave();

-- ── 3. Ocultar talentos que ya tienen membresía aceptada (datos existentes) ───

UPDATE public.job_board_profiles jbp
SET is_visible = FALSE
WHERE EXISTS (
  SELECT 1 FROM public.job_invitations jinv
  WHERE jinv.invited_user_id = jbp.user_id
    AND jinv.status = 'accepted'
    AND jinv.event_id IS NULL
);

-- ── 4. Actualizar search_talents: doble filtro (is_visible + no owner) ────────
--    La función ya filtra por is_visible = TRUE.
--    Agregamos filtro extra: excluir usuarios con role = 'group'.
--    Esto protege ante el caso en que un dueño tenga un job_board_profile visible.

CREATE OR REPLACE FUNCTION public.search_talents(
  p_role         TEXT DEFAULT NULL,
  p_availability TEXT DEFAULT NULL
)
RETURNS TABLE (
  id                  UUID,
  user_id             UUID,
  full_name           TEXT,
  avatar_url          TEXT,
  instrument_or_role  TEXT,
  bio                 TEXT,
  experience_years    INTEGER,
  rating              NUMERIC,
  total_jobs          INTEGER,
  availability_status TEXT,
  created_at          TIMESTAMP WITH TIME ZONE
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT
    jbp.id,
    jbp.user_id,
    p.full_name,
    p.avatar_url,
    jbp.instrument_or_role,
    jbp.bio,
    jbp.experience_years,
    jbp.rating::NUMERIC,
    jbp.total_jobs,
    jbp.availability_status,
    jbp.created_at
  FROM job_board_profiles jbp
  JOIN profiles p ON p.id = jbp.user_id
  WHERE jbp.is_visible = TRUE
    -- Excluir dueños de grupos
    AND p.role <> 'group'
    -- Excluir talentos que ya son integrantes de un grupo
    AND NOT EXISTS (
      SELECT 1 FROM job_invitations jinv
      WHERE jinv.invited_user_id = jbp.user_id
        AND jinv.status = 'accepted'
        AND jinv.event_id IS NULL
    )
    AND (p_role         IS NULL OR jbp.instrument_or_role ILIKE '%' || p_role || '%')
    AND (p_availability IS NULL OR jbp.availability_status = p_availability)
  ORDER BY
    jbp.availability_status ASC,
    jbp.rating              DESC,
    jbp.total_jobs          DESC;
$$;

-- ── 5. Verificación ───────────────────────────────────────────────────────────
SELECT 'search_talents actualizado — talentos con grupo excluidos ✅' AS status;
