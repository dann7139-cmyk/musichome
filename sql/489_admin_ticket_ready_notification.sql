-- ============================================================
-- sql/489_admin_ticket_ready_notification.sql
-- 🎫 AVISO AL ADMIN: "tienes un ticket para descargar" al pagarse un
-- evento PRÓXIMO (programada) — dice si es NORMAL 🎫 o de REGALO 🎁
-- y de qué país 🇲🇽/🇺🇸. El tap abre el Expediente con la cola de
-- tickets por descargar dividida por país.
--
-- Redefine notify_reservation_paid (sql/478) conservando TODO
-- (confirmación al cliente + aviso a integrantes) y agregando el
-- bloque del admin. Solo eventos de mañana en adelante — los express
-- de hoy no se alcanzan a imprimir.
-- ============================================================

BEGIN;

CREATE OR REPLACE FUNCTION public.notify_reservation_paid()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_owner UUID;
  v_gname TEXT;
  v_fecha TEXT;
  v_uid   UUID;
  v_admin UUID;
BEGIN
  IF NEW.payment_status <> 'paid' OR COALESCE(OLD.payment_status, '') = 'paid' THEN
    RETURN NEW;
  END IF;

  SELECT owner_id, name INTO v_owner, v_gname FROM groups WHERE id = NEW.group_id;
  v_fecha := to_char(NEW.event_date, 'DD/MM') || ' a las ' ||
             TRIM(to_char(NEW.event_date::timestamp + COALESCE(NEW.event_time, '20:00'::time), 'HH12:MI am'));

  -- Cliente: confirmación formal de su pago
  IF NEW.client_id IS NOT NULL THEN
    INSERT INTO notifications (user_id, type, title, body, data)
    VALUES (NEW.client_id, 'reservation',
      '✅ Pago recibido — ¡tu evento está confirmado!',
      format('Tu pago del evento con %s (%s) fue procesado. Folio %s. Te avisaremos cuando el grupo vaya en camino.',
             COALESCE(v_gname, 'el grupo'), v_fecha, COALESCE(NEW.folio, '—')),
      jsonb_build_object('reservation_id', NEW.id, 'screen', 'Reservations'));
  END IF;

  -- Integrantes: la tocada quedó asegurada (sin montos — eso es del dueño)
  FOR v_uid IN SELECT * FROM _group_member_ids(NEW.group_id) LOOP
    IF v_uid <> COALESCE(v_owner, '00000000-0000-0000-0000-000000000000'::uuid) THEN
      INSERT INTO notifications (user_id, type, title, body, data)
      VALUES (v_uid, 'reservation',
        '💰 Tocada asegurada',
        format('El evento del %s ya está pagado. ¡Prepárense!', v_fecha),
        jsonb_build_object('reservation_id', NEW.id, 'screen', 'GroupReservations'));
    END IF;
  END LOOP;

  -- [489] 🎫 Admin: ticket listo para descargar (solo eventos de mañana
  -- en adelante — da tiempo de imprimir/enviar; express de hoy no)
  IF NEW.event_date IS NOT NULL
     AND NEW.event_date > (NOW() AT TIME ZONE 'America/Mexico_City')::date THEN
    FOR v_admin IN SELECT id FROM profiles WHERE role = 'admin' LOOP
      INSERT INTO notifications (user_id, type, title, body, data)
      VALUES (v_admin, 'admin',
        CASE WHEN COALESCE(NEW.is_gift, false)
          THEN '🎁 Ticket de REGALO para descargar'
          ELSE '🎫 Ticket para descargar' END,
        format('%s Evento %s del %s con %s%s. Descárgalo desde el Expediente → Tickets por descargar.',
               CASE WHEN COALESCE(NEW.currency_code, 'MXN') = 'USD' THEN '🇺🇸' ELSE '🇲🇽' END,
               COALESCE(NEW.folio, '—'), v_fecha, COALESCE(v_gname, 'el grupo'),
               CASE WHEN COALESCE(NEW.is_gift, false)
                 THEN ' — regalo para ' || COALESCE(NEW.gift_recipient_name, 'destinatario')
                 ELSE '' END),
        jsonb_build_object('reservation_id', NEW.id, 'screen', 'AdminTicketSearch'));
    END LOOP;
  END IF;

  RETURN NEW;
END;
$$;

-- El trigger trg_notify_reservation_paid (sql/478) ya apunta a esta función.

COMMIT;

-- ── VERIFICACIÓN ──────────────────────────────────────────────────────────────
SELECT prosrc LIKE '%Ticket para descargar%' AS avisa_ticket
FROM pg_proc WHERE proname = 'notify_reservation_paid';
-- Esperado: true

SELECT '489_admin_ticket_ready_notification.sql ejecutado ✅' AS status;
