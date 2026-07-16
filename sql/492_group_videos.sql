-- ============================================================
-- sql/492_group_videos.sql
-- 🎬 VIDEOS MÚLTIPLES del perfil del grupo (carrusel deslizable).
--
--  · Base: hasta 3 videos por grupo.
--  · Con PLUS (is_plus_active): hasta 5 (la insignia desbloquea +2).
--  · Cada video pasa por revisión del admin (status pending/approved/
--    rejected — mismo modelo que promo_video/video_status).
--  · El video legacy groups.promo_video se migra como posición 1.
--  · Límite validado por TRIGGER (no se puede brincar desde la app).
-- ============================================================

BEGIN;

CREATE TABLE IF NOT EXISTS public.group_videos (
  id         UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  group_id   UUID NOT NULL REFERENCES groups(id) ON DELETE CASCADE,
  url        TEXT NOT NULL,
  status     TEXT NOT NULL DEFAULT 'pending'
             CHECK (status IN ('pending', 'approved', 'rejected')),
  position   INT  NOT NULL DEFAULT 1,
  review_note TEXT,
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_group_videos_group ON group_videos(group_id, position);

-- ── Límite 3 / 5 (Plus) por trigger ─────────────────────────────────
CREATE OR REPLACE FUNCTION public.guard_group_videos_limit()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_count INT;
  v_plus  BOOLEAN;
  v_max   INT;
BEGIN
  SELECT COALESCE(is_plus_active, false) INTO v_plus FROM groups WHERE id = NEW.group_id;
  v_max := CASE WHEN v_plus THEN 5 ELSE 3 END;

  SELECT COUNT(*) INTO v_count FROM group_videos
  WHERE group_id = NEW.group_id AND status <> 'rejected';

  IF v_count >= v_max THEN
    IF v_plus THEN
      RAISE EXCEPTION 'Ya tienes % videos (el máximo con Plus es 5). Elimina uno para subir otro.', v_count;
    ELSE
      RAISE EXCEPTION 'Ya tienes % videos. Con la insignia Plus desbloqueas 2 más (hasta 5).', v_count;
    END IF;
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_guard_group_videos_limit ON public.group_videos;
CREATE TRIGGER trg_guard_group_videos_limit
  BEFORE INSERT ON public.group_videos
  FOR EACH ROW
  EXECUTE FUNCTION public.guard_group_videos_limit();

-- ── RLS ─────────────────────────────────────────────────────────────
ALTER TABLE public.group_videos ENABLE ROW LEVEL SECURITY;

-- Público (clientes) solo ve videos APROBADOS
DROP POLICY IF EXISTS gv_public_read ON public.group_videos;
CREATE POLICY gv_public_read ON public.group_videos
  FOR SELECT USING (
    status = 'approved'
    OR EXISTS (SELECT 1 FROM groups g WHERE g.id = group_id AND g.owner_id = auth.uid())
    OR EXISTS (SELECT 1 FROM profiles p WHERE p.id = auth.uid() AND p.role = 'admin')
  );

-- El dueño sube/borra los suyos; el admin todo
DROP POLICY IF EXISTS gv_owner_insert ON public.group_videos;
CREATE POLICY gv_owner_insert ON public.group_videos
  FOR INSERT WITH CHECK (
    EXISTS (SELECT 1 FROM groups g WHERE g.id = group_id AND g.owner_id = auth.uid())
  );

DROP POLICY IF EXISTS gv_owner_delete ON public.group_videos;
CREATE POLICY gv_owner_delete ON public.group_videos
  FOR DELETE USING (
    EXISTS (SELECT 1 FROM groups g WHERE g.id = group_id AND g.owner_id = auth.uid())
    OR EXISTS (SELECT 1 FROM profiles p WHERE p.id = auth.uid() AND p.role = 'admin')
  );

DROP POLICY IF EXISTS gv_admin_update ON public.group_videos;
CREATE POLICY gv_admin_update ON public.group_videos
  FOR UPDATE USING (
    EXISTS (SELECT 1 FROM profiles p WHERE p.id = auth.uid() AND p.role = 'admin')
  );

-- ── Migrar el video legacy (promo_video aprobado → posición 1) ──────
INSERT INTO group_videos (group_id, url, status, position)
SELECT g.id, g.promo_video, COALESCE(g.video_status, 'pending'), 1
FROM groups g
WHERE g.promo_video IS NOT NULL
  AND NOT EXISTS (SELECT 1 FROM group_videos gv WHERE gv.group_id = g.id AND gv.url = g.promo_video);

-- ── Notificar al admin cuando llega un video nuevo a revisión ───────
CREATE OR REPLACE FUNCTION public.notify_group_video_pending()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_admin UUID;
  v_gname TEXT;
BEGIN
  IF NEW.status <> 'pending' THEN RETURN NEW; END IF;
  SELECT name INTO v_gname FROM groups WHERE id = NEW.group_id;
  FOR v_admin IN SELECT id FROM profiles WHERE role = 'admin' LOOP
    INSERT INTO notifications (user_id, type, title, body, data)
    VALUES (v_admin, 'admin',
      '🎬 Video nuevo por revisar',
      format('%s subió un video a su perfil. Revísalo antes de que se publique.', COALESCE(v_gname, 'Un grupo')),
      jsonb_build_object('group_id', NEW.group_id, 'video_id', NEW.id, 'screen', 'AdminMediaReview'));
  END LOOP;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_notify_group_video_pending ON public.group_videos;
CREATE TRIGGER trg_notify_group_video_pending
  AFTER INSERT ON public.group_videos
  FOR EACH ROW
  EXECUTE FUNCTION public.notify_group_video_pending();

COMMIT;

-- ── VERIFICACIÓN ──────────────────────────────────────────────────────────────
SELECT COUNT(*) AS videos_migrados FROM group_videos;
-- Esperado: nº de grupos con promo_video

SELECT tgname FROM pg_trigger
WHERE tgname IN ('trg_guard_group_videos_limit', 'trg_notify_group_video_pending');
-- Esperado: 2 filas

SELECT '492_group_videos.sql ejecutado ✅' AS status;
