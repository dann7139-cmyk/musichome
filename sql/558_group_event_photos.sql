-- ============================================================
-- 558_group_event_photos.sql
--
-- PROPÓSITO
--   Los grupos podrán subir fotos de eventos reales que ya hicieron
--   (foto + fecha + descripción corta), para que su perfil se vea
--   profesional. Mismo patrón ya usado en group_videos: el dueño del
--   grupo sube, queda 'pending', el admin aprueba/rechaza, el cliente
--   solo ve las 'approved'. Máximo 6 fotos activas por grupo (no
--   cuenta las rechazadas), sin relación con Plus.
--
-- ALMACENAMIENTO
--   Bucket existente `group-images` (público, ya usado para fotos de
--   perfil) — ruta `{group_id}/event-photos/{archivo}`. Con el
--   group_id como primer segmento de la ruta, las políticas de
--   storage YA EXISTENTES (group_images_auth_insert/update/delete,
--   que usan is_group_owner(split_part(name,'/',1)::uuid)) cubren
--   esta ruta sin necesidad de ninguna política de storage nueva.
--   Verificado leyendo esas políticas antes de este archivo.
--
-- ALCANCE
--   Solo agrega: 1 tabla nueva + RLS + 1 trigger de límite (6 fotos).
--   No modifica group_videos, group-images, reviews, ni ninguna otra
--   tabla/función.
-- ============================================================

BEGIN;

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema='public' AND table_name='group_event_photos') THEN
    RAISE EXCEPTION 'ABORT: group_event_photos ya existe — no se debe recrear a ciegas';
  END IF;
END $$;

CREATE TABLE public.group_event_photos (
  id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  group_id    UUID NOT NULL REFERENCES public.groups(id) ON DELETE CASCADE,
  url         TEXT NOT NULL,
  caption     TEXT,
  event_date  DATE,
  status      TEXT NOT NULL DEFAULT 'pending' CHECK (status IN ('pending','approved','rejected')),
  review_note TEXT,
  position    INTEGER NOT NULL DEFAULT 0,
  created_at  TIMESTAMPTZ DEFAULT NOW(),
  updated_at  TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX idx_group_event_photos_group ON public.group_event_photos (group_id);

ALTER TABLE public.group_event_photos ENABLE ROW LEVEL SECURITY;

-- Mismo patrón exacto que group_videos (gv_owner_insert / gv_owner_delete / gv_admin_update / gv_public_read)
CREATE POLICY gep_owner_insert ON public.group_event_photos FOR INSERT
  WITH CHECK (EXISTS (SELECT 1 FROM public.groups g WHERE g.id = group_event_photos.group_id AND g.owner_id = auth.uid()));

CREATE POLICY gep_owner_delete ON public.group_event_photos FOR DELETE
  USING (
    EXISTS (SELECT 1 FROM public.groups g WHERE g.id = group_event_photos.group_id AND g.owner_id = auth.uid())
    OR EXISTS (SELECT 1 FROM public.profiles p WHERE p.id = auth.uid() AND p.role = 'admin')
  );

CREATE POLICY gep_admin_update ON public.group_event_photos FOR UPDATE
  USING (EXISTS (SELECT 1 FROM public.profiles p WHERE p.id = auth.uid() AND p.role = 'admin'));

CREATE POLICY gep_public_read ON public.group_event_photos FOR SELECT
  USING (
    status = 'approved'
    OR EXISTS (SELECT 1 FROM public.groups g WHERE g.id = group_event_photos.group_id AND g.owner_id = auth.uid())
    OR EXISTS (SELECT 1 FROM public.profiles p WHERE p.id = auth.uid() AND p.role = 'admin')
  );

GRANT SELECT, INSERT, UPDATE, DELETE ON public.group_event_photos TO authenticated;

-- ── Límite server-side: máximo 6 fotos activas (no rechazadas) por grupo ──
CREATE FUNCTION public.enforce_max_event_photos()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $function$
BEGIN
  IF (SELECT COUNT(*) FROM public.group_event_photos
      WHERE group_id = NEW.group_id AND status <> 'rejected') >= 6 THEN
    RAISE EXCEPTION 'max_event_photos_reached: Ya tienes 6 fotos de eventos (el máximo). Elimina una para subir otra.';
  END IF;
  RETURN NEW;
END;
$function$;

CREATE TRIGGER trg_enforce_max_event_photos
BEFORE INSERT ON public.group_event_photos
FOR EACH ROW
EXECUTE FUNCTION public.enforce_max_event_photos();

CREATE TRIGGER set_gep_updated_at
BEFORE UPDATE ON public.group_event_photos
FOR EACH ROW
EXECUTE FUNCTION public.set_updated_at();

COMMIT;

-- ============================================================
-- VERIFICACIÓN (ejecutar por separado después del COMMIT)
-- ============================================================
-- SELECT COUNT(*) FROM information_schema.tables WHERE table_name='group_event_photos'; -- 1
-- SELECT COUNT(*) FROM pg_policies WHERE tablename='group_event_photos'; -- 4
-- SELECT COUNT(*) FROM pg_trigger WHERE tgrelid='public.group_event_photos'::regclass AND NOT tgisinternal; -- 2

SELECT '558_group_event_photos preparado' AS status;
