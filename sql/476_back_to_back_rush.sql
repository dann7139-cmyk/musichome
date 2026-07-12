-- ============================================================
-- sql/476_back_to_back_rush.sql
-- 🏃 DOS TOCADAS EL MISMO DÍA: al terminar la primera, si el grupo tiene
-- otra tocada en las próximas 6 horas → aviso "¡rápido, te esperan!".
-- (Complemento del motor de horarios: 3h mínimo + 2h de colchón.)
--
-- Trigger AFTER UPDATE en reservations (status → completed). Solo inserta
-- una notificación — no toca dinero, candados ni liberaciones.
-- ============================================================

BEGIN;

CREATE OR REPLACE FUNCTION public.notify_next_gig_rush()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_next  RECORD;
  v_owner UUID;
BEGIN
  -- Solo cuando el evento ACABA de completarse
  IF NEW.status <> 'completed' OR COALESCE(OLD.status, '') = 'completed' THEN
    RETURN NEW;
  END IF;

  SELECT owner_id INTO v_owner FROM groups WHERE id = NEW.group_id;
  IF v_owner IS NULL THEN RETURN NEW; END IF;

  -- ¿Siguiente tocada del grupo en las próximas 6 horas?
  SELECT r.id, r.event_time, r.event_date, r.address
  INTO v_next
  FROM reservations r
  WHERE r.group_id = NEW.group_id
    AND r.id <> NEW.id
    AND r.status IN ('accepted', 'confirmed')
    AND r.payment_status IN ('paid', 'fully_paid', 'deposit_paid')
    AND r.group_arrived_at IS NULL
    AND ((r.event_date::timestamp + COALESCE(r.event_time, '20:00'::time))
          AT TIME ZONE 'America/Mexico_City')
        BETWEEN NOW() AND NOW() + INTERVAL '6 hours'
  ORDER BY r.event_date, r.event_time
  LIMIT 1;

  IF FOUND THEN
    INSERT INTO notifications (user_id, type, title, body, data)
    VALUES (v_owner, 'reservation',
      '🏃 ¡Rápido — tu siguiente tocada te espera!',
      format('Hoy tienes otro evento a las %s. Desconecta, presiona "Voy en camino" y sal con tiempo — el traslado cuenta.',
             to_char(((v_next.event_date::timestamp + COALESCE(v_next.event_time, '20:00'::time))
                       AT TIME ZONE 'America/Mexico_City') AT TIME ZONE 'America/Mexico_City', 'HH24:MI')),
      jsonb_build_object('reservation_id', v_next.id, 'screen', 'EventTimer'));
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_next_gig_rush ON reservations;
CREATE TRIGGER trg_next_gig_rush
  AFTER UPDATE OF status ON reservations
  FOR EACH ROW
  EXECUTE FUNCTION public.notify_next_gig_rush();

COMMIT;

-- ── VERIFICACIÓN ──────────────────────────────────────────────────────────────
SELECT tgname, tgenabled FROM pg_trigger
WHERE tgrelid = 'public.reservations'::regclass AND tgname = 'trg_next_gig_rush';
-- Esperado: trg_next_gig_rush | O

SELECT '476_back_to_back_rush.sql ejecutado ✅' AS status;
