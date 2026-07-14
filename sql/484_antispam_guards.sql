-- ============================================================
-- sql/484_antispam_guards.sql
-- 🛡️ ANTI-ABUSO: límites contra clientes que saturan por molestar.
--
--  1. RECLAMOS (open_dispute v3, reemplaza a sql/483 conservando todo):
--     • Máx 3 disputas abiertas por usuario en 30 días → al exceder se
--       bloquea + señal de fraude (severity medium, sube risk_score).
--     • Solo dentro de los 7 días posteriores al evento (lo viejo va
--       a Soporte).
--  2. SOLICITUDES EXPRESS (trigger BEFORE INSERT en event_requests —
--     imposible de brincar aunque el insert venga directo de la app):
--     • Máx 2 solicitudes ACTIVAS (open/en_negociacion) a la vez.
--     • Máx 5 solicitudes en 24 horas → al exceder, señal de fraude.
--  3. COTIZACIONES (trigger BEFORE INSERT en quotes):
--     • Máx 3 cotizaciones PENDIENTES al mismo grupo.
--     • Máx 15 cotizaciones en 24 horas.
--
-- Los mensajes de error son legibles — la app ya los muestra tal cual.
-- NO toca dinero, wallet ni flujos existentes legítimos.
-- ============================================================

BEGIN;

-- ────────────────────────────────────────────────────────────
-- 1) open_dispute v3 — con límites anti-abuso
-- ────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION open_dispute(
  p_reservation_id UUID,
  p_reason         TEXT
)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_caller_id   UUID := auth.uid();
  v_reservation RECORD;
  v_dispute_id  UUID;
  v_owner       UUID;
  v_gname       TEXT;
  v_is_client   BOOLEAN;
  v_recent      INT;
BEGIN
  IF v_caller_id IS NULL THEN
    RAISE EXCEPTION 'unauthorized: sesión requerida';
  END IF;

  SELECT * INTO v_reservation FROM reservations WHERE id = p_reservation_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Reserva no encontrada'; END IF;

  SELECT owner_id, name INTO v_owner, v_gname FROM groups WHERE id = v_reservation.group_id;
  v_is_client := (v_reservation.client_id = v_caller_id);

  IF NOT v_is_client AND v_owner IS DISTINCT FROM v_caller_id THEN
    RAISE EXCEPTION 'unauthorized: no eres parte de esta reserva';
  END IF;

  -- 🛡️ Ventana: solo hasta 7 días después del evento
  IF v_reservation.event_date IS NOT NULL
     AND v_reservation.event_date < (NOW() AT TIME ZONE 'America/Mexico_City')::date - 7 THEN
    RAISE EXCEPTION 'Este evento fue hace más de 7 días. Para aclaraciones antiguas contáctanos desde Soporte.';
  END IF;

  IF EXISTS (
    SELECT 1 FROM disputes
    WHERE reservation_id = p_reservation_id AND status IN ('open','under_review')
  ) THEN
    RAISE EXCEPTION 'Ya existe una disputa abierta para esta reserva';
  END IF;

  -- 🛡️ Máx 3 disputas por usuario en 30 días
  SELECT COUNT(*) INTO v_recent FROM disputes
  WHERE opened_by = v_caller_id AND created_at > NOW() - INTERVAL '30 days';
  IF v_recent >= 3 THEN
    INSERT INTO fraud_signals (user_id, signal_type, severity, description, metadata)
    VALUES (v_caller_id, 'dispute_spam', 'medium',
      'Intentó abrir más de 3 disputas en 30 días',
      jsonb_build_object('reservation_id', p_reservation_id, 'recent_count', v_recent));
    RAISE EXCEPTION 'Has alcanzado el límite de reportes de este mes. Si tienes un caso urgente, contáctanos desde Soporte.';
  END IF;

  INSERT INTO disputes (reservation_id, opened_by, reason, status)
  VALUES (p_reservation_id, v_caller_id, p_reason, 'open')
  RETURNING id INTO v_dispute_id;

  -- Admins → cola de disputas
  INSERT INTO notifications (user_id, type, title, body, data)
  SELECT id, 'dispute', '⚠️ Nueva disputa abierta',
    format('%s abrió una disputa del evento %s (%s): "%s". El pago queda bloqueado hasta resolverla.',
           CASE WHEN v_is_client THEN 'El cliente' ELSE COALESCE(v_gname, 'El grupo') END,
           COALESCE(v_reservation.folio, p_reservation_id::text),
           v_reservation.event_date, LEFT(p_reason, 120)),
    jsonb_build_object('screen','AdminDisputes','dispute_id',v_dispute_id,'reservation_id',p_reservation_id)
  FROM profiles WHERE role = 'admin';

  -- Contraparte → se entera y puede preparar su versión
  IF v_is_client AND v_owner IS NOT NULL THEN
    INSERT INTO notifications (user_id, type, title, body, data)
    VALUES (v_owner, 'dispute',
      '⚠️ El cliente reportó un problema con tu evento',
      format('Evento %s del %s: "%s". El equipo de Daricefy revisará el caso con la evidencia del temporizador — el pago queda en pausa mientras tanto. Si tienes algo que aportar, contáctanos desde Soporte.',
             COALESCE(v_reservation.folio, ''), v_reservation.event_date, LEFT(p_reason, 120)),
      jsonb_build_object('reservation_id', p_reservation_id, 'dispute_id', v_dispute_id, 'screen', 'GroupReservations'));
  ELSIF NOT v_is_client AND v_reservation.client_id IS NOT NULL THEN
    INSERT INTO notifications (user_id, type, title, body, data)
    VALUES (v_reservation.client_id, 'dispute',
      '⚠️ El grupo reportó un problema con el evento',
      format('Evento %s del %s: "%s". El equipo de Daricefy revisará el caso con la evidencia del temporizador. Si tienes algo que aportar, contáctanos desde Soporte.',
             COALESCE(v_reservation.folio, ''), v_reservation.event_date, LEFT(p_reason, 120)),
      jsonb_build_object('reservation_id', p_reservation_id, 'dispute_id', v_dispute_id, 'screen', 'Reservations'));
  END IF;

  RETURN jsonb_build_object('ok', true, 'dispute_id', v_dispute_id);
END;
$$;

GRANT EXECUTE ON FUNCTION open_dispute(UUID, TEXT) TO authenticated;

-- ────────────────────────────────────────────────────────────
-- 2) Anti-spam de solicitudes EXPRESS
-- ────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.guard_event_request_spam()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_active INT;
  v_today  INT;
BEGIN
  IF NEW.client_id IS NULL THEN RETURN NEW; END IF;

  -- Máx 2 solicitudes activas a la vez
  SELECT COUNT(*) INTO v_active FROM event_requests
  WHERE client_id = NEW.client_id AND status IN ('open', 'en_negociacion');
  IF v_active >= 2 THEN
    RAISE EXCEPTION 'Ya tienes % solicitudes activas. Espera a que un grupo responda o cancélalas antes de crear otra.', v_active;
  END IF;

  -- Máx 5 en 24 horas → señal de fraude al exceder
  SELECT COUNT(*) INTO v_today FROM event_requests
  WHERE client_id = NEW.client_id AND created_at > NOW() - INTERVAL '24 hours';
  IF v_today >= 5 THEN
    INSERT INTO fraud_signals (user_id, signal_type, severity, description, metadata)
    VALUES (NEW.client_id, 'express_spam', 'medium',
      'Intentó crear más de 5 solicitudes express en 24h',
      jsonb_build_object('count_24h', v_today));
    RAISE EXCEPTION 'Alcanzaste el límite de solicitudes por hoy. Intenta de nuevo mañana o contáctanos desde Soporte.';
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_guard_event_request_spam ON public.event_requests;
CREATE TRIGGER trg_guard_event_request_spam
  BEFORE INSERT ON public.event_requests
  FOR EACH ROW
  EXECUTE FUNCTION public.guard_event_request_spam();

-- ────────────────────────────────────────────────────────────
-- 3) Anti-spam de COTIZACIONES (programadas)
-- ────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.guard_quote_spam()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_same_group INT;
  v_today      INT;
BEGIN
  IF NEW.client_id IS NULL THEN RETURN NEW; END IF;

  -- Máx 3 cotizaciones pendientes al MISMO grupo
  SELECT COUNT(*) INTO v_same_group FROM quotes
  WHERE client_id = NEW.client_id AND group_id = NEW.group_id AND status = 'pending';
  IF v_same_group >= 3 THEN
    RAISE EXCEPTION 'Ya tienes % cotizaciones pendientes con este grupo. Espera su respuesta antes de enviar otra.', v_same_group;
  END IF;

  -- Máx 15 cotizaciones en 24 horas → señal de fraude al exceder
  SELECT COUNT(*) INTO v_today FROM quotes
  WHERE client_id = NEW.client_id AND created_at > NOW() - INTERVAL '24 hours';
  IF v_today >= 15 THEN
    INSERT INTO fraud_signals (user_id, signal_type, severity, description, metadata)
    VALUES (NEW.client_id, 'quote_spam', 'medium',
      'Intentó enviar más de 15 cotizaciones en 24h',
      jsonb_build_object('count_24h', v_today));
    RAISE EXCEPTION 'Alcanzaste el límite de cotizaciones por hoy. Intenta de nuevo mañana.';
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_guard_quote_spam ON public.quotes;
CREATE TRIGGER trg_guard_quote_spam
  BEFORE INSERT ON public.quotes
  FOR EACH ROW
  EXECUTE FUNCTION public.guard_quote_spam();

COMMIT;

-- ── VERIFICACIÓN ──────────────────────────────────────────────────────────────
SELECT prosrc LIKE '%dispute_spam%' AS disputa_con_limite
FROM pg_proc WHERE proname = 'open_dispute';
-- Esperado: true

SELECT tgname FROM pg_trigger
WHERE tgname IN ('trg_guard_event_request_spam', 'trg_guard_quote_spam');
-- Esperado: 2 filas

SELECT '484_antispam_guards.sql ejecutado ✅' AS status;
