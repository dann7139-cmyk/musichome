-- 620_notify_gift_visibility_off.sql
-- Pedido 2026-09-05: si el dueño APAGA "mostrar regalos a mis músicos"
-- (sql/618) mientras hay integrantes que lo tenían activo, esos
-- integrantes deben enterarse — así el dueño no puede quitarles la
-- transparencia "en silencio". Solo dispara en la transición true->false,
-- y solo notifica a integrantes FIJOS (invitation_type='membership',
-- event_id NULL) que existan en ese momento — si nunca hubo integrantes
-- viendo nada, no hay a quién avisar.
--
-- Se implementa como trigger (no en el código del cliente) para que
-- funcione sin importar desde dónde se apague el interruptor.

CREATE OR REPLACE FUNCTION public.notify_gift_visibility_off()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_member UUID;
BEGIN
  IF OLD.show_gifts_to_members = true AND NEW.show_gifts_to_members = false THEN
    FOR v_member IN
      SELECT invited_user_id FROM public.job_invitations
      WHERE group_id = NEW.id AND status = 'accepted' AND invitation_type = 'membership' AND event_id IS NULL
    LOOP
      INSERT INTO public.notifications (user_id, type, title, body, data)
      VALUES (
        v_member, 'system',
        '🔒 Ya no puedes ver los regalos del grupo',
        COALESCE(NEW.name, 'El grupo') || ' desactivó que sus integrantes vean los regalos y el dinero de regalos.',
        jsonb_build_object('screen', 'Wallet')
      );
    END LOOP;
  END IF;
  RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS trg_notify_gift_visibility_off ON public.groups;
CREATE TRIGGER trg_notify_gift_visibility_off
AFTER UPDATE OF show_gifts_to_members ON public.groups
FOR EACH ROW
EXECUTE FUNCTION public.notify_gift_visibility_off();
