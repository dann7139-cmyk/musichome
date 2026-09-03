-- ============================================================
-- 562_group_event_post_comment_likes.sql
--
-- PROPÓSITO: like por comentario individual (no solo por publicación),
-- mismo patrón que group_event_post_likes.
-- ============================================================

BEGIN;

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema='public' AND table_name='group_event_post_comment_likes') THEN
    RAISE EXCEPTION 'ABORT: group_event_post_comment_likes ya existe';
  END IF;
END $$;

CREATE TABLE public.group_event_post_comment_likes (
  id         UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  comment_id UUID NOT NULL REFERENCES public.group_event_post_comments(id) ON DELETE CASCADE,
  user_id    UUID NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  created_at TIMESTAMPTZ DEFAULT NOW(),
  UNIQUE (comment_id, user_id)
);

CREATE INDEX idx_gepcl_comment ON public.group_event_post_comment_likes (comment_id);

ALTER TABLE public.group_event_post_comment_likes ENABLE ROW LEVEL SECURITY;

CREATE POLICY gepcl_read       ON public.group_event_post_comment_likes FOR SELECT USING (true);
CREATE POLICY gepcl_insert_own ON public.group_event_post_comment_likes FOR INSERT WITH CHECK (user_id = auth.uid());
CREATE POLICY gepcl_delete_own ON public.group_event_post_comment_likes FOR DELETE USING (user_id = auth.uid());

GRANT SELECT, INSERT, DELETE ON public.group_event_post_comment_likes TO authenticated;

COMMIT;

SELECT '562_group_event_post_comment_likes preparado' AS status;
