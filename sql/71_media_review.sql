-- ════════════════════════════════════════════════════════════════════
-- 71_media_review.sql
-- Sistema de revisión manual de fotos y videos de grupos.
--
-- El admin aprueba/rechaza cada media desde el panel "Revisión de Medios".
-- Hasta que se aprueba:
--   · La foto se muestra como placeholder para clientes
--   · El video no se muestra (solo mensaje "en revisión")
--
-- Ejecutar DESPUÉS de 70_expire_stale_requests.sql
-- ════════════════════════════════════════════════════════════════════

-- ── 1. Nuevas columnas en groups ──────────────────────────────────────────────
ALTER TABLE public.groups
  ADD COLUMN IF NOT EXISTS photo_status TEXT NOT NULL DEFAULT 'none'
    CHECK (photo_status IN ('none', 'pending', 'approved', 'rejected')),
  ADD COLUMN IF NOT EXISTS video_status TEXT NOT NULL DEFAULT 'none'
    CHECK (video_status IN ('none', 'pending', 'approved', 'rejected')),
  ADD COLUMN IF NOT EXISTS photo_reject_reason TEXT,
  ADD COLUMN IF NOT EXISTS video_reject_reason TEXT;

-- Grupos que ya tenían foto/video antes de este script → marcarlos como aprobados
UPDATE public.groups SET photo_status = 'approved' WHERE profile_image IS NOT NULL AND photo_status = 'none';
UPDATE public.groups SET video_status = 'approved' WHERE promo_video   IS NOT NULL AND video_status = 'none';

-- Índice para que el admin panel sea rápido
CREATE INDEX IF NOT EXISTS idx_groups_photo_status ON public.groups(photo_status) WHERE photo_status = 'pending';
CREATE INDEX IF NOT EXISTS idx_groups_video_status ON public.groups(video_status) WHERE video_status = 'pending';

-- ── 2. RPC: admin aprueba/rechaza media ──────────────────────────────────────
CREATE OR REPLACE FUNCTION public.admin_review_media(
  p_group_id   UUID,
  p_media_type TEXT,   -- 'photo' | 'video'
  p_action     TEXT,   -- 'approve' | 'reject'
  p_reason     TEXT    DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_caller_role TEXT;
  v_group       RECORD;
  v_new_status  TEXT;
  v_notif_title TEXT;
  v_notif_body  TEXT;
BEGIN
  -- Solo admins pueden llamar esto
  SELECT role INTO v_caller_role FROM public.profiles WHERE id = auth.uid();
  IF v_caller_role <> 'admin' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_admin');
  END IF;

  -- Cargar el grupo
  SELECT id, owner_id INTO v_group FROM public.groups WHERE id = p_group_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'group_not_found');
  END IF;

  v_new_status := CASE p_action WHEN 'approve' THEN 'approved' ELSE 'rejected' END;

  -- Actualizar columna correspondiente
  IF p_media_type = 'photo' THEN
    UPDATE public.groups
    SET photo_status        = v_new_status,
        photo_reject_reason = CASE p_action WHEN 'reject' THEN p_reason ELSE NULL END
    WHERE id = p_group_id;

    v_notif_title := CASE p_action
      WHEN 'approve' THEN '✅ Foto de perfil aprobada'
      ELSE                 '❌ Foto de perfil rechazada'
    END;
    v_notif_body  := CASE p_action
      WHEN 'approve' THEN 'Tu foto de perfil fue aprobada y ya es visible para los clientes.'
      ELSE                 'Tu foto fue rechazada: ' || COALESCE(p_reason, 'no cumple los requisitos') || '. Sube una nueva foto limpia.'
    END;
  ELSIF p_media_type = 'video' THEN
    UPDATE public.groups
    SET video_status        = v_new_status,
        video_reject_reason = CASE p_action WHEN 'reject' THEN p_reason ELSE NULL END
    WHERE id = p_group_id;

    v_notif_title := CASE p_action
      WHEN 'approve' THEN '✅ Video aprobado'
      ELSE                 '❌ Video rechazado'
    END;
    v_notif_body  := CASE p_action
      WHEN 'approve' THEN 'Tu video promocional fue aprobado y ya es visible para los clientes.'
      ELSE                 'Tu video fue rechazado: ' || COALESCE(p_reason, 'no cumple los requisitos') || '. Sube un nuevo video limpio.'
    END;
  ELSE
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_media_type');
  END IF;

  -- Notificar al dueño del grupo
  IF v_group.owner_id IS NOT NULL THEN
    INSERT INTO public.notifications (user_id, type, title, body, data)
    VALUES (
      v_group.owner_id,
      'system',
      v_notif_title,
      v_notif_body,
      jsonb_build_object('group_id', p_group_id, 'screen', 'Dashboard')
    );
  END IF;

  RETURN jsonb_build_object('ok', true, 'action', p_action, 'media_type', p_media_type);

EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$$;

GRANT EXECUTE ON FUNCTION public.admin_review_media(UUID, TEXT, TEXT, TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_review_media(UUID, TEXT, TEXT, TEXT) TO service_role;

-- ── 3. RLS: admin puede leer/actualizar todos los grupos para revisar media ───
-- (Las políticas de admin en groups ya deben existir; esto es por si acaso)
DROP POLICY IF EXISTS "groups_admin_all" ON public.groups;
CREATE POLICY "groups_admin_all"
  ON public.groups FOR ALL
  USING (EXISTS (SELECT 1 FROM public.profiles WHERE id = auth.uid() AND role = 'admin'))
  WITH CHECK (EXISTS (SELECT 1 FROM public.profiles WHERE id = auth.uid() AND role = 'admin'));

SELECT '71_media_review: columnas photo_status/video_status + RPC admin_review_media ✅' AS status;
