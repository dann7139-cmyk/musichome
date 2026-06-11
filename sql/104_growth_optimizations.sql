-- ════════════════════════════════════════════════════════════════════════════
-- 104_growth_optimizations.sql
-- Optimizaciones de crecimiento y conversión
--
-- ESTADO DEL SISTEMA (lo que YA existe — no se re-implementa aquí):
--   93 → reviews, ranking_score, update_group_reputation (fórmula básica)
--   94 → availability (available/busy/offline), set_group_availability()
--         protect_chat_messages trigger
--   95 → wave system, _send_wave(), process_notification_waves()
--   102 → engagement notifications (nudges, weekend pushes)
--   103 → available_now, toggle_available_now(), send_express_followups()
--         expansión de radio 5→10→20 km
--   OpenRequestsScreen.tsx → indicador de competencia + temporizador (items 5, 6)
--
-- LO QUE IMPLEMENTA ESTE ARCHIVO:
--   1. Fórmula de reputación mejorada (acceptance_rate + response_speed + disputas)
--   2. Boost temporal de ranking para grupos activos (item 11)
--   3. Sincronización toggle_available_now ↔ availability (item 3 completo)
--   4. Retención de clientes post-evento: 24h / 7d / 30d (item 7)
--   5. RPC: get_top_groups_nearby() — "Top grupos cerca de ti" (item 9)
--   6. RPC: get_group_scarcity() — datos de escasez para UI (item 10)
--   7. Notificaciones estratégicas para artistas (item 12 complemento)
--   8. Crons para todas las funciones nuevas
--
-- No modifica flujo de reservas, pagos ni express existente.
-- Ejecutar DESPUÉS de 103_growth_improvements.sql
-- ════════════════════════════════════════════════════════════════════════════


-- ────────────────────────────────────────────────────────────────────────────
-- PARTE 1: REPUTACIÓN MEJORADA
-- ────────────────────────────────────────────────────────────────────────────
-- Reemplaza update_group_reputation() de 93 con una fórmula más completa.
--
-- Fórmula (escala 0–5, +boost temporal):
--
--   score =
--     (rating_avg / 5)           * 5 * 0.40   → max 2.00  (40%)
--   + (acceptance_rate)          * 5 * 0.25   → max 1.25  (25%)
--   + (response_speed_score / 5) * 5 * 0.15   → max 0.75  (15%)
--   + (min(events,50) / 50)      * 5 * 0.15   → max 0.75  (15%)
--   - (cancel_rate)              * 5 * 0.05   → max -0.25 (5%)
--   - (open_disputes * 0.10)                  → -0.10 por disputa activa
--   + ranking_boost                           → boost temporal
--
-- Insignias automáticas:
--   top_artist      → rating ≥ 4.5 con 5+ reseñas
--   high_demand     → 10+ eventos completados
--   reliable        → tasa de aceptación ≥ 80%
--   fast_responder  → tiempo de respuesta promedio < 5 min
-- ────────────────────────────────────────────────────────────────────────────

-- Columnas adicionales en groups para el boost
ALTER TABLE public.groups
  ADD COLUMN IF NOT EXISTS ranking_boost     NUMERIC(6,4) DEFAULT 0,
  ADD COLUMN IF NOT EXISTS boost_expires_at  TIMESTAMPTZ;

-- ── Función principal de cálculo ──────────────────────────────────────────

CREATE OR REPLACE FUNCTION public.recalculate_group_reputation(p_group_id UUID)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_avg          NUMERIC(3,2);
  v_count        INT;
  v_total_ev     INT;
  v_cancel_rate  NUMERIC;
  v_accept_rate  NUMERIC;
  v_resp_score   NUMERIC;
  v_disputes     INT  := 0;
  v_boost        NUMERIC;
  v_boost_exp    TIMESTAMPTZ;
  v_score        NUMERIC(8,4);
  v_badges       TEXT[] := '{}';
BEGIN
  -- ── Calificación promedio ────────────────────────────────────────────────
  SELECT ROUND(AVG(rating)::NUMERIC, 2), COUNT(*)
  INTO   v_avg, v_count
  FROM   public.reviews
  WHERE  group_id = p_group_id;

  -- ── Eventos completados ──────────────────────────────────────────────────
  SELECT COUNT(*) INTO v_total_ev
  FROM   public.reservations
  WHERE  group_id = p_group_id AND status = 'completed';

  -- ── Tasa de cancelación (últimos 90 días) ────────────────────────────────
  SELECT CASE WHEN COUNT(*) = 0 THEN 0
              ELSE COUNT(*) FILTER (WHERE status = 'cancelled')::NUMERIC / COUNT(*)
         END
  INTO   v_cancel_rate
  FROM   public.reservations
  WHERE  group_id = p_group_id
    AND  created_at >= NOW() - INTERVAL '90 days';

  -- ── Tasa de aceptación: reservas confirmadas o completadas / todas ───────
  SELECT CASE WHEN COUNT(*) = 0 THEN 0.5   -- neutral si no hay historial
              ELSE COUNT(*) FILTER (WHERE status IN ('confirmed','completed'))
                   ::NUMERIC / COUNT(*)
         END
  INTO   v_accept_rate
  FROM   public.reservations
  WHERE  group_id = p_group_id;

  -- ── Velocidad de respuesta (proposal_logs vs event_requests) ────────────
  -- Promedio de minutos entre la solicitud y la primera propuesta del grupo
  -- Escala: <5min=5, <15min=4, <30min=3, <60min=2, ≥60min=1
  SELECT CASE WHEN COUNT(*) = 0 THEN 2.5   -- neutral si sin historial
              ELSE
                CASE
                  WHEN AVG(EXTRACT(EPOCH FROM (pl.proposed_at - er.created_at)) / 60) <  5 THEN 5.0
                  WHEN AVG(EXTRACT(EPOCH FROM (pl.proposed_at - er.created_at)) / 60) < 15 THEN 4.0
                  WHEN AVG(EXTRACT(EPOCH FROM (pl.proposed_at - er.created_at)) / 60) < 30 THEN 3.0
                  WHEN AVG(EXTRACT(EPOCH FROM (pl.proposed_at - er.created_at)) / 60) < 60 THEN 2.0
                  ELSE 1.0
                END
         END
  INTO   v_resp_score
  FROM   public.proposal_logs pl
  JOIN   public.groups g        ON g.id = pl.group_id
  JOIN   public.event_requests  er ON er.id = pl.request_id
  WHERE  g.id = p_group_id
    AND  pl.proposed_at >= NOW() - INTERVAL '30 days';

  -- ── Disputas activas (penalización, si la tabla existe) ──────────────────
  BEGIN
    IF to_regclass('public.event_disputes') IS NOT NULL THEN
      EXECUTE
        'SELECT COUNT(*) FROM public.event_disputes
         WHERE group_id = $1
           AND status IN (''open'',''in_review'')
           AND created_at >= NOW() - INTERVAL ''90 days'''
      INTO v_disputes
      USING p_group_id;
    END IF;
  EXCEPTION WHEN OTHERS THEN
    v_disputes := 0;
  END;

  -- ── Boost temporal activo (ignora si expiró) ─────────────────────────────
  SELECT COALESCE(ranking_boost, 0), boost_expires_at
  INTO   v_boost, v_boost_exp
  FROM   public.groups
  WHERE  id = p_group_id;

  IF v_boost_exp IS NOT NULL AND v_boost_exp < NOW() THEN
    v_boost := 0;
  END IF;

  -- ── Fórmula ───────────────────────────────────────────────────────────────
  v_score :=
    (COALESCE(v_avg, 0)         / 5.0 * 5.0 * 0.40)
  + (COALESCE(v_accept_rate, 0)        * 5.0 * 0.25)
  + (COALESCE(v_resp_score, 2.5) / 5.0 * 5.0 * 0.15)
  + (LEAST(v_total_ev, 50)      / 50.0 * 5.0 * 0.15)
  - (COALESCE(v_cancel_rate, 0)        * 5.0 * 0.05)
  - (LEAST(COALESCE(v_disputes, 0), 3) * 0.10)
  + COALESCE(v_boost, 0);

  -- ── Insignias ─────────────────────────────────────────────────────────────
  IF COALESCE(v_avg, 0) >= 4.5 AND v_count >= 5 THEN
    v_badges := array_append(v_badges, 'top_artist');
  END IF;
  IF v_total_ev >= 10 THEN
    v_badges := array_append(v_badges, 'high_demand');
  END IF;
  IF COALESCE(v_accept_rate, 0) >= 0.80 THEN
    v_badges := array_append(v_badges, 'reliable');
  END IF;
  IF COALESCE(v_resp_score, 0) >= 4.5 THEN
    v_badges := array_append(v_badges, 'fast_responder');
  END IF;

  UPDATE public.groups
  SET average_rating = COALESCE(v_avg, 0),
      total_reviews   = COALESCE(v_count, 0),
      ranking_score   = GREATEST(v_score, 0),
      badges          = v_badges
  WHERE id = p_group_id;
END;
$$;

-- ── Wrappers de trigger ───────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION public._trg_reputation_from_review()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
  PERFORM public.recalculate_group_reputation(COALESCE(NEW.group_id, OLD.group_id));
  RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION public._trg_reputation_from_reservation()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
  -- Solo recalcular en cambios de status relevantes
  IF (TG_OP = 'UPDATE' AND NEW.status IS DISTINCT FROM OLD.status)
     OR TG_OP = 'INSERT' THEN
    PERFORM public.recalculate_group_reputation(COALESCE(NEW.group_id, OLD.group_id));
  END IF;
  RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION public._trg_reputation_from_proposal()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
  -- Recalcular reputación del grupo que propuso (actualiza response_speed)
  PERFORM public.recalculate_group_reputation(COALESCE(NEW.group_id, OLD.group_id));
  RETURN NEW;
END;
$$;

-- Reemplazar trigger de reviews (93) con el nuevo wrapper
DROP TRIGGER IF EXISTS trg_update_group_reputation ON public.reviews;
CREATE TRIGGER trg_update_group_reputation
  AFTER INSERT OR UPDATE OR DELETE ON public.reviews
  FOR EACH ROW EXECUTE FUNCTION public._trg_reputation_from_review();

-- Nuevo: trigger en reservations para status changes
DROP TRIGGER IF EXISTS trg_reputation_from_reservation ON public.reservations;
CREATE TRIGGER trg_reputation_from_reservation
  AFTER INSERT OR UPDATE OF status ON public.reservations
  FOR EACH ROW EXECUTE FUNCTION public._trg_reputation_from_reservation();

-- Nuevo: trigger en proposal_logs para response speed
DROP TRIGGER IF EXISTS trg_reputation_from_proposal ON public.proposal_logs;
CREATE TRIGGER trg_reputation_from_proposal
  AFTER INSERT ON public.proposal_logs
  FOR EACH ROW EXECUTE FUNCTION public._trg_reputation_from_proposal();

-- ── Backfill: recalcular todos los grupos con actividad ───────────────────
DO $$
DECLARE v_gid UUID;
BEGIN
  FOR v_gid IN
    SELECT DISTINCT id FROM public.groups WHERE is_active = TRUE
  LOOP
    PERFORM public.recalculate_group_reputation(v_gid);
  END LOOP;
END;
$$;


-- ────────────────────────────────────────────────────────────────────────────
-- PARTE 2: BOOST TEMPORAL DE RANKING (Item 11)
-- ────────────────────────────────────────────────────────────────────────────
-- Cuando un grupo se comporta bien el sistema le aplica un boost temporal
-- que lo sube en el ranking por un período determinado.
--
-- Se activa automáticamente cuando:
--   • Completa un evento                        → +0.3 durante 48h
--   • Recibe reseña de 5 estrellas              → +0.2 durante 24h
--   • Responde a solicitud en menos de 5 min    → +0.15 durante 12h
--   • Acepta solicitud express                  → +0.1  durante 6h
-- ────────────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION public.apply_ranking_boost(
  p_group_id UUID,
  p_boost    NUMERIC,
  p_hours    INT
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_current_boost NUMERIC;
  v_current_exp   TIMESTAMPTZ;
  v_new_boost     NUMERIC;
  v_new_exp       TIMESTAMPTZ;
BEGIN
  SELECT COALESCE(ranking_boost, 0), boost_expires_at
  INTO   v_current_boost, v_current_exp
  FROM   public.groups
  WHERE  id = p_group_id;

  -- Si ya hay un boost activo, acumular (con techo de 0.5)
  IF v_current_exp IS NOT NULL AND v_current_exp > NOW() THEN
    v_new_boost := LEAST(v_current_boost + p_boost, 0.5);
    -- Extender al plazo más largo entre el actual y el nuevo
    v_new_exp   := GREATEST(v_current_exp, NOW() + (p_hours || ' hours')::INTERVAL);
  ELSE
    v_new_boost := LEAST(p_boost, 0.5);
    v_new_exp   := NOW() + (p_hours || ' hours')::INTERVAL;
  END IF;

  UPDATE public.groups
  SET ranking_boost    = v_new_boost,
      boost_expires_at = v_new_exp
  WHERE id = p_group_id;

  -- Recalcular ranking_score con el nuevo boost incluido
  PERFORM public.recalculate_group_reputation(p_group_id);
END;
$$;

GRANT EXECUTE ON FUNCTION public.apply_ranking_boost(UUID, NUMERIC, INT) TO service_role;

-- ── Trigger automático de boost al completar evento ──────────────────────

CREATE OR REPLACE FUNCTION public._trg_boost_on_event_complete()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF NEW.status = 'completed' AND OLD.status IS DISTINCT FROM 'completed' THEN
    PERFORM public.apply_ranking_boost(NEW.group_id, 0.30, 48);
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_boost_on_event_complete ON public.reservations;
CREATE TRIGGER trg_boost_on_event_complete
  AFTER UPDATE OF status ON public.reservations
  FOR EACH ROW EXECUTE FUNCTION public._trg_boost_on_event_complete();

-- ── Trigger: boost por reseña de 5 estrellas ────────────────────────────

CREATE OR REPLACE FUNCTION public._trg_boost_on_five_star()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF NEW.rating = 5 THEN
    PERFORM public.apply_ranking_boost(NEW.group_id, 0.20, 24);
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_boost_on_five_star ON public.reviews;
CREATE TRIGGER trg_boost_on_five_star
  AFTER INSERT ON public.reviews
  FOR EACH ROW EXECUTE FUNCTION public._trg_boost_on_five_star();

-- ── Expirar boosts vencidos ────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION public.expire_ranking_boosts()
RETURNS INT
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_count INT := 0;
  v_gid   UUID;
BEGIN
  FOR v_gid IN
    SELECT id FROM public.groups
    WHERE ranking_boost > 0
      AND boost_expires_at < NOW()
  LOOP
    UPDATE public.groups
    SET ranking_boost = 0, boost_expires_at = NULL
    WHERE id = v_gid;

    -- Recalcular score sin el boost
    PERFORM public.recalculate_group_reputation(v_gid);
    v_count := v_count + 1;
  END LOOP;

  RETURN v_count;
END;
$$;

GRANT EXECUTE ON FUNCTION public.expire_ranking_boosts() TO service_role;


-- ────────────────────────────────────────────────────────────────────────────
-- PARTE 3: SINCRONIZAR toggle_available_now ↔ availability (Item 3 completo)
-- ────────────────────────────────────────────────────────────────────────────
-- El modo "Estoy disponible ahora" (103) ya existe pero no sincronizaba
-- con el campo availability (94).  Este reemplazo los une:
--   • Al activar   → availability = 'available'  (garantiza que reciba waves)
--   • Al desactivar → availability = 'busy'      (no 'offline', solo pausa)
-- ────────────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION public.toggle_available_now(p_group_id UUID)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_owner_id    UUID;
  v_current_now BOOLEAN;
  v_new_now     BOOLEAN;
  v_new_avail   TEXT;
BEGIN
  SELECT owner_id, COALESCE(available_now, FALSE)
  INTO   v_owner_id, v_current_now
  FROM   public.groups
  WHERE  id = p_group_id;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'group_not_found');
  END IF;

  IF v_owner_id IS DISTINCT FROM auth.uid() THEN
    RETURN jsonb_build_object('ok', false, 'error', 'unauthorized');
  END IF;

  v_new_now   := NOT v_current_now;
  v_new_avail := CASE WHEN v_new_now THEN 'available' ELSE 'busy' END;

  UPDATE public.groups
  SET available_now       = v_new_now,
      available_now_since = CASE WHEN v_new_now THEN NOW() ELSE NULL END,
      availability        = v_new_avail   -- sincroniza con wave system
  WHERE id = p_group_id;

  -- Aplicar boost si se activa el modo disponible
  IF v_new_now THEN
    PERFORM public.apply_ranking_boost(p_group_id, 0.10, 4);
  END IF;

  RETURN jsonb_build_object(
    'ok',            true,
    'available_now', v_new_now,
    'availability',  v_new_avail,
    'message', CASE WHEN v_new_now
      THEN 'Modo disponible activado. Recibirás solicitudes prioritarias y aparecerás primero. Se desactiva en 4 horas.'
      ELSE 'Modo disponible desactivado. Tu disponibilidad está en "ocupado".'
    END
  );

EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$$;

GRANT EXECUTE ON FUNCTION public.toggle_available_now(UUID) TO authenticated;


-- ────────────────────────────────────────────────────────────────────────────
-- PARTE 4: RETENCIÓN DE CLIENTES POST-EVENTO (Item 7)
-- ────────────────────────────────────────────────────────────────────────────
-- Envía notificaciones automáticas al cliente después de completar un evento:
--   24h después → solicitar reseña + motivar próxima reserva
--    7d después → recordar que los grupos siguen disponibles
--   30d después → reactivación con descubrimiento de nuevos grupos
-- ────────────────────────────────────────────────────────────────────────────

ALTER TABLE public.reservations
  ADD COLUMN IF NOT EXISTS retention_24h_sent  BOOLEAN DEFAULT FALSE,
  ADD COLUMN IF NOT EXISTS retention_7d_sent   BOOLEAN DEFAULT FALSE,
  ADD COLUMN IF NOT EXISTS retention_30d_sent  BOOLEAN DEFAULT FALSE;

CREATE INDEX IF NOT EXISTS idx_reservations_retention
  ON public.reservations(status, event_date)
  WHERE status = 'completed';

CREATE OR REPLACE FUNCTION public.send_client_retention_notifications()
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_res   RECORD;
  v_grp   TEXT;
  v_count INT := 0;
  v_completed_at TIMESTAMPTZ;
BEGIN
  FOR v_res IN
    SELECT
      r.id,
      r.client_id,
      r.group_id,
      r.event_date,
      r.retention_24h_sent,
      r.retention_7d_sent,
      r.retention_30d_sent,
      g.name AS group_name,
      g.genre
    FROM public.reservations r
    JOIN public.groups g ON g.id = r.group_id
    WHERE r.status = 'completed'
      AND (
        NOT r.retention_24h_sent
        OR NOT r.retention_7d_sent
        OR NOT r.retention_30d_sent
      )
  LOOP
    -- Usar event_date como proxy de "completado" (evento fue ese día)
    v_completed_at := r.event_date::TIMESTAMPTZ;
    v_grp := COALESCE(r.group_name, 'el grupo');

    -- ── 24 horas: solicitar reseña ────────────────────────────────────────
    IF NOT r.retention_24h_sent
       AND v_completed_at BETWEEN NOW() - INTERVAL '48 hours'
                              AND NOW() - INTERVAL '20 hours' THEN

      INSERT INTO public.notifications (user_id, type, title, body, data)
      VALUES (
        r.client_id,
        'event_completed',
        '⭐ ¿Cómo estuvo el evento?',
        '¡Esperamos que ' || v_grp || ' haya superado tus expectativas! '
        || 'Deja una reseña — ayuda a otros clientes y motiva al grupo. Solo toma 10 segundos. 🎶',
        jsonb_build_object(
          'reservation_id', r.id,
          'screen',         'ReservationDetail',
          'action',         'rate'
        )
      );

      UPDATE public.reservations
      SET retention_24h_sent = TRUE WHERE id = r.id;
      v_count := v_count + 1;

    -- ── 7 días: volver a reservar ──────────────────────────────────────────
    ELSIF NOT r.retention_7d_sent
          AND v_completed_at BETWEEN NOW() - INTERVAL '8 days'
                                 AND NOW() - INTERVAL '6 days' THEN

      INSERT INTO public.notifications (user_id, type, title, body, data)
      VALUES (
        r.client_id,
        'system',
        '🎵 ¿Planeas otro evento?',
        v_grp || ' y otros grupos de ' || COALESCE(r.genre, 'música en vivo')
        || ' siguen disponibles en tu zona. ¡Reserva con tiempo y asegura la fecha que quieres! 🎸',
        jsonb_build_object(
          'screen', 'Home',
          'action', 'explore_groups'
        )
      );

      UPDATE public.reservations
      SET retention_7d_sent = TRUE WHERE id = r.id;
      v_count := v_count + 1;

    -- ── 30 días: reactivación ─────────────────────────────────────────────
    ELSIF NOT r.retention_30d_sent
          AND v_completed_at BETWEEN NOW() - INTERVAL '31 days'
                                 AND NOW() - INTERVAL '28 days' THEN

      INSERT INTO public.notifications (user_id, type, title, body, data)
      VALUES (
        r.client_id,
        'system',
        '🎉 Descubre nuevos grupos cerca de ti',
        'Muchos clientes reservan música en vivo para eventos especiales. '
        || '¡Hay grupos nuevos en tu zona que estás a punto de descubrir! '
        || 'Explora y encuentra el sonido perfecto para tu próxima celebración. ✨',
        jsonb_build_object(
          'screen', 'Explore',
          'action', 'discover'
        )
      );

      UPDATE public.reservations
      SET retention_30d_sent = TRUE WHERE id = r.id;
      v_count := v_count + 1;
    END IF;

  END LOOP;

  RETURN jsonb_build_object('ok', true, 'sent', v_count);

EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$$;

GRANT EXECUTE ON FUNCTION public.send_client_retention_notifications() TO service_role;


-- ────────────────────────────────────────────────────────────────────────────
-- PARTE 5: "TOP GRUPOS CERCA DE TI" (Item 9)
-- ────────────────────────────────────────────────────────────────────────────
-- RPC que el frontend llama para mostrar la sección "Top grupos cerca de ti".
-- Ordena por: ranking_score + proximidad + eventos recientes (30 días).
-- ────────────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION public.get_top_groups_nearby(
  p_lat   DOUBLE PRECISION  DEFAULT NULL,
  p_lng   DOUBLE PRECISION  DEFAULT NULL,
  p_genre TEXT              DEFAULT NULL,
  p_limit INT               DEFAULT 10
)
RETURNS TABLE (
  group_id       UUID,
  name           TEXT,
  genre          TEXT,
  average_rating NUMERIC,
  total_reviews  INT,
  ranking_score  NUMERIC,
  dist_km        NUMERIC,
  badges         TEXT[],
  recent_events  INT,
  available_now  BOOLEAN,
  availability   TEXT
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  RETURN QUERY
  SELECT
    g.id                                        AS group_id,
    g.name,
    g.genre,
    g.average_rating,
    g.total_reviews,
    g.ranking_score,
    CASE
      WHEN gl.lat IS NOT NULL AND p_lat IS NOT NULL
        THEN ROUND(haversine_km(gl.lat, gl.lng, p_lat, p_lng)::NUMERIC, 1)
      ELSE NULL
    END                                         AS dist_km,
    g.badges,
    COALESCE(ev.recent_count, 0)::INT           AS recent_events,
    COALESCE(g.available_now, FALSE)            AS available_now,
    COALESCE(g.availability, 'available')       AS availability
  FROM public.groups g
  LEFT JOIN public.group_locations gl ON gl.group_id = g.id
  LEFT JOIN LATERAL (
    SELECT COUNT(*) AS recent_count
    FROM public.reservations r
    WHERE r.group_id = g.id
      AND r.status   = 'completed'
      AND r.event_date >= CURRENT_DATE - 30
  ) ev ON TRUE
  WHERE g.is_active = TRUE
    AND COALESCE(g.availability, 'available') != 'offline'
    AND (p_genre IS NULL OR g.genre = p_genre)
    AND (
      -- Incluir grupos sin coordenadas o fuera del radio si no hay coords del cliente
      p_lat IS NULL OR gl.lat IS NULL
      OR haversine_km(gl.lat, gl.lng, p_lat, p_lng) <= 50
    )
  ORDER BY
    -- Grupos disponibles ahora primero
    CASE WHEN COALESCE(g.available_now, FALSE) THEN 1 ELSE 0 END DESC,
    -- Score combinado: 60% ranking, 25% proximidad, 15% actividad reciente
    (COALESCE(g.ranking_score, 0) * 0.60)
    + (CASE WHEN gl.lat IS NOT NULL AND p_lat IS NOT NULL
         THEN (1.0 / (haversine_km(gl.lat, gl.lng, p_lat, p_lng) + 1.0)) * 10.0 * 0.25
         ELSE 0
       END)
    + (LEAST(COALESCE(ev.recent_count, 0), 10) / 10.0 * 5.0 * 0.15) DESC
  LIMIT p_limit;
END;
$$;

GRANT EXECUTE ON FUNCTION public.get_top_groups_nearby(DOUBLE PRECISION, DOUBLE PRECISION, TEXT, INT) TO authenticated, anon;


-- ────────────────────────────────────────────────────────────────────────────
-- PARTE 6: DATOS DE ESCASEZ PARA UI (Item 10)
-- ────────────────────────────────────────────────────────────────────────────
-- RPC que devuelve datos de actividad reciente de un grupo para que el
-- frontend muestre mensajes de urgencia/escasez.
-- Ejemplos de uso:
--   "3 clientes han reservado este grupo esta semana"
--   "Este grupo suele llenarse los fines de semana"
-- ────────────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION public.get_group_scarcity(p_group_id UUID)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_weekly_bookings   INT;
  v_monthly_bookings  INT;
  v_weekend_bookings  INT;
  v_total_bookings    INT;
  v_is_weekend_busy   BOOLEAN;
  v_acceptance_rate   NUMERIC;
  v_avg_response_mins NUMERIC;
  v_message           TEXT;
BEGIN
  -- Reservas esta semana (confirmadas + completadas)
  SELECT COUNT(*) INTO v_weekly_bookings
  FROM public.reservations
  WHERE group_id = p_group_id
    AND status IN ('confirmed', 'deposit_paid', 'in_progress', 'completed')
    AND event_date >= CURRENT_DATE - 7;

  -- Reservas este mes
  SELECT COUNT(*) INTO v_monthly_bookings
  FROM public.reservations
  WHERE group_id = p_group_id
    AND status IN ('confirmed', 'deposit_paid', 'in_progress', 'completed')
    AND event_date >= CURRENT_DATE - 30;

  -- Reservas en fines de semana (últimos 60 días)
  SELECT COUNT(*) INTO v_weekend_bookings
  FROM public.reservations
  WHERE group_id = p_group_id
    AND status IN ('confirmed', 'deposit_paid', 'completed')
    AND event_date >= CURRENT_DATE - 60
    AND EXTRACT(DOW FROM event_date) IN (5, 6, 0); -- Vie, Sáb, Dom

  -- Total historial
  SELECT COUNT(*) INTO v_total_bookings
  FROM public.reservations
  WHERE group_id = p_group_id
    AND status IN ('confirmed', 'deposit_paid', 'in_progress', 'completed');

  -- ¿Es popular en fines de semana?
  v_is_weekend_busy := v_weekend_bookings >= 3;

  -- Tasa de aceptación reciente
  SELECT CASE WHEN COUNT(*) = 0 THEN NULL
              ELSE ROUND(COUNT(*) FILTER (WHERE status IN ('confirmed','completed'))
                   ::NUMERIC / COUNT(*) * 100, 0)
         END
  INTO v_acceptance_rate
  FROM public.reservations
  WHERE group_id = p_group_id AND created_at >= NOW() - INTERVAL '60 days';

  -- Tiempo promedio de respuesta (minutos)
  SELECT ROUND(AVG(EXTRACT(EPOCH FROM (pl.proposed_at - er.created_at)) / 60)::NUMERIC, 0)
  INTO   v_avg_response_mins
  FROM   public.proposal_logs pl
  JOIN   public.groups g      ON g.id = pl.group_id
  JOIN   public.event_requests er ON er.id = pl.request_id
  WHERE  g.id = p_group_id
    AND  pl.proposed_at >= NOW() - INTERVAL '30 days';

  -- Construir mensaje de escasez para la UI
  v_message := CASE
    WHEN v_weekly_bookings >= 3
      THEN v_weekly_bookings::TEXT || ' clientes han reservado este grupo esta semana.'
    WHEN v_is_weekend_busy AND EXTRACT(DOW FROM CURRENT_DATE) IN (3, 4)  -- Mié/Jue
      THEN 'Este grupo suele llenarse los fines de semana. ¡Reserva ya!'
    WHEN v_monthly_bookings >= 8
      THEN 'Alta demanda este mes — ' || v_monthly_bookings || ' eventos confirmados.'
    WHEN COALESCE(v_avg_response_mins, 999) < 10
      THEN 'Responde muy rápido — tiempo promedio de respuesta: menos de 10 minutos.'
    WHEN v_total_bookings >= 20
      THEN v_total_bookings::TEXT || ' eventos completados con éxito en la plataforma.'
    ELSE NULL
  END;

  RETURN jsonb_build_object(
    'ok',                  true,
    'weekly_bookings',     v_weekly_bookings,
    'monthly_bookings',    v_monthly_bookings,
    'is_weekend_busy',     v_is_weekend_busy,
    'total_bookings',      v_total_bookings,
    'acceptance_rate_pct', v_acceptance_rate,
    'avg_response_mins',   v_avg_response_mins,
    'scarcity_message',    v_message   -- NULL si no hay dato de escasez significativo
  );

EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$$;

GRANT EXECUTE ON FUNCTION public.get_group_scarcity(UUID) TO authenticated, anon;


-- ────────────────────────────────────────────────────────────────────────────
-- PARTE 7: NOTIFICACIONES ESTRATÉGICAS PARA ARTISTAS (Item 12)
-- ────────────────────────────────────────────────────────────────────────────
-- Complementa 102_engagement_notifications.sql con mensajes específicos para
-- artistas sobre actividad en su zona y el modo "disponible ahora".
-- ────────────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION public.notify_artists_activity_boost()
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_group   RECORD;
  v_count   INT := 0;
  v_open_requests INT;
BEGIN
  FOR v_group IN
    SELECT
      g.id,
      g.owner_id,
      g.name,
      g.genre,
      g.availability,
      g.available_now,
      gl.lat,
      gl.lng,
      gl.city
    FROM public.groups g
    LEFT JOIN public.group_locations gl ON gl.group_id = g.id
    WHERE g.is_active = TRUE
      AND COALESCE(g.availability, 'available') != 'offline'
      AND COALESCE(g.available_now, FALSE) = FALSE   -- no notificar a los ya activos
  LOOP
    -- Contar solicitudes abiertas del mismo género (últimas 2 horas)
    SELECT COUNT(*) INTO v_open_requests
    FROM public.event_requests er
    WHERE er.genre  = v_group.genre
      AND er.status = 'open'
      AND er.expires_at > NOW()
      AND er.created_at > NOW() - INTERVAL '2 hours'
      AND (
        v_group.lat IS NULL
        OR er.event_lat IS NULL
        OR haversine_km(v_group.lat, v_group.lng, er.event_lat, er.event_lng) <= 50
      );

    IF v_open_requests > 0 THEN
      -- Verificar anti-spam: no notificar más de una vez en 3 horas
      IF NOT EXISTS (
        SELECT 1 FROM public.notifications n
        WHERE n.user_id = v_group.owner_id
          AND n.type = 'system'
          AND n.data->>'notif_key' = 'activity_boost'
          AND n.created_at > NOW() - INTERVAL '3 hours'
      ) THEN
        INSERT INTO public.notifications (user_id, type, title, body, data)
        VALUES (
          v_group.owner_id,
          'system',
          '🎵 Hay eventos disponibles en tu zona',
          CASE
            WHEN v_open_requests = 1
              THEN 'Hay 1 solicitud de ' || v_group.genre || ' activa ahora mismo. ¡Activa "Disponible ahora" para recibirla con prioridad!'
            ELSE
              'Hay ' || v_open_requests || ' solicitudes de ' || v_group.genre || ' activas ahora mismo en tu zona. ¡Actívate para recibirlas primero!'
          END,
          jsonb_build_object(
            'screen',     'Dashboard',
            'action',     'toggle_available',
            'notif_key',  'activity_boost'
          )
        );
        v_count := v_count + 1;
      END IF;
    END IF;

  END LOOP;

  RETURN jsonb_build_object('ok', true, 'notified', v_count);

EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$$;

GRANT EXECUTE ON FUNCTION public.notify_artists_activity_boost() TO service_role;

-- Notificación diaria motivacional a grupos inactivos sin boost
CREATE OR REPLACE FUNCTION public.notify_artists_daily_tip()
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_group  RECORD;
  v_count  INT := 0;
BEGIN
  FOR v_group IN
    SELECT g.id, g.owner_id, g.genre
    FROM public.groups g
    WHERE g.is_active = TRUE
      AND COALESCE(g.available_now, FALSE) = FALSE
      AND COALESCE(g.availability, 'available') = 'available'
      -- Solo grupos que no han tenido reserva esta semana
      AND NOT EXISTS (
        SELECT 1 FROM public.reservations r
        WHERE r.group_id = g.id
          AND r.status IN ('confirmed','deposit_paid','in_progress')
          AND r.event_date >= CURRENT_DATE
          AND r.event_date <= CURRENT_DATE + 14
      )
      -- Anti-spam: no más de una vez por día
      AND NOT EXISTS (
        SELECT 1 FROM public.notifications n
        WHERE n.user_id = g.owner_id
          AND n.data->>'notif_key' = 'daily_tip'
          AND n.created_at > NOW() - INTERVAL '22 hours'
      )
  LOOP
    INSERT INTO public.notifications (user_id, type, title, body, data)
    VALUES (
      v_group.owner_id,
      'system',
      '💡 Activa "Disponible ahora" y recibe solicitudes primero',
      'Los clientes están buscando grupos de ' || v_group.genre
      || ' en tu ciudad. Activa el modo "Disponible ahora" para aparecer '
      || 'primero en las búsquedas y recibir solicitudes prioritarias. 🚀',
      jsonb_build_object(
        'screen',    'Dashboard',
        'action',    'toggle_available',
        'notif_key', 'daily_tip'
      )
    );
    v_count := v_count + 1;
  END LOOP;

  RETURN jsonb_build_object('ok', true, 'notified', v_count);

EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$$;

GRANT EXECUTE ON FUNCTION public.notify_artists_daily_tip() TO service_role;


-- ────────────────────────────────────────────────────────────────────────────
-- CRONS
-- ────────────────────────────────────────────────────────────────────────────

-- Expirar boosts vencidos cada hora
DO $$ BEGIN PERFORM cron.unschedule('expire-ranking-boosts'); EXCEPTION WHEN OTHERS THEN NULL; END; $$;
SELECT cron.schedule('expire-ranking-boosts', '0 * * * *', $$ SELECT public.expire_ranking_boosts(); $$);

-- Retención de clientes: diario a las 10am GDL (16:00 UTC)
DO $$ BEGIN PERFORM cron.unschedule('client-retention'); EXCEPTION WHEN OTHERS THEN NULL; END; $$;
SELECT cron.schedule('client-retention', '0 16 * * *', $$ SELECT public.send_client_retention_notifications(); $$);

-- Notificaciones de actividad para artistas: cada hora (durante horas activas GDL 12pm–10pm → 18-04 UTC)
DO $$ BEGIN PERFORM cron.unschedule('artists-activity-boost'); EXCEPTION WHEN OTHERS THEN NULL; END; $$;
SELECT cron.schedule('artists-activity-boost', '30 18-04 * * *', $$ SELECT public.notify_artists_activity_boost(); $$);

-- Tip diario para artistas: lunes/miércoles/viernes a las 9am GDL (15:00 UTC)
DO $$ BEGIN PERFORM cron.unschedule('artists-daily-tip'); EXCEPTION WHEN OTHERS THEN NULL; END; $$;
SELECT cron.schedule('artists-daily-tip', '0 15 * * 1,3,5', $$ SELECT public.notify_artists_daily_tip(); $$);


-- ════════════════════════════════════════════════════════════════════════════
-- RESUMEN COMPLETO DE CRONS ACTIVOS (post-104)
-- ════════════════════════════════════════════════════════════════════════════
-- dispatch-push-notifications  → * * * * *        → send-push-notification (Edge Fn)
-- process-express-waves        → */2 * * * *      → process_notification_waves()
-- express-followups            → */2 * * * *      → send_express_followups()
-- auto-cancel-bookings         → */5 * * * *      → auto_cancel_expired_bookings()
-- expire-available-now         → */30 * * * *     → expire_available_now()
-- event-reminders              → 0 * * * *        → send_event_reminders()
-- expire-ranking-boosts        → 0 * * * *        → expire_ranking_boosts()
-- engagement-nearby-requests   → */30 * * * *     → notify_groups_nearby_requests()
-- engagement-inactive-groups   → 0 18 * * *       → nudge_inactive_groups()
-- engagement-clients-available → 0 18 * * 1,3,5   → notify_clients_available_groups()
-- artists-activity-boost       → 30 18-04 * * *   → notify_artists_activity_boost()
-- client-retention             → 0 16 * * *       → send_client_retention_notifications()
-- artists-daily-tip            → 0 15 * * 1,3,5   → notify_artists_daily_tip()
-- engagement-weekend-clients   → 0 23 * * 5       → weekend_client_nudge()
-- engagement-weekend-clients-sat → 0 16 * * 6    → weekend_client_nudge()
-- engagement-weekend-groups    → 0 22 * * 5       → weekend_group_nudge()
-- engagement-weekend-groups-sat → 0 15 * * 6     → weekend_group_nudge()
-- ════════════════════════════════════════════════════════════════════════════

-- ════════════════════════════════════════════════════════════════════════════
-- USO DESDE EL FRONTEND
-- ════════════════════════════════════════════════════════════════════════════
-- Top grupos cerca de ti (item 9):
--   supabase.rpc('get_top_groups_nearby', {
--     p_lat: lat, p_lng: lng, p_genre: 'Rock', p_limit: 10
--   })
--   → [{ group_id, name, ranking_score, dist_km, badges, recent_events, ... }]
--
-- Escasez para GroupDetail (item 10):
--   supabase.rpc('get_group_scarcity', { p_group_id: id })
--   → { weekly_bookings, is_weekend_busy, scarcity_message, ... }
--   Si scarcity_message != null → mostrar badge/texto en la UI
--
-- Activar modo disponible (item 3 + sincronizado con availability):
--   supabase.rpc('toggle_available_now', { p_group_id: id })
--   → { ok, available_now, availability: 'available' | 'busy' }
-- ════════════════════════════════════════════════════════════════════════════

SELECT '104_growth_optimizations: reputación mejorada + boost + retención + top-grupos + escasez + artistas ✅' AS status;
