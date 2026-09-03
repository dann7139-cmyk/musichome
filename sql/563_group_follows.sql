-- ============================================================
-- 563_group_follows.sql
--
-- PROPÓSITO: seguidores de grupo — contador de confianza en el perfil
-- + botón Seguir/Dejar de seguir + aviso a seguidores cuando el grupo
-- publica algo nuevo (aprobado).
--
-- ANTI-TRAMPA: UNIQUE(group_id, user_id) evita que un mismo usuario
-- cuente más de una vez. Trigger adicional evita que el propio dueño
-- del grupo se siga a sí mismo para inflar su contador.
-- ============================================================

BEGIN;

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema='public' AND table_name='group_follows') THEN
    RAISE EXCEPTION 'ABORT: group_follows ya existe';
  END IF;
END $$;

CREATE TABLE public.group_follows (
  id         UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  group_id   UUID NOT NULL REFERENCES public.groups(id) ON DELETE CASCADE,
  user_id    UUID NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  created_at TIMESTAMPTZ DEFAULT NOW(),
  UNIQUE (group_id, user_id)
);

CREATE INDEX idx_group_follows_group ON public.group_follows (group_id);
CREATE INDEX idx_group_follows_user  ON public.group_follows (user_id);

ALTER TABLE public.group_follows ENABLE ROW LEVEL SECURITY;

CREATE POLICY gf_read       ON public.group_follows FOR SELECT USING (true);
CREATE POLICY gf_insert_own ON public.group_follows FOR INSERT WITH CHECK (user_id = auth.uid());
CREATE POLICY gf_delete_own ON public.group_follows FOR DELETE USING (user_id = auth.uid());

GRANT SELECT, INSERT, DELETE ON public.group_follows TO authenticated;

-- Anti-trampa: el dueño del grupo no puede seguir su propio grupo
CREATE FUNCTION public.prevent_self_follow()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $function$
BEGIN
  IF EXISTS (SELECT 1 FROM public.groups g WHERE g.id = NEW.group_id AND g.owner_id = NEW.user_id) THEN
    RAISE EXCEPTION 'self_follow_not_allowed: no puedes seguir tu propio grupo';
  END IF;
  RETURN NEW;
END;
$function$;

CREATE TRIGGER trg_prevent_self_follow
BEFORE INSERT ON public.group_follows
FOR EACH ROW
EXECUTE FUNCTION public.prevent_self_follow();

COMMIT;

SELECT '563_group_follows preparado' AS status;
