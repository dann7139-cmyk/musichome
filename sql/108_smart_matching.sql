-- ════════════════════════════════════════════════════════════════════════════
-- 108_smart_matching.sql
-- Sistema de matching inteligente para solicitudes express (estilo Uber)
--
-- LO QUE IMPLEMENTA ESTE ARCHIVO:
--   1. calculate_matching_score()   — fórmula ponderada 0–100 por grupo+solicitud
--   2. get_best_matching_groups()   — ranking inteligente de grupos disponibles
--   3. request_matching_state       — tabla de estado de matching por solicitud
--   4. start_smart_matching()       — inicia el matching al crear la solicitud
--   5. process_matching_queue()     — cron cada 60 s, avanza olas progresivas
--   6. instant_accept_request()     — asignación rápida: grupo acepta sin negociar
--   7. get_request_search_status()  — estado en tiempo real para el cliente
--   8. Trigger AFTER INSERT en event_requests → inicia matching automático
--
-- Fórmula matching_score (0–100):
--   distancia       × 30 %   → 5 km=100, 10 km=70, 25 km=40, >25 km=20
--   ranking_score   × 25 %   → normalizado 0-5 → 0-100
--   reliability     × 20 %   → ya es 0-100
--   respuesta       × 15 %   → normalizado por velocidad promedio
--   actividad reciente × 10 % → min(eventos_30d × 10, 100)
--   +10 bonus si available_now = TRUE
--
-- Olas progresivas:
--   Ola 1: top 3  → inmediato
--   Ola 2: sig 5  → +60 s
--   Ola 3: sig 5  → +60 s
--   Ola N: sig 5  → +60 s  (hasta que alguien acepte o se agoten grupos)
--
-- Ejecutar DESPUÉS de 107_reliability_system.sql
-- ════════════════════════════════════════════════════════════════════════════


-- ────────────────────────────────────────────────────────────────────────────
-- PARTE 1: TABLA DE ESTADO DE MATCHING
-- ────────────────────────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS public.request_matching_state (
  request_id          UUID        PRIMARY KEY
                        REFERENCES public.event_requests(id) ON DELETE CASCADE,
  current_wave        SMALLINT    NOT NULL DEFAULT 0,
  last_wave_sent_at   TIMESTAMPTZ,
  notified_group_ids  UUID[]      NOT NULL DEFAULT '{}',
  status_message      TEXT        NOT NULL DEFAULT 'Buscando grupos disponibles cerca de ti...',
  is_active           BOOLEAN     NOT NULL DEFAULT TRUE,
  created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_matching_active
  ON public.request_matching_state(is_active, last_wave_sent_at)
  WHERE is_active = TRUE;

-- RLS: solo el cliente dueño de la solicitud puede leer el estado
ALTER TABLE public.request_matching_state ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "matching_state_client_select" ON public.request_matching_state;
CREATE POLICY "matching_state_client_select"
  ON public.request_matching_state FOR SELECT
  USING (
    EXISTS (
      SELECT 1 FROM public.event_requests er
      WHERE er.id = request_id AND er.client_id = auth.uid()
    )
  );


-- ────────────────────────────────────────────────────────────────────────────
-- PARTE 2: calculate_matching_score()
-- ────────────────────────────────────────────────────────────────────────────
-- Devuelve un puntaje 0–100 que mide qué tan buena es la pareja grupo↔solicitud.
-- Usado internamente por get_best_matching_groups() y notify_matching_wave().

CREATE OR REPLACE FUNCTION public.calculate_matching_score(
  p_group_id   UUID,
  p_request_id UUID
)
RETURNS NUMERIC
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_req            RECORD;
  v_group          RECORD;
  v_dist_km        NUMERIC;
  v_dist_score     NUMERIC;
  v_rank_score     NUMERIC;
  v_rel_score      NUMERIC;
  v_resp_score     NUMERIC;
  v_activity_score NUMERIC;
  v_total          NUMERIC;
BEGIN
  SELECT er.*, gl_req.lat AS req_lat, gl_req.lng AS req_lng
  INTO   v_req
  FROM   public.event_requests er
  -- Coordenadas del evento vienen de la columna en event_requests (añadida en 103)
  LEFT JOIN LATERAL (SELECT er.event_lat AS lat, er.event_lng AS lng) gl_req ON TRUE
  WHERE  er.id = p_request_id;

  IF NOT FOUND THEN RETURN 0; END IF;

  SELECT g.*, gl.lat, gl.lng
  INTO   v_group
  FROM   public.groups g
  LEFT JOIN public.group_locations gl ON gl.group_id = g.id
  WHERE  g.id = p_group_id;

  IF NOT FOUND THEN RETURN 0; END IF;

  -- ── Puntaje de distancia (30 %) ────────────────────────────────────────
  IF v_group.lat IS NOT NULL AND v_req.event_lat IS NOT NULL THEN
    v_dist_km := haversine_km(v_group.lat, v_group.lng, v_req.event_lat, v_req.event_lng);
    v_dist_score := CASE
      WHEN v_dist_km <=  5 THEN 100
      WHEN v_dist_km <= 10 THEN 70
      WHEN v_dist_km <= 25 THEN 40
      ELSE                       20
    END;
  ELSE
    v_dist_score := 50;  -- sin coordenadas: puntaje neutro
  END IF;

  -- ── Puntaje de ranking (25 %) — normaliza 0-5 → 0-100 ─────────────────
  v_rank_score := LEAST(COALESCE(v_group.ranking_score, 0) / 5.0 * 100, 100);

  -- ── Puntaje de confiabilidad (20 %) — ya es 0-100 ──────────────────────
  v_rel_score := COALESCE(v_group.reliability_score, 0);

  -- ── Puntaje de velocidad de respuesta (15 %) ──────────────────────────
  SELECT CASE
    WHEN COUNT(*) = 0 THEN 50  -- sin historial: puntaje neutro
    ELSE
      CASE
        WHEN AVG(EXTRACT(EPOCH FROM (pl.proposed_at - er.created_at)) / 60) <  5 THEN 100
        WHEN AVG(EXTRACT(EPOCH FROM (pl.proposed_at - er.created_at)) / 60) < 15 THEN 80
        WHEN AVG(EXTRACT(EPOCH FROM (pl.proposed_at - er.created_at)) / 60) < 30 THEN 60
        WHEN AVG(EXTRACT(EPOCH FROM (pl.proposed_at - er.created_at)) / 60) < 60 THEN 40
        ELSE 20
      END
  END
  INTO v_resp_score
  FROM public.proposal_logs pl
  JOIN public.event_requests er ON er.id = pl.request_id
  WHERE pl.group_id = p_group_id
    AND pl.proposed_at >= NOW() - INTERVAL '60 days';

  v_resp_score := COALESCE(v_resp_score, 50);

  -- ── Puntaje de actividad reciente (10 %) ──────────────────────────────
  SELECT LEAST(COUNT(*) * 10, 100)
  INTO   v_activity_score
  FROM   public.reservations
  WHERE  group_id = p_group_id
    AND  status   = 'completed'
    AND  updated_at >= NOW() - INTERVAL '30 days';

  v_activity_score := COALESCE(v_activity_score, 0);

  -- ── Total ponderado ───────────────────────────────────────────────────
  v_total :=
      (v_dist_score    * 0.30)
    + (v_rank_score    * 0.25)
    + (v_rel_score     * 0.20)
    + (v_resp_score    * 0.15)
    + (v_activity_score * 0.10);

  -- Bonus: disponible ahora → +10 pts (incentiva activar available_now)
  IF COALESCE(v_group.available_now, FALSE) THEN
    v_total := v_total + 10;
  END IF;

  RETURN LEAST(GREATEST(v_total, 0), 100);

EXCEPTION WHEN OTHERS THEN
  RETURN 0;
END;
$$;

GRANT EXECUTE ON FUNCTION public.calculate_matching_score(UUID, UUID) TO authenticated, service_role;


-- ────────────────────────────────────────────────────────────────────────────
-- PARTE 3: get_best_matching_groups()
-- ────────────────────────────────────────────────────────────────────────────
-- Devuelve los grupos ordenados por matching_score para una solicitud.
-- Filtra: mismo género, is_active, availability = 'available', no expirados.
-- Excluye grupos ya notificados (p_exclude_ids).

CREATE OR REPLACE FUNCTION public.get_best_matching_groups(
  p_request_id  UUID,
  p_limit       INT     DEFAULT 10,
  p_offset      INT     DEFAULT 0,
  p_exclude_ids UUID[]  DEFAULT '{}'
)
RETURNS TABLE (
  group_id        UUID,
  owner_id        UUID,
  group_name      TEXT,
  matching_score  NUMERIC,
  distance_km     NUMERIC,
  ranking_score   NUMERIC,
  reliability_score NUMERIC,
  available_now   BOOLEAN
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_req RECORD;
BEGIN
  SELECT * INTO v_req FROM public.event_requests WHERE id = p_request_id;
  IF NOT FOUND THEN RETURN; END IF;

  RETURN QUERY
  SELECT
    g.id                                                          AS group_id,
    g.owner_id,
    g.name                                                        AS group_name,
    public.calculate_matching_score(g.id, p_request_id)          AS matching_score,
    CASE
      WHEN gl.lat IS NOT NULL AND v_req.event_lat IS NOT NULL
        THEN ROUND(haversine_km(gl.lat, gl.lng,
                                v_req.event_lat, v_req.event_lng)::NUMERIC, 1)
      ELSE NULL
    END                                                           AS distance_km,
    ROUND(COALESCE(g.ranking_score, 0)::NUMERIC, 2)              AS ranking_score,
    ROUND(COALESCE(g.reliability_score, 0)::NUMERIC, 0)          AS reliability_score,
    COALESCE(g.available_now, FALSE)                              AS available_now
  FROM public.groups g
  LEFT JOIN public.group_locations gl ON gl.group_id = g.id
  WHERE g.genre     = v_req.genre
    AND g.is_active = TRUE
    AND COALESCE(g.availability, 'available') = 'available'
    AND NOT (g.id = ANY(COALESCE(p_exclude_ids, '{}')))
  ORDER BY public.calculate_matching_score(g.id, p_request_id) DESC
  LIMIT  p_limit
  OFFSET p_offset;
END;
$$;

GRANT EXECUTE ON FUNCTION public.get_best_matching_groups(UUID, INT, INT, UUID[]) TO authenticated, service_role;


-- ────────────────────────────────────────────────────────────────────────────
-- PARTE 4: _notify_matching_wave()  (función interna)
-- ────────────────────────────────────────────────────────────────────────────
-- Envía notificaciones a un lote de grupos con el mejor matching_score.
-- Devuelve el número de grupos notificados.

CREATE OR REPLACE FUNCTION public._notify_matching_wave(
  p_request_id  UUID,
  p_wave        INT
)
RETURNS INT
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_req        RECORD;
  v_state      RECORD;
  v_row        RECORD;
  v_count      INT := 0;
  v_batch_size INT;
  v_body       TEXT;
  v_new_ids    UUID[];
BEGIN
  SELECT * INTO v_req
  FROM public.event_requests
  WHERE id = p_request_id AND status = 'open';

  IF NOT FOUND THEN RETURN 0; END IF;

  SELECT * INTO v_state
  FROM public.request_matching_state
  WHERE request_id = p_request_id;

  -- Tamaño de lote: 3 en la ola 1, 5 en olas siguientes
  v_batch_size := CASE WHEN p_wave = 1 THEN 3 ELSE 5 END;

  v_body := 'Evento de ' || v_req.hours || 'h el ' ||
            TO_CHAR(v_req.event_date, 'DD Mon') ||
            ' en ' || COALESCE(v_req.location_city, 'tu zona') ||
            '. ¡Sé el primero en aceptar!';

  FOR v_row IN
    SELECT * FROM public.get_best_matching_groups(
      p_request_id,
      v_batch_size,
      0,
      COALESCE(v_state.notified_group_ids, '{}')
    )
  LOOP
    INSERT INTO public.notifications (user_id, type, title, body, data)
    VALUES (
      v_row.owner_id,
      'booking',
      '⚡ Nueva solicitud express disponible',
      v_body,
      jsonb_build_object(
        'request_id',      p_request_id,
        'screen',          'OpenRequests',
        'matching_score',  ROUND(v_row.matching_score::NUMERIC, 0),
        'distance_km',     v_row.distance_km,
        'wave',            p_wave
      )
    );
    v_count := v_count + 1;
  END LOOP;

  -- Actualizar estado de matching
  SELECT array_agg(group_id)
  INTO   v_new_ids
  FROM   public.get_best_matching_groups(
    p_request_id, v_batch_size, 0,
    COALESCE(v_state.notified_group_ids, '{}')
  );

  UPDATE public.request_matching_state
  SET current_wave       = p_wave,
      last_wave_sent_at  = NOW(),
      notified_group_ids = COALESCE(notified_group_ids, '{}') ||
                           COALESCE(v_new_ids, '{}'),
      status_message     = CASE
        WHEN p_wave = 1 THEN 'Notificando a los mejores grupos para tu evento...'
        WHEN p_wave = 2 THEN 'Encontrando el mejor grupo para tu evento...'
        ELSE                 'Ampliando la búsqueda de grupos disponibles...'
      END
  WHERE request_id = p_request_id;

  RETURN v_count;
END;
$$;


-- ────────────────────────────────────────────────────────────────────────────
-- PARTE 5: start_smart_matching()
-- ────────────────────────────────────────────────────────────────────────────
-- Punto de entrada principal. Crea el estado de matching y envía la ola 1.
-- Reemplaza notify_express_groups() / notify_wave_1().
-- Puede llamarse manualmente o desde el trigger de INSERT en event_requests.

CREATE OR REPLACE FUNCTION public.start_smart_matching(p_request_id UUID)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_notified INT;
BEGIN
  -- Crear estado de matching si no existe
  INSERT INTO public.request_matching_state (request_id)
  VALUES (p_request_id)
  ON CONFLICT (request_id) DO NOTHING;

  -- Enviar ola 1 (top 3 grupos)
  v_notified := public._notify_matching_wave(p_request_id, 1);

  RETURN jsonb_build_object(
    'ok',          TRUE,
    'request_id',  p_request_id,
    'wave',        1,
    'notified',    v_notified
  );

EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('ok', FALSE, 'error', SQLERRM);
END;
$$;

GRANT EXECUTE ON FUNCTION public.start_smart_matching(UUID) TO authenticated, service_role;


-- ────────────────────────────────────────────────────────────────────────────
-- PARTE 6: process_matching_queue()
-- ────────────────────────────────────────────────────────────────────────────
-- Se ejecuta cada 60 segundos (cron).
-- Para cada solicitud activa cuya última ola fue hace ≥ 60 s:
--   • Si la solicitud ya no está 'open' → desactivar matching
--   • Si expiró → desactivar
--   • Si hay más grupos → enviar siguiente ola
--   • Si no hay más grupos disponibles → desactivar

CREATE OR REPLACE FUNCTION public.process_matching_queue()
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_state      RECORD;
  v_req        RECORD;
  v_notified   INT;
  v_processed  INT := 0;
  v_advanced   INT := 0;
  v_closed     INT := 0;
BEGIN
  FOR v_state IN
    SELECT ms.*
    FROM   public.request_matching_state ms
    WHERE  ms.is_active = TRUE
      AND  ms.last_wave_sent_at < NOW() - INTERVAL '60 seconds'
    ORDER BY ms.last_wave_sent_at ASC
    LIMIT 50  -- procesar máx 50 por ciclo para no bloquear
  LOOP
    v_processed := v_processed + 1;

    -- Leer solicitud actual
    SELECT * INTO v_req
    FROM   public.event_requests
    WHERE  id = v_state.request_id;

    -- Desactivar si ya no está open (aceptada, cancelada, expirada, etc.)
    IF NOT FOUND
       OR v_req.status <> 'open'
       OR COALESCE(v_req.expires_at, NOW() + INTERVAL '1 hour') < NOW() THEN

      UPDATE public.request_matching_state
      SET is_active      = FALSE,
          status_message = CASE
            WHEN v_req.status IN ('accepted', 'en_negociacion') THEN
              '¡Grupo encontrado! Revisa los detalles del evento.'
            ELSE
              'La búsqueda ha finalizado.'
          END
      WHERE request_id = v_state.request_id;
      v_closed := v_closed + 1;
      CONTINUE;
    END IF;

    -- Enviar siguiente ola
    v_notified := public._notify_matching_wave(
      v_state.request_id,
      v_state.current_wave + 1
    );

    IF v_notified > 0 THEN
      v_advanced := v_advanced + 1;
    ELSE
      -- Sin más grupos disponibles → cerrar matching
      UPDATE public.request_matching_state
      SET is_active      = FALSE,
          status_message = 'No hay más grupos disponibles en tu zona. Intenta más tarde.'
      WHERE request_id = v_state.request_id;
      v_closed := v_closed + 1;
    END IF;

  END LOOP;

  RETURN jsonb_build_object(
    'ok',        TRUE,
    'processed', v_processed,
    'advanced',  v_advanced,
    'closed',    v_closed
  );

EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('ok', FALSE, 'error', SQLERRM);
END;
$$;

GRANT EXECUTE ON FUNCTION public.process_matching_queue() TO service_role;


-- ────────────────────────────────────────────────────────────────────────────
-- PARTE 7: instant_accept_request()
-- ────────────────────────────────────────────────────────────────────────────
-- El grupo acepta la solicitud express en un solo paso:
--   • Bloquea la solicitud (FOR UPDATE)
--   • Crea la reserva en estado 'pending' (el cliente confirma y paga)
--   • Marca la solicitud como 'accepted'
--   • Notifica al cliente con el total calculado
-- No requiere que el cliente acepte manualmente; el flujo de pago continúa
-- con la reserva ya creada (igual que client_accept_proposal).

CREATE OR REPLACE FUNCTION public.instant_accept_request(
  p_request_id     UUID,
  p_price_per_hour NUMERIC  DEFAULT 0,
  p_travel_cost    NUMERIC  DEFAULT 0,
  p_notes          TEXT     DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_req     RECORD;
  v_group   RECORD;
  v_hours   INTEGER;
  v_base    NUMERIC;
  v_total   NUMERIC;
  v_comm    NUMERIC;
  v_earn    NUMERIC;
  v_addr    TEXT;
  v_res_id  UUID;
BEGIN
  -- Verificar que el usuario autenticado tiene un grupo
  SELECT * INTO v_group
  FROM public.groups
  WHERE owner_id = auth.uid()
  LIMIT 1;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', FALSE, 'error', 'no_group_found');
  END IF;

  -- Bloquear la solicitud (evita race condition con otro grupo)
  SELECT * INTO v_req
  FROM public.event_requests
  WHERE id = p_request_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', FALSE, 'error', 'request_not_found');
  END IF;

  IF v_req.status <> 'open' THEN
    RETURN jsonb_build_object('ok', FALSE, 'error', 'request_no_longer_available');
  END IF;

  IF COALESCE(v_req.expires_at, NOW() + INTERVAL '1 hour') < NOW() THEN
    RETURN jsonb_build_object('ok', FALSE, 'error', 'request_expired');
  END IF;

  IF v_group.genre <> v_req.genre THEN
    RETURN jsonb_build_object('ok', FALSE, 'error', 'genre_mismatch');
  END IF;

  -- Calcular montos
  v_hours := COALESCE(v_req.hours, 3);
  v_base  := COALESCE(p_price_per_hour, 0) * v_hours;
  v_total := v_base + COALESCE(p_travel_cost, 0);
  v_comm  := v_hours * 150;
  v_earn  := GREATEST(v_total - v_comm, 0);

  -- Dirección del evento
  v_addr := COALESCE(
    NULLIF(v_req.location_address, ''),
    v_req.location_city || ', ' || v_req.location_estado
  );

  -- Crear reserva directamente en 'pending'
  -- (el cliente confirma + paga por el flujo normal)
  INSERT INTO public.reservations (
    group_id,
    client_id,
    event_date,
    event_time,
    address,
    notes,
    total_price,
    platform_commission,
    group_earnings,
    status,
    hours_count,
    event_request_id
  )
  VALUES (
    v_group.id,
    v_req.client_id,
    v_req.event_date,
    v_req.event_time::TIME,
    v_addr,
    p_notes,
    v_total,
    v_comm,
    v_earn,
    'pending',
    v_hours,
    p_request_id
  )
  RETURNING id INTO v_res_id;

  -- Marcar solicitud como aceptada
  UPDATE public.event_requests
  SET status                  = 'accepted',
      negotiating_group_id    = auth.uid(),
      accepted_by_group_id    = v_group.id,
      accepted_reservation_id = v_res_id,
      proposal_data           = jsonb_build_object(
        'price_per_hour',    p_price_per_hour,
        'travel_cost',       COALESCE(p_travel_cost, 0),
        'base_price',        v_base,
        'total_amount',      v_total,
        'commission_amount', v_comm,
        'group_earnings',    v_earn,
        'notes',             p_notes,
        'instant_accept',    TRUE
      )
  WHERE id = p_request_id;

  -- Cerrar matching para esta solicitud
  UPDATE public.request_matching_state
  SET is_active      = FALSE,
      status_message = '¡Grupo encontrado! Revisa los detalles del evento.'
  WHERE request_id = p_request_id;

  -- Registrar en proposal_logs (para rate-limiting y métricas)
  INSERT INTO public.proposal_logs (group_id, request_id)
  VALUES (v_group.id, p_request_id);

  -- Notificar al cliente
  INSERT INTO public.notifications (user_id, type, title, body, data)
  VALUES (
    v_req.client_id,
    'booking',
    '🎵 ¡Grupo listo para tu evento!',
    '"' || v_group.name || '" aceptó tocar en tu evento del ' ||
    TO_CHAR(v_req.event_date, 'DD/MM/YYYY') ||
    CASE
      WHEN v_total > 0
        THEN '. Total: $' || TRUNC(v_total)::TEXT || ' MXN. Confírmalo para asegurar tu fecha.'
      ELSE '. Confírmalo para asegurar tu fecha.'
    END,
    jsonb_build_object(
      'request_id',     p_request_id,
      'reservation_id', v_res_id,
      'group_id',       v_group.id,
      'screen',         'ReservationDetail'
    )
  );

  RETURN jsonb_build_object(
    'ok',             TRUE,
    'group_name',     v_group.name,
    'group_id',       v_group.id,
    'reservation_id', v_res_id,
    'total',          v_total
  );

EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('ok', FALSE, 'error', SQLERRM);
END;
$$;

GRANT EXECUTE ON FUNCTION public.instant_accept_request(UUID, NUMERIC, NUMERIC, TEXT) TO authenticated;


-- ────────────────────────────────────────────────────────────────────────────
-- PARTE 8: get_request_search_status()
-- ────────────────────────────────────────────────────────────────────────────
-- El cliente hace polling cada pocos segundos para actualizar la UI.
-- Devuelve: status_message, wave actual, grupos notificados, estado del request.

CREATE OR REPLACE FUNCTION public.get_request_search_status(p_request_id UUID)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_req   RECORD;
  v_state RECORD;
BEGIN
  SELECT * INTO v_req
  FROM public.event_requests
  WHERE id = p_request_id AND client_id = auth.uid();

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', FALSE, 'error', 'not_found');
  END IF;

  SELECT * INTO v_state
  FROM public.request_matching_state
  WHERE request_id = p_request_id;

  RETURN jsonb_build_object(
    'ok',               TRUE,
    'request_status',   v_req.status,
    'is_searching',     COALESCE(v_state.is_active, FALSE),
    'current_wave',     COALESCE(v_state.current_wave, 0),
    'groups_notified',  COALESCE(array_length(v_state.notified_group_ids, 1), 0),
    'status_message',   COALESCE(
      v_state.status_message,
      CASE v_req.status
        WHEN 'open'            THEN 'Buscando grupos disponibles cerca de ti...'
        WHEN 'en_negociacion'  THEN 'Un grupo está revisando tu solicitud...'
        WHEN 'accepted'        THEN '¡Grupo encontrado! Revisa los detalles del evento.'
        WHEN 'completed'       THEN 'Evento completado.'
        WHEN 'expired'         THEN 'La solicitud ha expirado.'
        WHEN 'cancelled'       THEN 'La solicitud fue cancelada.'
        ELSE                        'Procesando...'
      END
    ),
    'reservation_id',   v_req.accepted_reservation_id,
    'expires_at',       v_req.expires_at
  );

EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('ok', FALSE, 'error', SQLERRM);
END;
$$;

GRANT EXECUTE ON FUNCTION public.get_request_search_status(UUID) TO authenticated;


-- ────────────────────────────────────────────────────────────────────────────
-- PARTE 9: TRIGGER — inicia matching automáticamente al crear solicitud
-- ────────────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION public._trg_start_smart_matching()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NEW.status = 'open' THEN
    PERFORM public.start_smart_matching(NEW.id);
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_start_smart_matching ON public.event_requests;
CREATE TRIGGER trg_start_smart_matching
  AFTER INSERT ON public.event_requests
  FOR EACH ROW
  EXECUTE FUNCTION public._trg_start_smart_matching();


-- ────────────────────────────────────────────────────────────────────────────
-- PARTE 10: CRON — avanza olas cada 60 segundos
-- ────────────────────────────────────────────────────────────────────────────

DO $$ BEGIN PERFORM cron.unschedule('smart-matching-queue'); EXCEPTION WHEN OTHERS THEN NULL; END; $$;
SELECT cron.schedule(
  'smart-matching-queue',
  '* * * * *',
  $$ SELECT public.process_matching_queue(); $$
);


-- ════════════════════════════════════════════════════════════════════════════
-- USO DESDE EL FRONTEND
-- ════════════════════════════════════════════════════════════════════════════
--
-- ── CLIENTE: crear solicitud express ─────────────────────────────────────
--    supabase.from('event_requests').insert({ genre, event_date, hours,
--      location_city, event_lat, event_lng, ... })
--    → El trigger inicia el smart matching automáticamente.
--
-- ── CLIENTE: polling de estado (cada 3-5 s) ──────────────────────────────
--    supabase.rpc('get_request_search_status', { p_request_id: id })
--    → {
--        is_searching: true,
--        current_wave: 2,
--        groups_notified: 8,
--        status_message: "Encontrando el mejor grupo para tu evento...",
--        request_status: "open" | "en_negociacion" | "accepted"
--      }
--    Mostrar status_message en la pantalla mientras is_searching = true.
--    Cuando request_status = 'accepted', redirigir a ReservationDetail.
--
-- ── CLIENTE: ver ranking de grupos para su solicitud ─────────────────────
--    supabase.rpc('get_best_matching_groups', { p_request_id: id, p_limit: 5 })
--    → [{ group_id, group_name, matching_score, distance_km, ... }]
--
-- ── GRUPO: aceptar instantáneamente (sin negociar) ───────────────────────
--    supabase.rpc('instant_accept_request', {
--      p_request_id:     id,
--      p_price_per_hour: 800,
--      p_travel_cost:    0,
--      p_notes:          "Llegamos 30 min antes"
--    })
--    → { ok: true, reservation_id, group_name, total: 2400 }
--    El cliente recibe push: "¡Grupo listo para tu evento!"
--    El cliente confirma y paga → flujo normal de reservas.
--
-- ── GRUPO: proponer con negociación (flujo original) ─────────────────────
--    supabase.rpc('propose_event_request', { p_request_id: id, ... })
--    → Igual que antes (no cambia).
-- ════════════════════════════════════════════════════════════════════════════

SELECT '108_smart_matching: matching inteligente + olas progresivas + instant_accept ✅' AS status;
