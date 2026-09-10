-- sql/637_posts_free_no_plus.sql
--
-- PUBLICACIONES DE FOTOS AHORA SON GRATIS (2026-09-10)
--
-- Petición del usuario: subir publicaciones (group_event_posts) deja de
-- requerir Plus vigente. Los REGALOS siguen siendo exclusivos de Plus —
-- eso vive en las Edge Functions create-gift-order / create-gift-payment-intent
-- y NO se toca aquí.
--
-- Lo único que cambia: se quita la condición `is_plus_active` de 3 políticas
-- RLS. Todo lo demás se conserva IDÉNTICO:
--   · gep_posts_owner_insert  → sigue exigiendo ser el dueño del grupo.
--   · gep_posts_public_read   → posts 'approved' visibles para todos;
--                               pending/rejected solo dueño + admin.
--   · gep_photos_read         → fotos de posts 'approved' visibles para todos.
--   · trigger enforce_max_event_posts (tope de 6) → SIN CAMBIO.
--   · guard_group_videos_limit (videos 1 gratis / 3 con Plus) → SIN CAMBIO.
--   · Badge Plus, ranking, sello express, bidding → SIN CAMBIO.
-- ============================================================

BEGIN;

-- ── 1. INSERT de publicaciones: solo dueño (sin Plus) ────────
DROP POLICY IF EXISTS gep_posts_owner_insert ON public.group_event_posts;
CREATE POLICY gep_posts_owner_insert ON public.group_event_posts
  FOR INSERT TO public
  WITH CHECK (
    EXISTS (
      SELECT 1 FROM public.groups g
      WHERE g.id = group_event_posts.group_id
        AND g.owner_id = auth.uid()
    )
  );

-- ── 2. Lectura pública de publicaciones: 'approved' para todos ─
DROP POLICY IF EXISTS gep_posts_public_read ON public.group_event_posts;
CREATE POLICY gep_posts_public_read ON public.group_event_posts
  FOR SELECT TO public
  USING (
    status = 'approved'
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

-- ── 3. Lectura de fotos: fotos de posts 'approved' para todos ─
DROP POLICY IF EXISTS gep_photos_read ON public.group_event_photos;
CREATE POLICY gep_photos_read ON public.group_event_photos
  FOR SELECT TO public
  USING (
    EXISTS (
      SELECT 1 FROM public.group_event_posts gp
      WHERE gp.id = group_event_photos.post_id
        AND (
          gp.status = 'approved'
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

-- ── VERIFICACIÓN ────────────────────────────────────────────
SELECT policyname,
       (qual::text || coalesce(with_check::text,'')) NOT ILIKE '%is_plus_active%' AS sin_candado_plus
FROM pg_policies
WHERE schemaname='public'
  AND policyname IN ('gep_posts_owner_insert','gep_posts_public_read','gep_photos_read');
-- Esperado: 3 filas, sin_candado_plus = true en todas

SELECT '637_posts_free_no_plus.sql ejecutado ✅' AS status;
