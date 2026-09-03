-- ============================================================
-- sql/565_comment_replies.sql
--
-- Respuestas a comentarios de publicaciones (group_event_posts,
-- sql/561), estilo Instagram: un cliente puede responder directo a
-- un comentario de otro, no solo comentar la publicación.
--
-- Cambio mínimo: agrega parent_comment_id (NULL = comentario normal,
-- no NULL = respuesta a ese comentario — un solo nivel de anidación,
-- igual que Instagram no deja responder a una respuesta).
--
-- RLS sin cambios: gepc_insert_own solo exige user_id = auth.uid(),
-- no le importa post_id/parent_comment_id — las respuestas ya quedan
-- cubiertas. gepc_read ya es pública (qual = true).
-- ============================================================

ALTER TABLE public.group_event_post_comments
  ADD COLUMN IF NOT EXISTS parent_comment_id UUID
    REFERENCES public.group_event_post_comments(id) ON DELETE CASCADE;

CREATE INDEX IF NOT EXISTS idx_gepc_parent ON public.group_event_post_comments(parent_comment_id);

SELECT '565_comment_replies.sql ejecutado ✅' AS status;
