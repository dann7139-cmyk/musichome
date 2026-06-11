-- ════════════════════════════════════════════════════════════════════════════
-- 103_growth_improvements.sql
-- Mejoras de crecimiento y engagement
--
-- 1. Follow-ups automáticos para grupos que no responden solicitudes express
--      +2 min → "Tienes una solicitud disponible cerca de ti."
--      +5 min → "Esta solicitud podría asignarse a otro grupo."
-- 2. Modo "Estoy disponible ahora" para grupos
--      toggle_available_now() RPC (solo el dueño)
--      Grupos disponibles reciben solicitudes con prioridad máxima
--      Se auto-desactiva a las 4 horas
-- 3. Expansión automática de radio (5 → 10 → 20 km)
--      Cuando p_use_radius_expansion = TRUE en notify_wave_1():
--        wave 1 → 5 km (inmediata)
--        wave 2 → 10 km (+2 min)
--        wave 3 → 20 km (+5 min más)
--
-- No modifica el flujo de reservas ni pagos.
-- Ejecutar DESPUÉS de 102_engagement_notifications.sql
-- ════════════════════════════════════════════════════════════════════════════


-- ────────────────────────────────────────────────────────────────────────────
-- PARTE 1: FOLLOW-UPS PARA GRUPOS QUE NO RESPONDEN
-- ────────────────────────────────────────────────────────────────────────────
-- Busca grupos que recibieron una notificación de solicitud express
-- (type = 'booking') pero no han respondido, y envía recordatorios
-- de urgencia creciente a los 2 y 5 minutos.
-- Los follow-ups se identifican por data->>'followup_level' para
-- evitar duplicados y no confundirlos con notificaciones originales.
-- ────────────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION public.send_express_followups()
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_notif   RECORD;
  v_count   INT := 0;
BEGIN

  -- ── Follow-up nivel 1: +2 minutos ─────────────────────────────────────────
  -- Ventana: notificación original tiene entre 2 y 4 minutos de antigüedad
  FOR v_notif IN
    SELECT DISTINCT ON (n.user_id, (n.data->>'request_id'))
      n.user_id,
      n.data->>'request_id' AS request_id
    FROM public.notifications n
    JOIN public.event_requests er
      ON er.id = (n.data->>'request_id')::UUID
    WHERE n.type = 'booking'
      AND (n.data->>'followup_level') IS NULL          -- notificación original
      AND n.created_at BETWEEN NOW() - INTERVAL '4 minutes'
                           AND NOW() - INTERVAL '2 minutes'
      AND er.status = 'open'
      AND NOT EXISTS (
        SELECT 1 FROM public.notifications n2
        WHERE n2.user_id = n.user_id
          AND n2.data->>'request_id' = n.data->>'request_id'
          AND n2.data->>'followup_level' = '1'
      )
    ORDER BY n.user_id, (n.data->>'request_id'), n.created_at
  LOOP
    INSERT INTO public.notifications (user_id, type, title, body, data)
    VALUES (
      v_notif.user_id,
      'booking',
      '⏰ Tienes una solicitud pendiente',
      'Tienes una solicitud disponible cerca de ti. ¡Revísala antes de que otro grupo la tome!',
      jsonb_build_object(
        'request_id',     v_notif.request_id,
        'screen',         'OpenRequests',
        'followup_level', '1'
      )
    );
    v_count := v_count + 1;
  END LOOP;

  -- ── Follow-up nivel 2: +5 minutos ─────────────────────────────────────────
  -- Ventana: notificación original tiene entre 5 y 8 minutos de antigüedad
  FOR v_notif IN
    SELECT DISTINCT ON (n.user_id, (n.data->>'request_id'))
      n.user_id,
      n.data->>'request_id' AS request_id
    FROM public.notifications n
    JOIN public.event_requests er
      ON er.id = (n.data->>'request_id')::UUID
    WHERE n.type = 'booking'
      AND (n.data->>'followup_level') IS NULL
      AND n.created_at BETWEEN NOW() - INTERVAL '8 minutes'
                           AND NOW() - INTERVAL '5 minutes'
      AND er.status = 'open'
      AND NOT EXISTS (
        SELECT 1 FROM public.notifications n2
        WHERE n2.user_id = n.user_id
          AND n2.data->>'request_id' = n.data->>'request_id'
          AND n2.data->>'followup_level' = '2'
      )
    ORDER BY n.user_id, (n.data->>'request_id'), n.created_at
  LOOP
    INSERT INTO public.notifications (user_id, type, title, body, data)
    VALUES (
      v_notif.user_id,
      'booking',
      '🔥 ¡Esta solicitud podría irse a otro grupo!',
      'Esta solicitud podría asignarse a otro grupo si no respondes pronto. ¡Ábrela ahora y sé el primero!',
      jsonb_build_object(
        'request_id',     v_notif.request_id,
        'screen',         'OpenRequests',
        'followup_level', '2'
      )
    );
    v_count := v_count + 1;
  END LOOP;

  RETURN jsonb_build_object('ok', true, 'sent', v_count);

EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$$;

GRANT EXECUTE ON FUNCTION public.send_express_followups() TO service_role;


-- ────────────────────────────────────────────────────────────────────────────
-- PARTE 2: MODO "ESTOY DISPONIBLE AHORA"
-- ────────────────────────────────────────────────────────────────────────────

-- Columnas en groups
ALTER TABLE public.groups
  ADD COLUMN IF NOT EXISTS available_now       BOOLEAN     DEFAULT FALSE,
  ADD COLUMN IF NOT EXISTS available_now_since TIMESTAMPTZ;

-- Índice para las consultas del wave system
CREATE INDEX IF NOT EXISTS idx_groups_available_now
  ON public.groups(available_now)
  WHERE available_now = TRUE;

-- ── RPC: toggle_available_now() ───────────────────────────────────────────
-- Solo el dueño del grupo puede activar/desactivar su modo disponible.
-- Al activar, registra la hora de inicio.
-- Se desactiva automáticamente a las 4 horas (via cron expire_available_now).

CREATE OR REPLACE FUNCTION public.toggle_available_now(p_group_id UUID)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_owner_id UUID;
  v_current  BOOLEAN;
  v_new_val  BOOLEAN;
BEGIN
  SELECT owner_id, COALESCE(available_now, FALSE)
  INTO   v_owner_id, v_current
  FROM   public.groups
  WHERE  id = p_group_id;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'group_not_found');
  END IF;

  -- Solo el dueño puede activarlo
  IF v_owner_id IS DISTINCT FROM auth.uid() THEN
    RETURN jsonb_build_object('ok', false, 'error', 'unauthorized');
  END IF;

  v_new_val := NOT v_current;

  UPDATE public.groups
  SET available_now       = v_new_val,
      available_now_since = CASE WHEN v_new_val THEN NOW() ELSE NULL END
  WHERE id = p_group_id;

  RETURN jsonb_build_object(
    'ok',            true,
    'available_now', v_new_val,
    'message', CASE WHEN v_new_val
      THEN 'Modo disponible activado. Recibirás solicitudes con prioridad máxima. Se desactiva en 4 horas.'
      ELSE 'Modo disponible desactivado.'
    END
  );

EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$$;

GRANT EXECUTE ON FUNCTION public.toggle_available_now(UUID) TO authenticated;

-- ── Función de expiración automática ─────────────────────────────────────
CREATE OR REPLACE FUNCTION public.expire_available_now()
RETURNS INT
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
AS $$
  WITH expired AS (
    UPDATE public.groups
    SET available_now       = FALSE,
        available_now_since = NULL
    WHERE available_now = TRUE
      AND available_now_since < NOW() - INTERVAL '4 hours'
    RETURNING id
  )
  SELECT COUNT(*)::INT FROM expired;
$$;

GRANT EXECUTE ON FUNCTION public.expire_available_now() TO service_role;


-- ────────────────────────────────────────────────────────────────────────────
-- PARTE 3: EXPANSIÓN AUTOMÁTICA DE RADIO (5 → 10 → 20 km)
-- ────────────────────────────────────────────────────────────────────────────

-- Columna de control en event_requests
ALTER TABLE public.event_requests
  ADD COLUMN IF NOT EXISTS use_radius_expansion BOOLEAN DEFAULT FALSE;


-- ────────────────────────────────────────────────────────────────────────────
-- REEMPLAZO DE _send_wave()
-- Agrega prioridad para grupos con available_now = TRUE.
-- Ajusta el filtro NOT EXISTS para ignorar follow-ups al verificar
-- si un grupo ya fue notificado de una solicitud.
-- ────────────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION _send_wave(
  p_req       RECORD,
  p_offset    INT,
  p_limit     INT,
  p_is_urgent BOOLEAN DEFAULT FALSE
)
RETURNS INT
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_group   RECORD;
  v_count   INT := 0;
  v_body    TEXT;
  v_title   TEXT;
BEGIN
  v_title := CASE WHEN p_is_urgent
    THEN '🔥 ¡Evento URGENTE disponible!'
    ELSE '⚡ Nueva tocada express disponible'
  END;

  v_body := 'Evento de ' || p_req.hours || 'h el ' ||
            TO_CHAR(p_req.event_date, 'DD Mon') || ' en ' ||
            COALESCE(p_req.location_city, 'tu zona') ||
            CASE WHEN p_is_urgent
              THEN ' · ¡Comienza en menos de 6 horas!'
              ELSE '. ¡Sé el primero en aceptar!'
            END;

  FOR v_group IN
    SELECT
      g.id                                    AS group_id,
      g.owner_id,
      g.name,
      COALESCE(g.ranking_score, 0)            AS ranking_score,
      COALESCE(g.available_now, FALSE)        AS available_now,
      gl.lat,
      gl.lng,
      CASE
        WHEN gl.lat IS NOT NULL AND p_req.event_lat IS NOT NULL
          THEN haversine_km(gl.lat, gl.lng, p_req.event_lat, p_req.event_lng)
        ELSE NULL
      END AS dist_km
    FROM public.groups g
    LEFT JOIN public.group_locations gl ON gl.group_id = g.id
    WHERE g.genre     = p_req.genre
      AND g.is_active = TRUE
      AND COALESCE(g.availability, 'available') = 'available'
      AND (
        gl.lat IS NULL
        OR p_req.event_lat IS NULL
        OR haversine_km(gl.lat, gl.lng, p_req.event_lat, p_req.event_lng) <= COALESCE(p_req.radius_km, 50)
      )
      -- No re-notificar grupos que ya recibieron la notificación original
      -- (los follow-ups no cuentan como "ya notificado" para el wave system)
      AND NOT EXISTS (
        SELECT 1 FROM public.notifications n
        WHERE n.user_id = g.owner_id
          AND n.data->>'request_id' = p_req.id::TEXT
          AND (n.data->>'followup_level') IS NULL
      )
    ORDER BY
      -- Grupos "disponibles ahora" siempre al tope
      CASE WHEN COALESCE(g.available_now, FALSE) THEN 1 ELSE 0 END DESC,
      -- Score combinado: 50% ranking, 50% proximidad
      (COALESCE(g.ranking_score, 0) * 0.5) +
      (CASE WHEN gl.lat IS NOT NULL AND p_req.event_lat IS NOT NULL
        THEN (1.0 / (haversine_km(gl.lat, gl.lng, p_req.event_lat, p_req.event_lng) + 1.0)) * 5.0 * 0.5
        ELSE 0
       END) DESC,
      g.created_at ASC
    OFFSET p_offset LIMIT p_limit
  LOOP
    INSERT INTO public.notifications (user_id, type, title, body, data)
    VALUES (
      v_group.owner_id,
      'booking',
      -- Los grupos "disponibles ahora" reciben un título diferenciado
      CASE WHEN v_group.available_now
        THEN CASE WHEN p_is_urgent
               THEN '🟢🔥 Solicitud urgente prioritaria para ti'
               ELSE '🟢⚡ Solicitud prioritaria para ti'
             END
        ELSE v_title
      END,
      v_body,
      jsonb_build_object(
        'request_id', p_req.id,
        'screen',     'OpenRequests',
        'dist_km',    ROUND(v_group.dist_km::NUMERIC, 1),
        'is_urgent',  p_is_urgent
      )
    );
    v_count := v_count + 1;
  END LOOP;

  RETURN v_count;
END;
$$;


-- ────────────────────────────────────────────────────────────────────────────
-- REEMPLAZO DE notify_wave_1()
-- Agrega parámetro p_use_radius_expansion (default FALSE).
-- Si TRUE, inicia con radius_km = 5 y el cron lo expande en cada ola.
-- ────────────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION public.notify_wave_1(
  p_request_id           UUID,
  p_event_lat            DOUBLE PRECISION DEFAULT NULL,
  p_event_lng            DOUBLE PRECISION DEFAULT NULL,
  p_radius_km            DOUBLE PRECISION DEFAULT 50,
  p_use_radius_expansion BOOLEAN          DEFAULT FALSE
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_req            RECORD;
  v_sent           INT;
  v_urgent         BOOLEAN;
  v_initial_radius DOUBLE PRECISION;
BEGIN
  SELECT * INTO v_req FROM public.event_requests WHERE id = p_request_id;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'request_not_found');
  END IF;

  IF v_req.current_wave > 0 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'wave_already_started');
  END IF;

  -- Con expansión de radio empezar en 5 km; si no, usar el parámetro recibido
  v_initial_radius := CASE WHEN p_use_radius_expansion THEN 5.0 ELSE p_radius_km END;

  v_urgent := (
    v_req.event_date::TIMESTAMP +
    COALESCE((v_req.event_time)::INTERVAL, INTERVAL '0')
    - NOW()
  ) < INTERVAL '6 hours';

  UPDATE public.event_requests
  SET event_lat            = p_event_lat,
      event_lng            = p_event_lng,
      radius_km            = v_initial_radius,
      use_radius_expansion = p_use_radius_expansion,
      current_wave         = 1,
      wave1_sent_at        = NOW()
  WHERE id = p_request_id;

  SELECT * INTO v_req FROM public.event_requests WHERE id = p_request_id;

  v_sent := _send_wave(v_req, 0, 5, v_urgent);

  UPDATE public.event_requests
  SET notified_count = notified_count + v_sent
  WHERE id = p_request_id;

  RETURN jsonb_build_object(
    'ok',                    true,
    'wave',                  1,
    'notified',              v_sent,
    'urgent',                v_urgent,
    'initial_radius_km',     v_initial_radius,
    'use_radius_expansion',  p_use_radius_expansion
  );

EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$$;

GRANT EXECUTE ON FUNCTION public.notify_wave_1(UUID, DOUBLE PRECISION, DOUBLE PRECISION, DOUBLE PRECISION, BOOLEAN) TO authenticated;


-- ────────────────────────────────────────────────────────────────────────────
-- REEMPLAZO DE process_notification_waves()
-- Expande el radio cuando use_radius_expansion = TRUE:
--   wave 1 → 5 km  (ya enviada)
--   wave 2 → 10 km (+2 min)
--   wave 3 → 20 km (+5 min más)
-- ────────────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION public.process_notification_waves()
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_req    RECORD;
  v_sent   INT;
  v_urgent BOOLEAN;
  v_total  INT := 0;
BEGIN
  FOR v_req IN
    SELECT * FROM public.event_requests
    WHERE status = 'open'
      AND expires_at > NOW()
      AND (
        (current_wave = 1 AND wave1_sent_at < NOW() - INTERVAL '2 minutes')
        OR
        (current_wave = 2 AND wave2_sent_at < NOW() - INTERVAL '5 minutes')
      )
    FOR UPDATE SKIP LOCKED
  LOOP
    v_urgent := (
      v_req.event_date::TIMESTAMP +
      COALESCE((v_req.event_time)::INTERVAL, INTERVAL '0')
      - NOW()
    ) < INTERVAL '6 hours';

    IF v_req.current_wave = 1 THEN
      -- Expansión de radio: wave 2 → 10 km
      IF COALESCE(v_req.use_radius_expansion, FALSE) THEN
        UPDATE public.event_requests SET radius_km = 10 WHERE id = v_req.id;
        SELECT * INTO v_req FROM public.event_requests WHERE id = v_req.id;
      END IF;

      v_sent := _send_wave(v_req, 5, 10, v_urgent);

      UPDATE public.event_requests
      SET current_wave   = 2,
          wave2_sent_at  = NOW(),
          notified_count = notified_count + v_sent
      WHERE id = v_req.id;

    ELSIF v_req.current_wave = 2 THEN
      -- Expansión de radio: wave 3 → 20 km
      IF COALESCE(v_req.use_radius_expansion, FALSE) THEN
        UPDATE public.event_requests SET radius_km = 20 WHERE id = v_req.id;
        SELECT * INTO v_req FROM public.event_requests WHERE id = v_req.id;
      END IF;

      v_sent := _send_wave(v_req, 15, 1000, v_urgent);

      UPDATE public.event_requests
      SET current_wave   = 3,
          wave3_sent_at  = NOW(),
          notified_count = notified_count + v_sent
      WHERE id = v_req.id;
    END IF;

    v_total := v_total + v_sent;
  END LOOP;

  RETURN jsonb_build_object('ok', true, 'processed', v_total);

EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$$;

GRANT EXECUTE ON FUNCTION public.process_notification_waves() TO service_role;


-- ────────────────────────────────────────────────────────────────────────────
-- CRONS
-- ────────────────────────────────────────────────────────────────────────────

-- Follow-ups cada 2 minutos (se alinea con el cron de process-express-waves)
DO $$
BEGIN
  PERFORM cron.unschedule('express-followups');
EXCEPTION WHEN OTHERS THEN NULL;
END;
$$;

SELECT cron.schedule(
  'express-followups',
  '*/2 * * * *',
  $$ SELECT public.send_express_followups(); $$
);

-- Expirar available_now cada 30 minutos
DO $$
BEGIN
  PERFORM cron.unschedule('expire-available-now');
EXCEPTION WHEN OTHERS THEN NULL;
END;
$$;

SELECT cron.schedule(
  'expire-available-now',
  '*/30 * * * *',
  $$ SELECT public.expire_available_now(); $$
);


-- ════════════════════════════════════════════════════════════════════════════
-- RESUMEN DE CRONS ACTIVOS TRAS EJECUTAR 103
-- ════════════════════════════════════════════════════════════════════════════
-- dispatch-push-notifications  → * * * * *      → send-push-notification (Edge Fn)
-- process-express-waves        → */2 * * * *    → process_notification_waves()
-- express-followups            → */2 * * * *    → send_express_followups()
-- auto-cancel-bookings         → */5 * * * *    → auto_cancel_expired_bookings()
-- expire-available-now         → */30 * * * *   → expire_available_now()
-- event-reminders              → 0 * * * *      → send_event_reminders()
-- engagement-nearby-requests   → */30 * * * *   → notify_groups_nearby_requests()
-- engagement-inactive-groups   → 0 18 * * *     → nudge_inactive_groups()
-- engagement-clients-available → 0 18 * * 1,3,5 → notify_clients_available_groups()
-- engagement-weekend-clients   → 0 23 * * 5     → weekend_client_nudge()
-- engagement-weekend-clients-sat → 0 16 * * 6  → weekend_client_nudge()
-- engagement-weekend-groups    → 0 22 * * 5     → weekend_group_nudge()
-- engagement-weekend-groups-sat → 0 15 * * 6   → weekend_group_nudge()
-- ════════════════════════════════════════════════════════════════════════════

-- ════════════════════════════════════════════════════════════════════════════
-- USO DESDE EL FRONTEND
-- ════════════════════════════════════════════════════════════════════════════
-- 1. Activar modo disponible (desde GroupDashboard):
--      supabase.rpc('toggle_available_now', { p_group_id: groupId })
--      → { ok: true, available_now: true, message: '...' }
--
-- 2. Crear solicitud express CON expansión de radio:
--      supabase.rpc('notify_wave_1', {
--        p_request_id:           requestId,
--        p_event_lat:            lat,
--        p_event_lng:            lng,
--        p_use_radius_expansion: true   // activa 5→10→20 km automático
--      })
--
-- 3. Crear solicitud express SIN expansión (comportamiento anterior):
--      supabase.rpc('notify_wave_1', {
--        p_request_id: requestId,
--        p_event_lat:  lat,
--        p_event_lng:  lng,
--        p_radius_km:  50           // radio fijo 50 km (default)
--      })
-- ════════════════════════════════════════════════════════════════════════════

SELECT '103_growth_improvements: follow-ups + available_now + radio_expansion ✅' AS status;
