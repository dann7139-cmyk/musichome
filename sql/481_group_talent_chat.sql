-- ============================================================
-- sql/481_group_talent_chat.sql
-- 💬 CHATS INTERNOS DEL GRUPO (separados del chat de evento):
--
--   1. Chat 1:1 dueño ↔ talento (invitado de tocada o integrante).
--   2. Chat GRUPAL del grupo (dueño + integrantes fijos).
--
-- A diferencia del chat cliente↔grupo (reservation_messages):
--   • NO es efímero (no se borra al terminar eventos).
--   • SÍ permite fotos, videos y compartir números — es coordinación
--     interna del grupo, no hay riesgo de fuga de comisión.
--   • Notificación de mensaje INSERTADA POR TRIGGER (garantizada,
--     no depende de la app del emisor). El push sale con el cron
--     existente de send-push-notification (cada minuto).
--
-- Storage: bucket privado chat-media, path {group_id}/{uid}_{ts}.ext
-- ============================================================

BEGIN;

-- ────────────────────────────────────────────────────────────
-- 1) Tabla
-- ────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.direct_messages (
  id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  group_id        UUID NOT NULL REFERENCES groups(id)   ON DELETE CASCADE,
  sender_id       UUID NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
  -- NULL = chat grupal del grupo; con valor = mensaje 1:1 a esa persona
  recipient_id    UUID REFERENCES profiles(id) ON DELETE CASCADE,
  content         TEXT CHECK (content IS NULL OR char_length(content) BETWEEN 1 AND 1000),
  attachment_path TEXT,
  attachment_type TEXT CHECK (attachment_type IN ('image', 'video')),
  created_at      TIMESTAMPTZ DEFAULT NOW(),
  CONSTRAINT dm_content_or_attachment CHECK (content IS NOT NULL OR attachment_path IS NOT NULL)
);

CREATE INDEX IF NOT EXISTS idx_dm_group_created ON direct_messages (group_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_dm_recipient     ON direct_messages (recipient_id, created_at DESC);

-- ────────────────────────────────────────────────────────────
-- 2) Helpers de membresía
-- ────────────────────────────────────────────────────────────
-- Dueño o CUALQUIER talento aceptado (integrante fijo o invitado de tocada)
CREATE OR REPLACE FUNCTION public.is_group_chat_member(p_group_id UUID, p_user UUID)
RETURNS BOOLEAN LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT EXISTS (SELECT 1 FROM groups WHERE id = p_group_id AND owner_id = p_user)
      OR EXISTS (SELECT 1 FROM job_invitations
                 WHERE group_id = p_group_id AND invited_user_id = p_user AND status = 'accepted');
$$;

-- Dueño o integrante FIJO (membership) — para el chat grupal
CREATE OR REPLACE FUNCTION public.is_group_core_member(p_group_id UUID, p_user UUID)
RETURNS BOOLEAN LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT EXISTS (SELECT 1 FROM groups WHERE id = p_group_id AND owner_id = p_user)
      OR EXISTS (SELECT 1 FROM job_invitations
                 WHERE group_id = p_group_id AND invited_user_id = p_user
                   AND status = 'accepted' AND invitation_type = 'membership');
$$;

GRANT EXECUTE ON FUNCTION public.is_group_chat_member(UUID, UUID)  TO authenticated;
GRANT EXECUTE ON FUNCTION public.is_group_core_member(UUID, UUID) TO authenticated;

-- ────────────────────────────────────────────────────────────
-- 3) RLS
-- ────────────────────────────────────────────────────────────
ALTER TABLE public.direct_messages ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS dm_select ON public.direct_messages;
CREATE POLICY dm_select ON public.direct_messages FOR SELECT USING (
  -- Grupal: dueño + integrantes fijos
  (recipient_id IS NULL AND is_group_core_member(group_id, auth.uid()))
  -- 1:1: solo los dos participantes
  OR (recipient_id IS NOT NULL AND auth.uid() IN (sender_id, recipient_id))
);

DROP POLICY IF EXISTS dm_insert ON public.direct_messages;
CREATE POLICY dm_insert ON public.direct_messages FOR INSERT WITH CHECK (
  sender_id = auth.uid()
  AND (
    -- Grupal
    (recipient_id IS NULL AND is_group_core_member(group_id, auth.uid()))
    -- 1:1: dueño → talento aceptado, o talento aceptado → dueño
    OR (recipient_id IS NOT NULL
        AND is_group_chat_member(group_id, auth.uid())
        AND is_group_chat_member(group_id, recipient_id)
        AND (
          EXISTS (SELECT 1 FROM groups WHERE id = group_id AND owner_id = auth.uid())
          OR EXISTS (SELECT 1 FROM groups WHERE id = group_id AND owner_id = recipient_id)
        ))
  )
);

DROP POLICY IF EXISTS dm_admin ON public.direct_messages;
CREATE POLICY dm_admin ON public.direct_messages FOR ALL USING (
  EXISTS (SELECT 1 FROM profiles WHERE id = auth.uid() AND role = 'admin')
);

-- Realtime
ALTER TABLE public.direct_messages REPLICA IDENTITY FULL;
DO $$ BEGIN
  ALTER PUBLICATION supabase_realtime ADD TABLE public.direct_messages;
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

-- ────────────────────────────────────────────────────────────
-- 4) Notificación por TRIGGER (garantizada en servidor)
-- ────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.notify_direct_message()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_sender TEXT;
  v_gname  TEXT;
  v_owner  UUID;
  v_body   TEXT;
  v_uid    UUID;
BEGIN
  SELECT full_name INTO v_sender FROM profiles WHERE id = NEW.sender_id;
  SELECT name, owner_id INTO v_gname, v_owner FROM groups WHERE id = NEW.group_id;

  v_body := COALESCE(
    NULLIF(LEFT(COALESCE(NEW.content, ''), 120), ''),
    CASE NEW.attachment_type WHEN 'video' THEN '🎬 Video' ELSE '📷 Foto' END
  );

  IF NEW.recipient_id IS NOT NULL THEN
    -- 1:1 → solo el destinatario
    INSERT INTO notifications (user_id, type, title, body, data)
    VALUES (NEW.recipient_id, 'chat',
      format('💬 %s · %s', COALESCE(v_sender, 'Mensaje'), COALESCE(v_gname, 'tu grupo')),
      v_body,
      jsonb_build_object('dm', true, 'group_id', NEW.group_id, 'chat_mode', 'dm',
                         'peer_id', NEW.sender_id, 'screen', 'GroupChat'));
  ELSE
    -- Grupal → dueño + integrantes fijos, excepto el emisor
    FOR v_uid IN
      SELECT v_owner WHERE v_owner IS NOT NULL
      UNION
      SELECT invited_user_id FROM job_invitations
      WHERE group_id = NEW.group_id AND status = 'accepted'
        AND invitation_type = 'membership' AND invited_user_id IS NOT NULL
    LOOP
      IF v_uid <> NEW.sender_id THEN
        INSERT INTO notifications (user_id, type, title, body, data)
        VALUES (v_uid, 'chat',
          format('💬 %s · Chat de %s', COALESCE(v_sender, 'Mensaje'), COALESCE(v_gname, 'tu grupo')),
          v_body,
          jsonb_build_object('dm', true, 'group_id', NEW.group_id, 'chat_mode', 'general',
                             'screen', 'GroupChat'));
      END IF;
    END LOOP;
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_notify_direct_message ON direct_messages;
CREATE TRIGGER trg_notify_direct_message
  AFTER INSERT ON direct_messages
  FOR EACH ROW
  EXECUTE FUNCTION public.notify_direct_message();

COMMIT;

-- ────────────────────────────────────────────────────────────
-- 5) Storage: bucket privado para fotos/videos del chat
-- ────────────────────────────────────────────────────────────
INSERT INTO storage.buckets (id, name, public)
VALUES ('chat-media', 'chat-media', false)
ON CONFLICT (id) DO NOTHING;

DROP POLICY IF EXISTS chat_media_insert ON storage.objects;
CREATE POLICY chat_media_insert ON storage.objects FOR INSERT TO authenticated
WITH CHECK (
  bucket_id = 'chat-media'
  AND public.is_group_chat_member(((storage.foldername(name))[1])::uuid, auth.uid())
);

DROP POLICY IF EXISTS chat_media_select ON storage.objects;
CREATE POLICY chat_media_select ON storage.objects FOR SELECT TO authenticated
USING (
  bucket_id = 'chat-media'
  AND public.is_group_chat_member(((storage.foldername(name))[1])::uuid, auth.uid())
);

-- ── VERIFICACIÓN ──────────────────────────────────────────────────────────────
SELECT COUNT(*) AS policies FROM pg_policies WHERE tablename = 'direct_messages';
-- Esperado: 3

SELECT tgname FROM pg_trigger WHERE tgrelid = 'public.direct_messages'::regclass
  AND tgname = 'trg_notify_direct_message';
-- Esperado: 1 fila

SELECT id FROM storage.buckets WHERE id = 'chat-media';
-- Esperado: chat-media

SELECT '481_group_talent_chat.sql ejecutado ✅' AS status;
