-- ============================================================
-- 559_group_event_photo_likes_comments.sql
--
-- PROPÓSITO
--   Likes y comentarios sobre las fotos de eventos (sql/558), para
--   que la publicación se sienta como una red social: cualquier
--   usuario autenticado puede dar/quitar like y comentar. El filtro
--   de contenido ofensivo va del lado del cliente (mismo patrón que
--   validatePublicText ya usado en toda la app) — no hay moderación
--   por IA, es una lista básica de palabras bloqueadas.
--
-- ALCANCE
--   Solo agrega 2 tablas nuevas + RLS. No modifica group_event_photos,
--   group_videos, reviews, ni ninguna otra tabla/función.
-- ============================================================

BEGIN;

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema='public' AND table_name='group_event_photo_likes') THEN
    RAISE EXCEPTION 'ABORT: group_event_photo_likes ya existe';
  END IF;
  IF EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema='public' AND table_name='group_event_photo_comments') THEN
    RAISE EXCEPTION 'ABORT: group_event_photo_comments ya existe';
  END IF;
END $$;

-- ── Likes ────────────────────────────────────────────────────────────
CREATE TABLE public.group_event_photo_likes (
  id         UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  photo_id   UUID NOT NULL REFERENCES public.group_event_photos(id) ON DELETE CASCADE,
  user_id    UUID NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  created_at TIMESTAMPTZ DEFAULT NOW(),
  UNIQUE (photo_id, user_id)
);

CREATE INDEX idx_gepl_photo ON public.group_event_photo_likes (photo_id);

ALTER TABLE public.group_event_photo_likes ENABLE ROW LEVEL SECURITY;

CREATE POLICY gepl_read       ON public.group_event_photo_likes FOR SELECT USING (true);
CREATE POLICY gepl_insert_own ON public.group_event_photo_likes FOR INSERT WITH CHECK (user_id = auth.uid());
CREATE POLICY gepl_delete_own ON public.group_event_photo_likes FOR DELETE USING (user_id = auth.uid());

GRANT SELECT, INSERT, DELETE ON public.group_event_photo_likes TO authenticated;

-- ── Comentarios ──────────────────────────────────────────────────────
CREATE TABLE public.group_event_photo_comments (
  id         UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  photo_id   UUID NOT NULL REFERENCES public.group_event_photos(id) ON DELETE CASCADE,
  user_id    UUID NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  comment    TEXT NOT NULL,
  created_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX idx_gepc_photo ON public.group_event_photo_comments (photo_id);

ALTER TABLE public.group_event_photo_comments ENABLE ROW LEVEL SECURITY;

CREATE POLICY gepc_read       ON public.group_event_photo_comments FOR SELECT USING (true);
CREATE POLICY gepc_insert_own ON public.group_event_photo_comments FOR INSERT WITH CHECK (user_id = auth.uid());
CREATE POLICY gepc_delete_own_or_admin ON public.group_event_photo_comments FOR DELETE USING (
  user_id = auth.uid()
  OR EXISTS (SELECT 1 FROM public.profiles p WHERE p.id = auth.uid() AND p.role = 'admin')
);

GRANT SELECT, INSERT, DELETE ON public.group_event_photo_comments TO authenticated;

COMMIT;

-- ============================================================
-- VERIFICACIÓN (ejecutar por separado después del COMMIT)
-- ============================================================
-- SELECT COUNT(*) FROM information_schema.tables WHERE table_name IN ('group_event_photo_likes','group_event_photo_comments'); -- 2
-- SELECT COUNT(*) FROM pg_policies WHERE tablename IN ('group_event_photo_likes','group_event_photo_comments'); -- 6

SELECT '559_group_event_photo_likes_comments preparado' AS status;
