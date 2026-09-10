-- sql/637_posts_free_no_plus_ROLLBACK.sql
-- Restaura el candado de Plus en las 3 políticas RLS de publicaciones.
-- (Estado previo exacto a sql/637 — capturado de pg_policies el 2026-09-10.)
-- ============================================================

BEGIN;

DROP POLICY IF EXISTS gep_posts_owner_insert ON public.group_event_posts;
CREATE POLICY gep_posts_owner_insert ON public.group_event_posts
  FOR INSERT TO public
  WITH CHECK (
    EXISTS (
      SELECT 1 FROM public.groups g
      WHERE g.id = group_event_posts.group_id
        AND g.owner_id = auth.uid()
        AND g.is_plus_active = true
        AND (g.plus_expires_at IS NULL OR g.plus_expires_at > now())
    )
  );

DROP POLICY IF EXISTS gep_posts_public_read ON public.group_event_posts;
CREATE POLICY gep_posts_public_read ON public.group_event_posts
  FOR SELECT TO public
  USING (
    (
      status = 'approved'
      AND EXISTS (
        SELECT 1 FROM public.groups g
        WHERE g.id = group_event_posts.group_id
          AND g.is_plus_active = true
          AND (g.plus_expires_at IS NULL OR g.plus_expires_at > now())
      )
    )
    OR EXISTS (
      SELECT 1 FROM public.groups g
      WHERE g.id = group_event_posts.group_id
        AND g.owner_id = auth.uid()
    )
    OR EXISTS (
      SELECT 1 FROM public.profiles p
      WHERE p.id = auth.uid() AND p.role = 'admin'
    )
  );

DROP POLICY IF EXISTS gep_photos_read ON public.group_event_photos;
CREATE POLICY gep_photos_read ON public.group_event_photos
  FOR SELECT TO public
  USING (
    EXISTS (
      SELECT 1 FROM public.group_event_posts gp
      WHERE gp.id = group_event_photos.post_id
        AND (
          (
            gp.status = 'approved'
            AND EXISTS (
              SELECT 1 FROM public.groups g
              WHERE g.id = gp.group_id
                AND g.is_plus_active = true
                AND (g.plus_expires_at IS NULL OR g.plus_expires_at > now())
            )
          )
          OR EXISTS (
            SELECT 1 FROM public.groups g
            WHERE g.id = gp.group_id AND g.owner_id = auth.uid()
          )
          OR EXISTS (
            SELECT 1 FROM public.profiles p
            WHERE p.id = auth.uid() AND p.role = 'admin'
          )
        )
    )
  );

COMMIT;

SELECT '637_posts_free_no_plus_ROLLBACK.sql ejecutado ✅' AS status;
