-- ═══════════════════════════════════════════════════════════════════════════════
-- 94_express_improvements.sql
-- Mejoras de escalabilidad al sistema de solicitudes express
--
-- 1. Columna availability en groups (available / busy / offline)
-- 2. Tabla proposal_logs — historial de propuestas para rate-limiting
-- 3. notify_express_groups() — global, basado en radio configurable (reemplaza GDL)
-- 4. propose_event_request() — con rate-limit de 10 propuestas/hora
-- 5. Trigger check_client_request_limit — máx 3 solicitudes activas por cliente
-- 6. Trigger protect_chat_messages — bloquea teléfonos y redes sociales en chat
--
-- PUSH NOTIFICATIONS: ya implementadas en 11_push_booking_flow.sql +
--   supabase/functions/send-push-notification/index.ts
--
-- Ejecutar DESPUÉS de 93.
-- ═══════════════════════════════════════════════════════════════════════════════

-- ────────────────────────────────────────────────────────────────────────────
-- 1. DISPONIBILIDAD DE GRUPOS
-- ────────────────────────────────────────────────────────────────────────────
-- Columna que el dueño del grupo actualiza manualmente desde el dashboard.
-- Solo los grupos 'available' reciben nuevas solicitudes express.

ALTER TABLE groups
  ADD COLUMN IF NOT EXISTS availability TEXT
    NOT NULL DEFAULT 'available'
    CHECK (availability IN ('available', 'busy', 'offline'));

CREATE INDEX IF NOT EXISTS idx_groups_availability ON groups(availability);

-- RPC: el dueño del grupo actualiza su disponibilidad
CREATE OR REPLACE FUNCTION set_group_availability(p_availability TEXT)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_group RECORD;
BEGIN
  IF p_availability NOT IN ('available', 'busy', 'offline') THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_availability');
  END IF;

  SELECT id INTO v_group
  FROM groups
  WHERE owner_id = auth.uid()
  LIMIT 1;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'no_group_found');
  END IF;

  UPDATE groups
  SET availability = p_availability
  WHERE id = v_group.id;

  RETURN jsonb_build_object('ok', true, 'availability', p_availability);
END;
$$;

GRANT EXECUTE ON FUNCTION set_group_availability(TEXT) TO authenticated;

-- ────────────────────────────────────────────────────────────────────────────
-- 2. TABLA PROPOSAL_LOGS (rate-limiting de propuestas)
-- ────────────────────────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS proposal_logs (
  id          UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  group_id    UUID        NOT NULL REFERENCES groups(id) ON DELETE CASCADE,
  request_id  UUID        NOT NULL,
  proposed_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_proplogg_group_time
  ON proposal_logs(group_id, proposed_at DESC);

-- ────────────────────────────────────────────────────────────────────────────
-- 3. notify_express_groups() — GLOBAL, RADIO CONFIGURABLE
--    Reemplaza notify_express_gdl_groups().
--    Filtra por:
--      • mismo género
--      • is_active = true
--      • availability = 'available'
--      • dentro del radio p_radius_km (default 50 km)
--        si el grupo no tiene coordenadas, se incluye con distancia NULL
--    Ordena por distancia ASC NULLS LAST.
-- ────────────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION public.notify_express_groups(
  p_request_id UUID,
  p_event_lat  DOUBLE PRECISION DEFAULT NULL,
  p_event_lng  DOUBLE PRECISION DEFAULT NULL,
  p_radius_km  DOUBLE PRECISION DEFAULT 50
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_req     RECORD;
  v_group   RECORD;
  v_count   INT := 0;
  v_body    TEXT;
BEGIN
  SELECT * INTO v_req
  FROM event_requests
  WHERE id = p_request_id;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'request_not_found');
  END IF;

  v_body := 'Evento de ' || v_req.hours || 'h el ' ||
            TO_CHAR(v_req.event_date, 'DD Mon') || ' en ' ||
            COALESCE(v_req.location_city, 'tu zona') ||
            '. ¡Sé el primero en aceptar!';

  FOR v_group IN
    SELECT
      g.owner_id,
      g.name,
      gl.lat,
      gl.lng,
      CASE
        WHEN gl.lat IS NOT NULL AND p_event_lat IS NOT NULL THEN
          6371 * 2 * ASIN(SQRT(
            POWER(SIN(RADIANS((gl.lat - p_event_lat) / 2)), 2) +
            COS(RADIANS(p_event_lat)) * COS(RADIANS(gl.lat)) *
            POWER(SIN(RADIANS((gl.lng - p_event_lng) / 2)), 2)
          ))
        ELSE NULL
      END AS dist_km
    FROM groups g
    LEFT JOIN group_locations gl ON gl.group_id = g.id
    WHERE g.genre        = v_req.genre
      AND g.is_active    = TRUE
      AND COALESCE(g.availability, 'available') = 'available'
      AND (
        -- dentro del radio, o sin coordenadas (incluir siempre)
        gl.lat IS NULL
        OR p_event_lat IS NULL
        OR (
          6371 * 2 * ASIN(SQRT(
            POWER(SIN(RADIANS((gl.lat - p_event_lat) / 2)), 2) +
            COS(RADIANS(p_event_lat)) * COS(RADIANS(gl.lat)) *
            POWER(SIN(RADIANS((gl.lng - p_event_lng) / 2)), 2)
          )) <= p_radius_km
        )
      )
    ORDER BY dist_km ASC NULLS LAST, g.created_at ASC
  LOOP
    INSERT INTO notifications (user_id, type, title, body, data)
    VALUES (
      v_group.owner_id,
      'booking',
      '⚡ Nueva tocada express disponible',
      v_body,
      jsonb_build_object(
        'request_id', p_request_id,
        'screen',     'OpenRequests',
        'dist_km',    ROUND(v_group.dist_km::NUMERIC, 1)
      )
    );
    v_count := v_count + 1;
  END LOOP;

  RETURN jsonb_build_object('ok', true, 'notified', v_count);

EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$$;

GRANT EXECUTE ON FUNCTION public.notify_express_groups(UUID, DOUBLE PRECISION, DOUBLE PRECISION, DOUBLE PRECISION) TO authenticated;

-- Mantener alias de la función anterior para compatibilidad con código existente
CREATE OR REPLACE FUNCTION public.notify_express_gdl_groups(
  p_request_id UUID,
  p_event_lat  DOUBLE PRECISION DEFAULT NULL,
  p_event_lng  DOUBLE PRECISION DEFAULT NULL
)
RETURNS JSONB LANGUAGE sql SECURITY DEFINER SET search_path = public AS $$
  SELECT public.notify_express_groups(p_request_id, p_event_lat, p_event_lng, 50);
$$;

GRANT EXECUTE ON FUNCTION public.notify_express_gdl_groups(UUID, DOUBLE PRECISION, DOUBLE PRECISION) TO authenticated;

-- ────────────────────────────────────────────────────────────────────────────
-- 4. propose_event_request() — CON RATE-LIMIT DE 10 PROPUESTAS/HORA
--    Reemplaza la versión de 87_start_time_proposal.sql
-- ────────────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION public.propose_event_request(
  p_request_id     UUID,
  p_price_per_hour NUMERIC  DEFAULT NULL,
  p_travel_cost    NUMERIC  DEFAULT 0,
  p_overtime_1h    NUMERIC  DEFAULT NULL,
  p_overtime_2h    NUMERIC  DEFAULT NULL,
  p_overtime_3h    NUMERIC  DEFAULT NULL,
  p_notes          TEXT     DEFAULT NULL,
  p_member_dist    JSONB    DEFAULT NULL,
  p_arrival_time   TEXT     DEFAULT NULL,
  p_start_time     TEXT     DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_req   RECORD;
  v_group RECORD;
  v_hours INTEGER;
  v_base  NUMERIC;
  v_total NUMERIC;
  v_comm  NUMERIC;
BEGIN
  SELECT * INTO v_group
  FROM groups
  WHERE owner_id = auth.uid()
  LIMIT 1;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'no_group_found');
  END IF;

  -- ── Rate-limit: máx 10 propuestas por hora ──────────────────────────────
  IF (
    SELECT COUNT(*) FROM proposal_logs
    WHERE group_id   = v_group.id
      AND proposed_at >= NOW() - INTERVAL '1 hour'
  ) >= 10 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'rate_limit_exceeded');
  END IF;

  -- Bloquear fila (evita race condition)
  SELECT * INTO v_req
  FROM event_requests
  WHERE id = p_request_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'request_not_found');
  END IF;

  IF v_req.status <> 'open' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_available');
  END IF;

  IF v_req.expires_at < NOW() THEN
    RETURN jsonb_build_object('ok', false, 'error', 'request_expired');
  END IF;

  IF v_group.genre <> v_req.genre THEN
    RETURN jsonb_build_object('ok', false, 'error', 'genre_mismatch');
  END IF;

  -- Calcular totales
  v_hours := COALESCE(v_req.hours, 3);
  v_base  := COALESCE(p_price_per_hour, 0) * v_hours;
  v_total := v_base + COALESCE(p_travel_cost, 0);
  v_comm  := v_hours * 150;

  UPDATE event_requests
  SET
    status               = 'en_negociacion',
    negotiating_group_id = auth.uid(),
    proposal_data        = jsonb_build_object(
      'price_per_hour',    p_price_per_hour,
      'travel_cost',       COALESCE(p_travel_cost, 0),
      'base_price',        v_base,
      'total_amount',      v_total,
      'commission_amount', v_comm,
      'group_earnings',    GREATEST(v_total - v_comm, 0),
      'overtime_1h_price', p_overtime_1h,
      'overtime_2h_price', p_overtime_2h,
      'overtime_3h_price', p_overtime_3h,
      'notes',             p_notes,
      'member_dist',       p_member_dist,
      'arrival_time',      p_arrival_time,
      'start_time',        p_start_time
    )
  WHERE id = p_request_id;

  -- Registrar propuesta en log (para rate-limiting)
  INSERT INTO proposal_logs (group_id, request_id)
  VALUES (v_group.id, p_request_id);

  -- Notificar al cliente
  INSERT INTO notifications (user_id, type, title, body, data)
  VALUES (
    v_req.client_id,
    'booking',
    '📋 ¡Recibiste una cotización!',
    '"' || v_group.name || '" quiere tocar en tu evento' ||
    CASE WHEN p_price_per_hour IS NOT NULL
      THEN '. Total: $' || TRUNC(v_total)::TEXT || ' MXN' ||
           CASE
             WHEN p_start_time   IS NOT NULL THEN '. Tocan a las ' || p_start_time || '.'
             WHEN p_arrival_time IS NOT NULL THEN '. Llegan a las ' || p_arrival_time || '.'
             ELSE '. Toca para ver la propuesta.'
           END
      ELSE '. Revisa su propuesta y decide si lo contratas.'
    END,
    jsonb_build_object(
      'request_id', p_request_id,
      'group_id',   v_group.id,
      'screen',     'OpenRequest'
    )
  );

  RETURN jsonb_build_object(
    'ok',         true,
    'group_name', v_group.name,
    'group_id',   v_group.id,
    'total',      v_total
  );

EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$$;

GRANT EXECUTE ON FUNCTION public.propose_event_request(UUID, NUMERIC, NUMERIC, NUMERIC, NUMERIC, NUMERIC, TEXT, JSONB, TEXT, TEXT) TO authenticated;

-- ────────────────────────────────────────────────────────────────────────────
-- 5. LÍMITE DE SOLICITUDES ACTIVAS POR CLIENTE (máx 3)
--    Trigger BEFORE INSERT en event_requests.
-- ────────────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION check_client_request_limit()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
  IF (
    SELECT COUNT(*)
    FROM event_requests
    WHERE client_id = NEW.client_id
      AND status IN ('open', 'en_negociacion')
  ) >= 3 THEN
    RAISE EXCEPTION 'max_active_requests: Solo puedes tener 3 solicitudes activas a la vez.';
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_client_request_limit ON event_requests;
CREATE TRIGGER trg_client_request_limit
  BEFORE INSERT ON event_requests
  FOR EACH ROW EXECUTE FUNCTION check_client_request_limit();

-- ────────────────────────────────────────────────────────────────────────────
-- 6. PROTECCIÓN DE CHAT
--    Trigger BEFORE INSERT en reservation_messages.
--    Bloquea: números de teléfono, handles sociales, dominios de contacto.
-- ────────────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION protect_chat_messages()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
  -- Bloquear números de teléfono (8+ dígitos con posibles separadores)
  IF NEW.content ~ '(\+?[\d]{3}[\s\-\.]?[\d]{3}[\s\-\.]?[\d]{2,6})' THEN
    RAISE EXCEPTION 'contact_blocked: No puedes compartir números de teléfono antes del pago.';
  END IF;

  -- Bloquear redes sociales y apps de mensajería
  IF NEW.content ~* '(instagram\.com|facebook\.com|wa\.me|t\.me|tiktok\.com|twitter\.com|x\.com|linkedin\.com|snapchat\.com|telegram\.me|@[a-zA-Z0-9_.]{3,}|whatsapp|wha\.tsap|insta\b|tele\s*gram)' THEN
    RAISE EXCEPTION 'contact_blocked: No puedes compartir redes sociales ni apps de mensajería antes del pago.';
  END IF;

  -- Bloquear correos electrónicos
  IF NEW.content ~ '[a-zA-Z0-9._%+\-]+@[a-zA-Z0-9.\-]+\.[a-zA-Z]{2,}' THEN
    RAISE EXCEPTION 'contact_blocked: No puedes compartir correos electrónicos antes del pago.';
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_protect_chat ON reservation_messages;
CREATE TRIGGER trg_protect_chat
  BEFORE INSERT ON reservation_messages
  FOR EACH ROW EXECUTE FUNCTION protect_chat_messages();

-- ────────────────────────────────────────────────────────────────────────────
-- 7. DIRECCIÓN OCULTA EN SOLICITUDES (columna location_address)
--    Los grupos NO deben ver location_address hasta que haya reserva aceptada.
--    Esto se aplica desde el lado cliente (no enviar location_address en queries
--    de event_requests para grupos), pero por seguridad también lo aplicamos
--    a nivel de función: client_accept_proposal() ya copia location_address
--    a la reserva, y la reserva tiene su propia RLS que solo muestra el address
--    al grupo dueño de esa reserva.
--
--    Nota: No se modifica la RLS de event_requests para evitar romper flujos
--    existentes. El cliente de la app solo debe mostrar location_city al grupo
--    durante la negociación, y la dirección completa después del depósito.
-- ────────────────────────────────────────────────────────────────────────────

SELECT '94_express_improvements: disponibilidad + global + rate-limit + chat ✅' AS status;
