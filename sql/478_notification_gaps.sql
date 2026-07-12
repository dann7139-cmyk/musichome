-- ============================================================
-- sql/478_notification_gaps.sql
-- 🔔 HUECOS DE NOTIFICACIONES (auditoría 2026-07-12). 4 fixes:
--
--  1. Push EXPRESS al grupo ahora dice CUÁNDO es el evento:
--     "¡en ~45 min!", "HOY 8:00pm (en ~2h)" o "mañana 8:00pm".
--  2. Aceptación EXPRESS ya notifica (regresión de sql/416 que borró
--     los avisos): dueño + integrantes se enteran al instante.
--  3. Reserva PAGADA: el CLIENTE recibe confirmación in-app y los
--     INTEGRANTES se enteran de que la tocada quedó asegurada
--     (el dueño ya recibía su aviso del RPC de pago — sin duplicar).
--  4. Reserva CANCELADA: cliente (confirmación) + integrantes
--     (el dueño y admin ya recibían el suyo — sin duplicar).
--
-- Todo son triggers/notificaciones — NO toca RPCs de dinero, wallet,
-- GPS ni candados. Idempotente (CREATE OR REPLACE + DROP TRIGGER IF EXISTS).
-- ============================================================

BEGIN;

-- ────────────────────────────────────────────────────────────
-- 1) Express dispatch push v3: incluir tiempo restante al evento
-- ────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.notify_group_on_express_dispatch()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_owner_id    uuid;
  v_genre       text;
  v_city        text;
  v_notif_id    uuid;
  v_push_title  text;
  v_push_body   text;
  v_when        text;
  v_event_ts    timestamp;
  v_now_mx      timestamp;
  v_mins        numeric;
  v_tok         RECORD;
BEGIN
  IF NEW.status <> 'pending_broadcast' THEN
    RETURN NEW;
  END IF;

  SELECT g.owner_id, g.genre, g.city
    INTO v_owner_id, v_genre, v_city
    FROM public.groups g
   WHERE g.id = NEW.group_id;

  IF v_owner_id IS NULL THEN
    RETURN NEW;
  END IF;

  -- ⏱ Cuándo es el evento (hora local de México)
  SELECT (r.event_date::timestamp + COALESCE(r.event_time, '20:00'::time))
    INTO v_event_ts
    FROM public.event_requests r
   WHERE r.id = NEW.request_id;

  v_now_mx := (NOW() AT TIME ZONE 'America/Mexico_City');
  v_when   := NULL;

  IF v_event_ts IS NOT NULL THEN
    v_mins := EXTRACT(EPOCH FROM (v_event_ts - v_now_mx)) / 60.0;
    IF v_mins <= 0 THEN
      v_when := '¡es AHORA!';
    ELSIF v_mins <= 120 THEN
      v_when := '¡tocarías en ~' || GREATEST(ROUND(v_mins), 10)::int || ' min!';
    ELSIF v_event_ts::date = v_now_mx::date THEN
      v_when := 'HOY ' || TRIM(to_char(v_event_ts, 'HH12:MI am'))
                || ' (en ~' || ROUND(v_mins / 60.0)::int || 'h)';
    ELSIF v_event_ts::date = v_now_mx::date + 1 THEN
      v_when := 'mañana ' || TRIM(to_char(v_event_ts, 'HH12:MI am'));
    ELSE
      v_when := 'el ' || to_char(v_event_ts, 'DD/MM') || ' a las '
                || TRIM(to_char(v_event_ts, 'HH12:MI am'));
    END IF;
  END IF;

  v_push_title := '⚡ Solicitud Express para ti';
  v_push_body  := 'Solicitud de ' || COALESCE(v_genre, 'música') ||
                  ' en ' || COALESCE(v_city, 'tu zona') ||
                  COALESCE(' — ' || v_when, '') ||
                  ' ¡Responde rápido!';

  INSERT INTO public.notifications (user_id, type, title, body, data, push_sent_at)
  VALUES (
    v_owner_id,
    'express_dispatch',
    v_push_title,
    v_push_body,
    jsonb_build_object(
      'type',       'express_dispatch',
      'dispatchId', NEW.id::TEXT,
      'screen',     'IncomingExpress'
    ),
    NOW()
  )
  RETURNING id INTO v_notif_id;

  FOR v_tok IN
    SELECT token FROM public.push_tokens WHERE user_id = v_owner_id
  LOOP
    PERFORM net.http_post(
      url     := 'https://exp.host/--/api/v2/push/send',
      headers := '{"Content-Type":"application/json","Accept":"application/json","Accept-Encoding":"gzip, deflate"}'::jsonb,
      body    := jsonb_build_object(
        'to',       v_tok.token,
        'title',    v_push_title,
        'body',     v_push_body,
        'data',     jsonb_build_object(
          'type',       'express_dispatch',
          'dispatchId', NEW.id::TEXT,
          'screen',     'IncomingExpress'
        ),
        'sound',      'default',
        'priority',   'high',
        'channelId',  'default'
      )
    );
  END LOOP;

  RETURN NEW;
END;
$$;

-- El trigger ya existe (222/223) apuntando a esta función — no se recrea.

-- ────────────────────────────────────────────────────────────
-- Helper: integrantes/invitados aceptados de un grupo
-- ────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public._group_member_ids(p_group_id UUID)
RETURNS SETOF UUID LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT DISTINCT invited_user_id
  FROM job_invitations
  WHERE group_id = p_group_id
    AND status = 'accepted'
    AND invited_user_id IS NOT NULL;
$$;

-- ────────────────────────────────────────────────────────────
-- 2) Aceptación EXPRESS → avisar a dueño + integrantes
--    (hook: la reserva express nace con event_request_id)
-- ────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.notify_express_accepted()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_owner UUID;
  v_body  TEXT;
  v_uid   UUID;
BEGIN
  IF NEW.event_request_id IS NULL THEN RETURN NEW; END IF;

  SELECT owner_id INTO v_owner FROM groups WHERE id = NEW.group_id;
  IF v_owner IS NULL THEN RETURN NEW; END IF;

  v_body := format('El cliente aceptó tu propuesta para el %s a las %s. Se confirma en cuanto pague — mantente pendiente.',
                   to_char(NEW.event_date, 'DD/MM'),
                   TRIM(to_char(NEW.event_date::timestamp + COALESCE(NEW.event_time, '20:00'::time), 'HH12:MI am')));

  INSERT INTO notifications (user_id, type, title, body, data)
  VALUES (v_owner, 'reservation', '🎉 ¡Aceptaron tu propuesta express!', v_body,
          jsonb_build_object('reservation_id', NEW.id, 'screen', 'GroupReservations'));

  FOR v_uid IN SELECT * FROM _group_member_ids(NEW.group_id) LOOP
    IF v_uid <> v_owner THEN
      INSERT INTO notifications (user_id, type, title, body, data)
      VALUES (v_uid, 'reservation', '🎉 ¡Aceptaron la propuesta express de tu grupo!', v_body,
              jsonb_build_object('reservation_id', NEW.id, 'screen', 'GroupReservations'));
    END IF;
  END LOOP;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_notify_express_accepted ON reservations;
CREATE TRIGGER trg_notify_express_accepted
  AFTER INSERT ON reservations
  FOR EACH ROW
  WHEN (NEW.event_request_id IS NOT NULL)
  EXECUTE FUNCTION public.notify_express_accepted();

-- ────────────────────────────────────────────────────────────
-- 3) Reserva PAGADA → cliente (confirmación) + integrantes.
--    El dueño ya recibe "💰 Pago confirmado" desde el RPC de pago.
-- ────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.notify_reservation_paid()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_owner UUID;
  v_gname TEXT;
  v_fecha TEXT;
  v_uid   UUID;
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

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_notify_reservation_paid ON reservations;
CREATE TRIGGER trg_notify_reservation_paid
  AFTER UPDATE OF payment_status ON reservations
  FOR EACH ROW
  EXECUTE FUNCTION public.notify_reservation_paid();

-- ────────────────────────────────────────────────────────────
-- 4) Reserva CANCELADA → cliente (confirmación) + integrantes.
--    Dueño + admin ya reciben el suyo desde settle_cancellation.
-- ────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.notify_reservation_cancelled()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_owner UUID;
  v_gname TEXT;
  v_fecha TEXT;
  v_uid   UUID;
BEGIN
  IF NEW.status <> 'cancelled' OR COALESCE(OLD.status, '') = 'cancelled' THEN
    RETURN NEW;
  END IF;

  SELECT owner_id, name INTO v_owner, v_gname FROM groups WHERE id = NEW.group_id;
  v_fecha := to_char(NEW.event_date, 'DD/MM');

  IF NEW.client_id IS NOT NULL THEN
    INSERT INTO notifications (user_id, type, title, body, data)
    VALUES (NEW.client_id, 'reservation',
      '❌ Evento cancelado',
      format('Tu evento con %s del %s (folio %s) quedó cancelado. Si aplica reembolso, te avisaremos su estado por aquí.',
             COALESCE(v_gname, 'el grupo'), v_fecha, COALESCE(NEW.folio, '—')),
      jsonb_build_object('reservation_id', NEW.id, 'screen', 'Reservations'));
  END IF;

  FOR v_uid IN SELECT * FROM _group_member_ids(NEW.group_id) LOOP
    IF v_uid <> COALESCE(v_owner, '00000000-0000-0000-0000-000000000000'::uuid) THEN
      INSERT INTO notifications (user_id, type, title, body, data)
      VALUES (v_uid, 'reservation',
        '❌ Se canceló un evento de tu grupo',
        format('El evento del %s fue cancelado — bájalo de tu agenda.', v_fecha),
        jsonb_build_object('reservation_id', NEW.id, 'screen', 'GroupReservations'));
    END IF;
  END LOOP;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_notify_reservation_cancelled ON reservations;
CREATE TRIGGER trg_notify_reservation_cancelled
  AFTER UPDATE OF status ON reservations
  FOR EACH ROW
  EXECUTE FUNCTION public.notify_reservation_cancelled();

COMMIT;

-- ── VERIFICACIÓN ──────────────────────────────────────────────────────────────
SELECT tgname FROM pg_trigger
WHERE tgrelid = 'public.reservations'::regclass
  AND tgname IN ('trg_notify_express_accepted','trg_notify_reservation_paid','trg_notify_reservation_cancelled');
-- Esperado: 3 filas

SELECT prosrc LIKE '%tocarías en%' AS push_con_tiempo
FROM pg_proc WHERE proname = 'notify_group_on_express_dispatch';
-- Esperado: true

SELECT '478_notification_gaps.sql ejecutado ✅' AS status;
