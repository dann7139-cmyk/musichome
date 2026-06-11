-- ════════════════════════════════════════════════════════════════════
-- 72_fix_group_media_rls.sql
-- Fix: RLS bloqueaba al dueño del grupo al actualizar promo_video.
--
-- Solución: RPCs SECURITY DEFINER para actualizar foto y video,
-- y reparar la política groups_owner_all con WITH CHECK explícito.
-- ════════════════════════════════════════════════════════════════════

-- ── 1. Reparar política groups_owner_all con WITH CHECK explícito ─────────────
DROP POLICY IF EXISTS "groups_owner_all" ON public.groups;
CREATE POLICY "groups_owner_all"
  ON public.groups FOR ALL
  USING     (owner_id = auth.uid())
  WITH CHECK (owner_id = auth.uid());

-- ── 2. RPC: dueño del grupo actualiza su foto de perfil ───────────────────────
CREATE OR REPLACE FUNCTION public.update_group_photo(
  p_group_id    UUID,
  p_photo_url   TEXT
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM public.groups WHERE id = p_group_id AND owner_id = auth.uid()
  ) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_owner');
  END IF;

  -- Actualizar foto (obligatorio)
  UPDATE public.groups
  SET profile_image = p_photo_url
  WHERE id = p_group_id;

  -- Marcar como pendiente si la columna ya existe (SQL 71)
  BEGIN
    EXECUTE 'UPDATE public.groups SET photo_status = ''pending'' WHERE id = $1'
      USING p_group_id;
  EXCEPTION WHEN OTHERS THEN
    NULL; -- columna no existe aún, se ignora
  END;

  RETURN jsonb_build_object('ok', true);
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$$;

GRANT EXECUTE ON FUNCTION public.update_group_photo(UUID, TEXT) TO authenticated;

-- ── 3. RPC: dueño del grupo actualiza su video promocional ───────────────────
CREATE OR REPLACE FUNCTION public.update_group_video(
  p_group_id  UUID,
  p_video_url TEXT
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM public.groups WHERE id = p_group_id AND owner_id = auth.uid()
  ) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_owner');
  END IF;

  -- Actualizar video (obligatorio)
  UPDATE public.groups
  SET promo_video = p_video_url
  WHERE id = p_group_id;

  -- Marcar como pendiente si la columna ya existe (SQL 71)
  BEGIN
    EXECUTE 'UPDATE public.groups SET video_status = ''pending'' WHERE id = $1'
      USING p_group_id;
  EXCEPTION WHEN OTHERS THEN
    NULL; -- columna no existe aún, se ignora
  END;

  RETURN jsonb_build_object('ok', true);
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$$;

GRANT EXECUTE ON FUNCTION public.update_group_video(UUID, TEXT) TO authenticated;

SELECT '72_fix_group_media_rls: políticas + RPCs update_group_photo/video ✅' AS status;
