-- ============================================================
-- sql/433_notify_quotes_on_block.sql
-- LOTE 2 · Pieza C — avisar al cliente cuando el grupo bloquea la
-- fecha de una cotización EN CURSO (pending/quoted)
--
-- Evita que el cliente siga negociando sobre una fecha muerta.
-- Trigger AFTER INSERT en group_unavailability → por cada quote
-- pending/quoted de ese grupo con event_date = fecha bloqueada:
--   notif al cliente, type 'quote_received' (REUSADO: ya está en el
--   constraint y su case del handler navega a ClientQuoteDetail con
--   quote_id — exactamente donde el cliente puede proponer otra
--   fecha; el type es de ruteo, el contenido lo pone esta notif).
-- Dedupe: NOT EXISTS por quote_id + reason='date_blocked_by_group'.
-- Robustez: EXCEPTION por fila — el bloqueo del día NUNCA falla por
-- una notificación.
--
-- ⚠️ PRE-CHECK (si da false, DETENTE):
-- ============================================================

SELECT pg_get_constraintdef(c.oid) LIKE '%quote_received%' AS quote_received_ok
FROM   pg_constraint c
WHERE  c.conname  = 'notifications_type_check'
  AND  c.conrelid = 'public.notifications'::regclass;
-- Esperado: true


BEGIN;

CREATE OR REPLACE FUNCTION public.notify_quotes_on_date_block()
RETURNS TRIGGER
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_q          RECORD;
  v_group_name TEXT;
BEGIN
  SELECT name INTO v_group_name FROM groups WHERE id = NEW.group_id;

  FOR v_q IN
    SELECT q.id, q.client_id, q.event_type
    FROM   quotes q
    WHERE  q.group_id   = NEW.group_id
      AND  q.event_date = NEW.date
      AND  q.status IN ('pending', 'quoted')
      AND  q.client_id IS NOT NULL
      AND  NOT EXISTS (
        SELECT 1 FROM notifications n
        WHERE n.data->>'quote_id' = q.id::text
          AND n.data->>'reason'   = 'date_blocked_by_group'
      )
  LOOP
    BEGIN
      INSERT INTO notifications (user_id, type, title, body, data)
      VALUES (
        v_q.client_id,
        'quote_received',
        '📅 Fecha ya no disponible',
        COALESCE(v_group_name, 'El grupo') ||
          ' bloqueó la fecha de tu cotización en curso. ' ||
          'Entra y proponle otra fecha, o busca otro grupo.',
        jsonb_build_object(
          'quote_id', v_q.id,
          'reason',   'date_blocked_by_group',
          'screen',   'ClientQuoteDetail'
        )
      );
    EXCEPTION WHEN OTHERS THEN
      RAISE WARNING '[notify_quotes_on_date_block] notif falló para quote %: %',
        v_q.id, SQLERRM;
    END;
  END LOOP;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_notify_quotes_on_block ON public.group_unavailability;

CREATE TRIGGER trg_notify_quotes_on_block
  AFTER INSERT ON public.group_unavailability
  FOR EACH ROW
  EXECUTE FUNCTION public.notify_quotes_on_date_block();

COMMIT;

-- ── Verificaciones ────────────────────────────────────────────────────────────
-- V1: trigger instalado
SELECT tgname, tgenabled FROM pg_trigger
WHERE tgname = 'trg_notify_quotes_on_block';
-- Esperado: 1 fila, tgenabled = 'O'

-- V2: dedupe y type en la definición
SELECT
  routine_definition LIKE '%date_blocked_by_group%' AS dedupe_ok,
  routine_definition LIKE '%quote_received%'        AS type_reusado
FROM information_schema.routines
WHERE routine_schema = 'public' AND routine_name = 'notify_quotes_on_date_block';
-- Esperado: true | true

SELECT '433_notify_quotes_on_block.sql ejecutado ✅' AS status;
