-- ============================================================
-- sql/571_plus_gates_photos_and_gifts.sql
--
-- Publicaciones de eventos (fotos) y regalos/donaciones pasan a ser
-- EXCLUSIVOS de grupos con Plus activo — gancho para que paguen Plus
-- (así Daricefy gana por Plus Y por comisión de regalos).
--
-- Decisión del usuario:
--   - Fotos que YA subió un grupo sin Plus quedan OCULTAS al público
--     hasta que compre Plus (no se borran, el dueño las sigue viendo).
--   - Subir foto nueva o mandar un regalo sin Plus: bloqueado con
--     mensaje que invita a comprar Plus (no oculto silenciosamente).
--
-- Solo toca group_event_posts / group_event_photos (RLS) — group_gifts
-- se bloquea en el edge function create-gift-order (el INSERT real lo
-- hace ahí con service_role, RLS no aplica en ese camino).
-- ============================================================

-- ── group_event_posts: visibilidad pública requiere Plus VIGENTE ────────────
DROP POLICY IF EXISTS gep_posts_public_read ON public.group_event_posts;
CREATE POLICY gep_posts_public_read ON public.group_event_posts
  FOR SELECT USING (
    (
      status = 'approved'
      AND EXISTS (
        SELECT 1 FROM public.groups g
        WHERE g.id = group_event_posts.group_id
          AND g.is_plus_active = TRUE
          AND (g.plus_expires_at IS NULL OR g.plus_expires_at > NOW())
      )
    )
    OR EXISTS (SELECT 1 FROM public.groups g WHERE g.id = group_event_posts.group_id AND g.owner_id = auth.uid())
    OR EXISTS (SELECT 1 FROM public.profiles p WHERE p.id = auth.uid() AND p.role = 'admin')
  );

-- ── group_event_posts: subir publicación requiere Plus VIGENTE ──────────────
DROP POLICY IF EXISTS gep_posts_owner_insert ON public.group_event_posts;
CREATE POLICY gep_posts_owner_insert ON public.group_event_posts
  FOR INSERT WITH CHECK (
    EXISTS (
      SELECT 1 FROM public.groups g
      WHERE g.id = group_event_posts.group_id
        AND g.owner_id = auth.uid()
        AND g.is_plus_active = TRUE
        AND (g.plus_expires_at IS NULL OR g.plus_expires_at > NOW())
    )
  );

-- ── group_event_photos: mismo candado (mirror de gep_posts_public_read) ─────
DROP POLICY IF EXISTS gep_photos_read ON public.group_event_photos;
CREATE POLICY gep_photos_read ON public.group_event_photos
  FOR SELECT USING (
    EXISTS (
      SELECT 1 FROM public.group_event_posts gp
      WHERE gp.id = group_event_photos.post_id
        AND (
          (
            gp.status = 'approved'
            AND EXISTS (
              SELECT 1 FROM public.groups g
              WHERE g.id = gp.group_id
                AND g.is_plus_active = TRUE
                AND (g.plus_expires_at IS NULL OR g.plus_expires_at > NOW())
            )
          )
          OR EXISTS (SELECT 1 FROM public.groups g WHERE g.id = gp.group_id AND g.owner_id = auth.uid())
          OR EXISTS (SELECT 1 FROM public.profiles p WHERE p.id = auth.uid() AND p.role = 'admin')
        )
    )
  );

SELECT '571_plus_gates_photos_and_gifts.sql ejecutado ✅' AS status;
