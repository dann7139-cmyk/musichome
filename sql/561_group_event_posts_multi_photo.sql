-- ============================================================
-- 561_group_event_posts_multi_photo.sql
--
-- PROPÓSITO
--   Rediseño: una publicación ahora puede tener VARIAS fotos (carrusel),
--   con UNA sola descripción, UN solo like y UNOS solos comentarios
--   para toda la publicación — en vez de 1 foto = 1 publicación.
--
-- CAMBIO ESTRUCTURAL
--   - Nueva tabla group_event_posts: dueña de group_id, caption,
--     status (pending/approved/rejected), review_note. Mismas reglas
--     de seguridad y mismo límite (6 activas por grupo) que antes
--     tenía group_event_photos directamente.
--   - group_event_photos pasa a ser tabla hija: post_id + url +
--     position. Ya no tiene group_id/caption/status propios — viven
--     en el post.
--   - group_event_photo_likes / group_event_photo_comments se
--     renombran a group_event_post_likes / group_event_post_comments
--     y su columna photo_id pasa a post_id (apunta al post, no a una
--     foto individual).
--
-- MIGRACIÓN DE DATOS EXISTENTES (1 foto, 1 like, 1 comentario — ya
-- probados en vivo por el usuario, no se pierden)
--   Cada fila existente de group_event_photos se convierte en 1 post
--   (mismo id, para no romper las FK de likes/comments que ya
--   apuntaban a ese id) + 1 fila hija en la nueva group_event_photos.
--
-- ALCANCE: no toca reviews, group_videos, ni ninguna otra tabla.
-- ============================================================

BEGIN;

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema='public' AND table_name='group_event_posts') THEN
    RAISE EXCEPTION 'ABORT: group_event_posts ya existe';
  END IF;
END $$;

-- ── 1. Tabla nueva: group_event_posts (la publicación) ──────────────────
CREATE TABLE public.group_event_posts (
  id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  group_id    UUID NOT NULL REFERENCES public.groups(id) ON DELETE CASCADE,
  caption     TEXT,
  status      TEXT NOT NULL DEFAULT 'pending' CHECK (status IN ('pending','approved','rejected')),
  review_note TEXT,
  created_at  TIMESTAMPTZ DEFAULT NOW(),
  updated_at  TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX idx_gep_posts_group ON public.group_event_posts (group_id);

ALTER TABLE public.group_event_posts ENABLE ROW LEVEL SECURITY;

CREATE POLICY gep_posts_owner_insert ON public.group_event_posts FOR INSERT
  WITH CHECK (EXISTS (SELECT 1 FROM public.groups g WHERE g.id = group_event_posts.group_id AND g.owner_id = auth.uid()));

CREATE POLICY gep_posts_owner_delete ON public.group_event_posts FOR DELETE
  USING (
    EXISTS (SELECT 1 FROM public.groups g WHERE g.id = group_event_posts.group_id AND g.owner_id = auth.uid())
    OR EXISTS (SELECT 1 FROM public.profiles p WHERE p.id = auth.uid() AND p.role = 'admin')
  );

CREATE POLICY gep_posts_admin_update ON public.group_event_posts FOR UPDATE
  USING (EXISTS (SELECT 1 FROM public.profiles p WHERE p.id = auth.uid() AND p.role = 'admin'));

CREATE POLICY gep_posts_public_read ON public.group_event_posts FOR SELECT
  USING (
    status = 'approved'
    OR EXISTS (SELECT 1 FROM public.groups g WHERE g.id = group_event_posts.group_id AND g.owner_id = auth.uid())
    OR EXISTS (SELECT 1 FROM public.profiles p WHERE p.id = auth.uid() AND p.role = 'admin')
  );

GRANT SELECT, INSERT, UPDATE, DELETE ON public.group_event_posts TO authenticated;

-- Límite: máximo 6 publicaciones activas (no rechazadas) por grupo
CREATE FUNCTION public.enforce_max_event_posts()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $function$
BEGIN
  IF (SELECT COUNT(*) FROM public.group_event_posts
      WHERE group_id = NEW.group_id AND status <> 'rejected') >= 6 THEN
    RAISE EXCEPTION 'max_event_photos_reached: Ya tienes 6 publicaciones (el máximo). Elimina una para subir otra.';
  END IF;
  RETURN NEW;
END;
$function$;

CREATE TRIGGER trg_enforce_max_event_posts
BEFORE INSERT ON public.group_event_posts
FOR EACH ROW
EXECUTE FUNCTION public.enforce_max_event_posts();

CREATE TRIGGER set_gep_posts_updated_at
BEFORE UPDATE ON public.group_event_posts
FOR EACH ROW
EXECUTE FUNCTION public.set_updated_at();

-- ── 2. Migrar filas existentes de group_event_photos → 1 post cada una,
-- MISMO id (para no romper las FK de likes/comments que ya apuntan ahí) ──
INSERT INTO public.group_event_posts (id, group_id, caption, status, review_note, created_at, updated_at)
SELECT id, group_id, caption, status, review_note, created_at, updated_at
FROM public.group_event_photos;

-- ── 3. Reestructurar group_event_photos: pasa a ser tabla hija ──────────
DROP POLICY IF EXISTS gep_owner_insert ON public.group_event_photos;
DROP POLICY IF EXISTS gep_owner_delete ON public.group_event_photos;
DROP POLICY IF EXISTS gep_admin_update ON public.group_event_photos;
DROP POLICY IF EXISTS gep_public_read ON public.group_event_photos;
DROP TRIGGER IF EXISTS trg_enforce_max_event_photos ON public.group_event_photos;
DROP FUNCTION IF EXISTS public.enforce_max_event_photos();

ALTER TABLE public.group_event_photos ADD COLUMN post_id UUID REFERENCES public.group_event_posts(id) ON DELETE CASCADE;
UPDATE public.group_event_photos SET post_id = id;  -- 1:1 preservado del paso 2
ALTER TABLE public.group_event_photos ALTER COLUMN post_id SET NOT NULL;

ALTER TABLE public.group_event_photos DROP CONSTRAINT group_event_photos_group_id_fkey;
ALTER TABLE public.group_event_photos DROP COLUMN group_id;
ALTER TABLE public.group_event_photos DROP COLUMN caption;
ALTER TABLE public.group_event_photos DROP COLUMN event_date;
ALTER TABLE public.group_event_photos DROP COLUMN status;
ALTER TABLE public.group_event_photos DROP COLUMN review_note;
ALTER TABLE public.group_event_photos DROP COLUMN updated_at;

CREATE INDEX idx_gep_photos_post ON public.group_event_photos (post_id);

CREATE POLICY gep_photos_owner_insert ON public.group_event_photos FOR INSERT
  WITH CHECK (EXISTS (
    SELECT 1 FROM public.group_event_posts gp
    JOIN public.groups g ON g.id = gp.group_id
    WHERE gp.id = group_event_photos.post_id AND g.owner_id = auth.uid()
  ));

CREATE POLICY gep_photos_owner_delete ON public.group_event_photos FOR DELETE
  USING (EXISTS (
    SELECT 1 FROM public.group_event_posts gp
    JOIN public.groups g ON g.id = gp.group_id
    WHERE gp.id = group_event_photos.post_id AND g.owner_id = auth.uid()
  ) OR EXISTS (SELECT 1 FROM public.profiles p WHERE p.id = auth.uid() AND p.role = 'admin'));

CREATE POLICY gep_photos_read ON public.group_event_photos FOR SELECT
  USING (EXISTS (
    SELECT 1 FROM public.group_event_posts gp
    WHERE gp.id = group_event_photos.post_id
      AND (
        gp.status = 'approved'
        OR EXISTS (SELECT 1 FROM public.groups g WHERE g.id = gp.group_id AND g.owner_id = auth.uid())
        OR EXISTS (SELECT 1 FROM public.profiles p WHERE p.id = auth.uid() AND p.role = 'admin')
      )
  ));

-- ── 4. Renombrar likes/comments para que apunten al POST, no a la foto ──
ALTER TABLE public.group_event_photo_likes RENAME TO group_event_post_likes;
ALTER TABLE public.group_event_post_likes RENAME COLUMN photo_id TO post_id;
ALTER TABLE public.group_event_post_likes DROP CONSTRAINT group_event_photo_likes_photo_id_fkey;
ALTER TABLE public.group_event_post_likes ADD CONSTRAINT group_event_post_likes_post_id_fkey
  FOREIGN KEY (post_id) REFERENCES public.group_event_posts(id) ON DELETE CASCADE;

ALTER TABLE public.group_event_photo_comments RENAME TO group_event_post_comments;
ALTER TABLE public.group_event_post_comments RENAME COLUMN photo_id TO post_id;
ALTER TABLE public.group_event_post_comments DROP CONSTRAINT group_event_photo_comments_photo_id_fkey;
ALTER TABLE public.group_event_post_comments ADD CONSTRAINT group_event_post_comments_post_id_fkey
  FOREIGN KEY (post_id) REFERENCES public.group_event_posts(id) ON DELETE CASCADE;

COMMIT;

-- ============================================================
-- VERIFICACIÓN (ejecutar por separado después del COMMIT)
-- ============================================================
-- SELECT COUNT(*) FROM group_event_posts;                    -- 1 (migrado)
-- SELECT COUNT(*) FROM group_event_photos WHERE post_id IS NOT NULL; -- 1
-- SELECT COUNT(*) FROM group_event_post_likes;                -- 1 (conservado)
-- SELECT COUNT(*) FROM group_event_post_comments;             -- 1 (conservado)

SELECT '561_group_event_posts_multi_photo preparado' AS status;
