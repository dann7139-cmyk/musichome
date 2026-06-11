-- ════════════════════════════════════════════════════════════════════════════
-- 107_reliability_system.sql
-- Sistema de reputación, confiabilidad y penalizaciones (estilo Uber/Airbnb)
--
-- ESTADO DEL SISTEMA (ya implementado — no se re-implementa aquí):
--   93/104 → ranking_score, badges básicos, recalculate_group_reputation()
--   104    → ranking_boost / apply_ranking_boost() (boosts positivos)
--
-- LO QUE IMPLEMENTA ESTE ARCHIVO:
--   1. reliability_score   — puntaje de confianza 0–100, visible para clientes
--      calculate_group_reliability()  — fórmula de confiabilidad
--      Triggers: reviews · reservations · proposal_logs
--   2. cancelled_by        — quién canceló la reserva
--      group_cancel_reservation()     — RPC seguro para que el grupo cancele
--      reliability_penalty            — penalización temporal por cancelación
--   3. Protección al cliente          — notificación + grupos alternativos
--      cuando el grupo cancela cerca de la fecha del evento
--   4. Etiquetas de confianza extendidas
--      trusted_group / high_acceptance / quick_response / top_ciudad
--   5. Advertencias automáticas push a grupos con mal desempeño
--   6. review_group_health() — monitoreo periódico + ajuste de scores
--
-- No modifica flujo de reservas ni pagos.
-- Ejecutar DESPUÉS de 106_airbnb_conversions.sql
-- ════════════════════════════════════════════════════════════════════════════


-- ────────────────────────────────────────────────────────────────────────────
-- PARTE 1: reliability_score (0–100)
-- ────────────────────────────────────────────────────────────────────────────
-- Campo separado de ranking_score (0–5).
-- ranking_score  → ordena grupos en búsquedas y waves (calidad general)
-- reliability_score → confianza visible para el cliente (etiqueta "Confiable")
--
-- Fórmula (0–100):
--   acceptance_rate        × 30   → 0–30
--   response_speed_norm    × 20   → 0–20   (normalizado 1-5 → 0-1)
--   completed_events_norm  × 30   → 0–30   (min(events,100)/100)
--   rating_avg_norm        × 20   → 0–20   (avg/5)
--   cancellation_penalty   × 25   → 0–25   (subtracted; tasa de cancelación)
--
-- Columnas adicionales en groups
-- ────────────────────────────────────────────────────────────────────────────

ALTER TABLE public.groups
  ADD COLUMN IF NOT EXISTS reliability_score   NUMERIC(5,2)  DEFAULT 0,
  ADD COLUMN IF NOT EXISTS reliability_penalty NUMERIC(5,2)  DEFAULT 0,
  ADD COLUMN IF NOT EXISTS penalty_expires_at  TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS warnings_count      SMALLINT      DEFAULT 0;

ALTER TABLE public.reservations
  ADD COLUMN IF NOT EXISTS cancelled_by TEXT
    CHECK (cancelled_by IN ('group', 'client', 'admin', 'system'));

-- ── calculate_group_reliability() ────────────────────────────────────────

CREATE OR REPLACE FUNCTION public.calculate_group_reliability(p_group_id UUID)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_accept_rate   NUMERIC;
  v_resp_score    NUMERIC;   -- 1–5
  v_total_ev      INT;
  v_cancel_rate   NUMERIC;
  v_avg_rating    NUMERIC;
  v_penalty       NUMERIC;
  v_penalty_exp   TIMESTAMPTZ;
  v_score         NUMERIC(5,2);
  v_badges        TEXT[];
  v_current_badges TEXT[];
  v_new_badges    TEXT[];
  v_top_in_city   BOOLEAN;
BEGIN
  -- ── Tasa de aceptación: confirmed+completed / all ────────────────────────
  SELECT CASE WHEN COUNT(*) = 0 THEN 0.5
              ELSE COUNT(*) FILTER (WHERE status IN ('confirmed','deposit_paid','in_progress','completed'))
                   ::NUMERIC / COUNT(*)
         END
  INTO v_accept_rate
  FROM public.reservations
  WHERE group_id = p_group_id;

  -- ── Velocidad de respuesta (1–5) — misma lógica que en 104 ───────────────
  SELECT CASE WHEN COUNT(*) = 0 THEN 2.5
              ELSE
                CASE
                  WHEN AVG(EXTRACT(EPOCH FROM (pl.proposed_at - er.created_at)) / 60) <  5  THEN 5.0
                  WHEN AVG(EXTRACT(EPOCH FROM (pl.proposed_at - er.created_at)) / 60) < 15  THEN 4.0
                  WHEN AVG(EXTRACT(EPOCH FROM (pl.proposed_at - er.created_at)) / 60) < 30  THEN 3.0
                  WHEN AVG(EXTRACT(EPOCH FROM (pl.proposed_at - er.created_at)) / 60) < 60  THEN 2.0
                  ELSE 1.0
                END
         END
  INTO v_resp_score
  FROM public.proposal_logs pl
  JOIN public.groups g ON g.id = pl.group_id
  JOIN public.event_requests er ON er.id = pl.request_id
  WHERE g.id = p_group_id
    AND pl.proposed_at >= NOW() - INTERVAL '60 days';

  -- ── Eventos completados (normalizado 0–1) ────────────────────────────────
  SELECT COUNT(*) INTO v_total_ev
  FROM public.reservations
  WHERE group_id = p_group_id AND status = 'completed';

  -- ── Tasa de cancelación (últimos 90 días) ────────────────────────────────
  SELECT CASE WHEN COUNT(*) = 0 THEN 0
              ELSE COUNT(*) FILTER (WHERE status = 'cancelled' AND cancelled_by = 'group')
                   ::NUMERIC / COUNT(*)
         END
  INTO v_cancel_rate
  FROM public.reservations
  WHERE group_id = p_group_id
    AND created_at >= NOW() - INTERVAL '90 days';

  -- ── Calificación promedio ────────────────────────────────────────────────
  SELECT COALESCE(AVG(rating), 0) INTO v_avg_rating
  FROM public.reviews
  WHERE group_id = p_group_id;

  -- ── Penalización activa ──────────────────────────────────────────────────
  SELECT COALESCE(reliability_penalty, 0), penalty_expires_at
  INTO v_penalty, v_penalty_exp
  FROM public.groups WHERE id = p_group_id;

  IF v_penalty_exp IS NOT NULL AND v_penalty_exp < NOW() THEN
    -- Penalización vencida: limpiar
    UPDATE public.groups
    SET reliability_penalty = 0, penalty_expires_at = NULL
    WHERE id = p_group_id;
    v_penalty := 0;
  END IF;

  -- ── Fórmula principal ────────────────────────────────────────────────────
  v_score :=
    (COALESCE(v_accept_rate, 0)              * 30.0)
  + ((COALESCE(v_resp_score, 2.5) - 1) / 4.0 * 20.0)   -- normaliza 1-5 → 0-1
  + (LEAST(v_total_ev, 100) / 100.0          * 30.0)
  + (COALESCE(v_avg_rating, 0) / 5.0         * 20.0)
  - (COALESCE(v_cancel_rate, 0)              * 25.0)
  - COALESCE(v_penalty, 0);

  v_score := GREATEST(LEAST(v_score, 100), 0);  -- clamp 0–100

  -- ── Etiquetas de confianza ───────────────────────────────────────────────
  SELECT COALESCE(badges, '{}') INTO v_current_badges FROM public.groups WHERE id = p_group_id;

  -- Preservar insignias de calidad (de 104); solo gestionar las de confianza
  v_new_badges := ARRAY(
    SELECT u FROM unnest(v_current_badges) AS u
    WHERE u NOT IN ('trusted_group','high_acceptance','quick_response','top_ciudad')
  );

  IF v_score >= 85 THEN
    v_new_badges := array_append(v_new_badges, 'trusted_group');
  END IF;

  IF COALESCE(v_accept_rate, 0) >= 0.85 THEN
    v_new_badges := array_append(v_new_badges, 'high_acceptance');
  END IF;

  IF COALESCE(v_resp_score, 0) >= 4.5 THEN
    v_new_badges := array_append(v_new_badges, 'quick_response');
  END IF;

  -- "Top en tu ciudad": top 3 de la ciudad por ranking_score
  SELECT (
    SELECT COUNT(*) FROM public.groups g2
    WHERE g2.city = g.city
      AND g2.is_active = TRUE
      AND g2.ranking_score > g.ranking_score
  ) < 3
  INTO v_top_in_city
  FROM public.groups g
  WHERE g.id = p_group_id;

  IF v_top_in_city AND v_score >= 70 THEN
    v_new_badges := array_append(v_new_badges, 'top_ciudad');
  END IF;

  UPDATE public.groups
  SET reliability_score = v_score,
      badges            = v_new_badges
  WHERE id = p_group_id;
END;
$$;

-- ── Trigger wrappers ──────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION public._trg_reliability_from_review()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
  PERFORM public.calculate_group_reliability(COALESCE(NEW.group_id, OLD.group_id));
  RETURN NEW;
END; $$;

CREATE OR REPLACE FUNCTION public._trg_reliability_from_reservation()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
  IF (TG_OP = 'UPDATE' AND NEW.status IS DISTINCT FROM OLD.status) OR TG_OP = 'INSERT' THEN
    PERFORM public.calculate_group_reliability(COALESCE(NEW.group_id, OLD.group_id));
  END IF;
  RETURN NEW;
END; $$;

CREATE OR REPLACE FUNCTION public._trg_reliability_from_proposal()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
  PERFORM public.calculate_group_reliability(COALESCE(NEW.group_id, OLD.group_id));
  RETURN NEW;
END; $$;

DROP TRIGGER IF EXISTS trg_reliability_from_review       ON public.reviews;
DROP TRIGGER IF EXISTS trg_reliability_from_reservation  ON public.reservations;
DROP TRIGGER IF EXISTS trg_reliability_from_proposal     ON public.proposal_logs;

CREATE TRIGGER trg_reliability_from_review
  AFTER INSERT OR UPDATE OR DELETE ON public.reviews
  FOR EACH ROW EXECUTE FUNCTION public._trg_reliability_from_review();

CREATE TRIGGER trg_reliability_from_reservation
  AFTER INSERT OR UPDATE OF status ON public.reservations
  FOR EACH ROW EXECUTE FUNCTION public._trg_reliability_from_reservation();

CREATE TRIGGER trg_reliability_from_proposal
  AFTER INSERT ON public.proposal_logs
  FOR EACH ROW EXECUTE FUNCTION public._trg_reliability_from_proposal();

-- Backfill inicial
DO $$
DECLARE v_gid UUID;
BEGIN
  FOR v_gid IN SELECT DISTINCT id FROM public.groups WHERE is_active = TRUE LOOP
    PERFORM public.calculate_group_reliability(v_gid);
  END LOOP;
END; $$;


-- ────────────────────────────────────────────────────────────────────────────
-- PARTE 2: PENALIZACIONES POR CANCELACIÓN DEL GRUPO
-- ────────────────────────────────────────────────────────────────────────────
-- RPC para que el grupo cancele una reserva confirmada.
-- Registra cancelled_by = 'group' y activa la penalización automática.
--
-- Penalización según proximidad al evento:
--   ≤ 48 h → -20 pts durante 14 días  (grave)
--   ≤  7 d → -10 pts durante  7 días  (moderada)
--   >  7 d → - 5 pts durante  3 días  (leve)
-- ────────────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION public.group_cancel_reservation(p_reservation_id UUID)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_res      RECORD;
  v_group    RECORD;
  v_hours    NUMERIC;
  v_penalty  NUMERIC;
  v_days     INT;
BEGIN
  -- Verificar que la reserva pertenece a un grupo del usuario autenticado
  SELECT r.*, g.id AS gid
  INTO   v_res
  FROM   public.reservations r
  JOIN   public.groups g ON g.id = r.group_id AND g.owner_id = auth.uid()
  WHERE  r.id = p_reservation_id
    AND  r.status IN ('confirmed', 'deposit_paid', 'accepted');

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'reservation_not_found_or_unauthorized');
  END IF;

  v_hours := EXTRACT(EPOCH FROM (v_res.event_date::TIMESTAMPTZ - NOW())) / 3600;

  -- Determinar penalización según proximidad
  IF v_hours <= 48 THEN
    v_penalty := 20; v_days := 14;
  ELSIF v_hours <= 168 THEN   -- 7 días
    v_penalty := 10; v_days :=  7;
  ELSE
    v_penalty :=  5; v_days :=  3;
  END IF;

  -- Cancelar reserva
  UPDATE public.reservations
  SET status       = 'cancelled',
      cancelled_by = 'group'
  WHERE id = p_reservation_id;

  -- Aplicar penalización al reliability_score y ranking_score temporalmente
  UPDATE public.groups
  SET reliability_penalty = LEAST(COALESCE(reliability_penalty, 0) + v_penalty, 40),
      penalty_expires_at  = GREATEST(
                              COALESCE(penalty_expires_at, NOW()),
                              NOW() + (v_days || ' days')::INTERVAL
                            ),
      warnings_count      = COALESCE(warnings_count, 0) + 1
  WHERE id = v_res.gid;

  -- Reducir ranking_boost también (visibilidad)
  PERFORM public.apply_ranking_boost(v_res.gid, -0.30, v_days * 24);

  -- Recalcular scores
  PERFORM public.calculate_group_reliability(v_res.gid);
  PERFORM public.recalculate_group_reputation(v_res.gid);

  RETURN jsonb_build_object(
    'ok',          true,
    'penalty_pts', v_penalty,
    'penalty_days', v_days,
    'hours_to_event', ROUND(v_hours::NUMERIC, 1)
  );

EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$$;

GRANT EXECUTE ON FUNCTION public.group_cancel_reservation(UUID) TO authenticated;


-- ────────────────────────────────────────────────────────────────────────────
-- PARTE 3: PROTECCIÓN AL CLIENTE CUANDO EL GRUPO CANCELA
-- ────────────────────────────────────────────────────────────────────────────
-- Trigger AFTER UPDATE en reservations.
-- Cuando cancelled_by = 'group', el cliente recibe:
--   • Notificación push inmediata con explicación
--   • Lista de hasta 5 grupos disponibles similares
--   • Prioridad de cliente (priority_client_until en profiles)
-- ────────────────────────────────────────────────────────────────────────────

ALTER TABLE public.profiles
  ADD COLUMN IF NOT EXISTS priority_client_until TIMESTAMPTZ;

CREATE OR REPLACE FUNCTION public._trg_protect_client_on_group_cancel()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_group_name  TEXT;
  v_alt_groups  TEXT;
  v_alts        RECORD;
  v_alt_list    TEXT[] := '{}';
BEGIN
  -- Solo actuar cuando el grupo cancela una reserva confirmada
  IF NEW.cancelled_by != 'group'
     OR NEW.status != 'cancelled'
     OR OLD.status NOT IN ('confirmed','deposit_paid','accepted') THEN
    RETURN NEW;
  END IF;

  SELECT name INTO v_group_name FROM public.groups WHERE id = NEW.group_id;

  -- Notificar al cliente inmediatamente
  INSERT INTO public.notifications (user_id, type, title, body, data)
  VALUES (
    NEW.client_id,
    'booking_cancelled',
    '⚠️ Tu grupo canceló el evento',
    COALESCE(v_group_name, 'El grupo') ||
    ' canceló tu reserva del ' || TO_CHAR(NEW.event_date, 'DD/MM/YYYY') ||
    '. Entendemos que esto es inconveniente. Te ayudamos a encontrar otro grupo disponible.',
    jsonb_build_object(
      'reservation_id', NEW.id,
      'screen',         'Home',
      'action',         'find_replacement'
    )
  );

  -- Dar prioridad al cliente por 72 horas
  UPDATE public.profiles
  SET priority_client_until = NOW() + INTERVAL '72 hours'
  WHERE id = NEW.client_id;

  -- Buscar hasta 5 grupos alternativos disponibles del mismo género
  FOR v_alts IN
    SELECT g.name
    FROM public.groups g
    WHERE g.genre       = (SELECT genre FROM public.groups WHERE id = NEW.group_id)
      AND g.id         != NEW.group_id
      AND g.is_active   = TRUE
      AND COALESCE(g.availability, 'available') = 'available'
    ORDER BY g.ranking_score DESC
    LIMIT 5
  LOOP
    v_alt_list := array_append(v_alt_list, v_alts.name);
  END LOOP;

  -- Enviar segunda notificación con grupos alternativos si hay disponibles
  IF array_length(v_alt_list, 1) > 0 THEN
    INSERT INTO public.notifications (user_id, type, title, body, data)
    VALUES (
      NEW.client_id,
      'system',
      '🎵 Grupos disponibles para tu fecha',
      'Hay grupos disponibles que pueden cubrir tu evento del ' ||
      TO_CHAR(NEW.event_date, 'DD/MM') || ': ' ||
      array_to_string(v_alt_list, ', ') ||
      '. ¡Crea una nueva solicitud y te conectamos de inmediato!',
      jsonb_build_object(
        'screen',         'Home',
        'action',         'create_express',
        'alternatives',   to_jsonb(v_alt_list)
      )
    );
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_protect_client_on_group_cancel ON public.reservations;
CREATE TRIGGER trg_protect_client_on_group_cancel
  AFTER UPDATE OF status ON public.reservations
  FOR EACH ROW
  WHEN (NEW.status = 'cancelled' AND NEW.cancelled_by = 'group')
  EXECUTE FUNCTION public._trg_protect_client_on_group_cancel();


-- ────────────────────────────────────────────────────────────────────────────
-- PARTE 4: ADVERTENCIAS AUTOMÁTICAS A GRUPOS CON MAL DESEMPEÑO
-- ────────────────────────────────────────────────────────────────────────────
-- Envía notificaciones push educativas cuando un grupo baja el umbral.
-- Anti-spam: máx 1 advertencia por tipo en 7 días.
-- ────────────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION public.send_group_health_warnings()
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_group       RECORD;
  v_sent        INT := 0;
  v_accept_rate NUMERIC;
  v_cancel_rate NUMERIC;
  v_resp_mins   NUMERIC;
  v_key         TEXT;
BEGIN
  FOR v_group IN
    SELECT g.id, g.owner_id, g.name, g.reliability_score, g.warnings_count
    FROM public.groups g
    WHERE g.is_active = TRUE
      AND COALESCE(g.availability, 'available') != 'offline'
  LOOP

    -- ── Tasa de aceptación baja (< 40%) ─────────────────────────────────
    SELECT CASE WHEN COUNT(*) = 0 THEN NULL
                ELSE COUNT(*) FILTER (WHERE status IN ('confirmed','deposit_paid','completed'))
                     ::NUMERIC / COUNT(*) * 100
           END
    INTO v_accept_rate
    FROM public.reservations
    WHERE group_id = v_group.id
      AND created_at >= NOW() - INTERVAL '30 days';

    IF COALESCE(v_accept_rate, 100) < 40 THEN
      v_key := 'warn_low_acceptance';
      IF NOT EXISTS (
        SELECT 1 FROM public.notifications n
        WHERE n.user_id = v_group.owner_id
          AND n.data->>'warn_key' = v_key
          AND n.created_at > NOW() - INTERVAL '7 days'
      ) THEN
        INSERT INTO public.notifications (user_id, type, title, body, data)
        VALUES (
          v_group.owner_id, 'system',
          '📉 Tu tasa de aceptación es baja',
          'Solo has aceptado el ' || ROUND(COALESCE(v_accept_rate, 0)) ||
          '% de las solicitudes este mes. Aceptar más solicitudes aumenta tu visibilidad y ranking en la plataforma.',
          jsonb_build_object('screen', 'Dashboard', 'warn_key', v_key)
        );
        v_sent := v_sent + 1;
      END IF;
    END IF;

    -- ── Tiempo de respuesta lento (> 60 min promedio) ────────────────────
    SELECT ROUND(AVG(EXTRACT(EPOCH FROM (pl.proposed_at - er.created_at)) / 60)::NUMERIC, 0)
    INTO v_resp_mins
    FROM public.proposal_logs pl
    JOIN public.groups g2 ON g2.id = pl.group_id
    JOIN public.event_requests er ON er.id = pl.request_id
    WHERE g2.id = v_group.id
      AND pl.proposed_at >= NOW() - INTERVAL '30 days';

    IF COALESCE(v_resp_mins, 0) > 60 THEN
      v_key := 'warn_slow_response';
      IF NOT EXISTS (
        SELECT 1 FROM public.notifications n
        WHERE n.user_id = v_group.owner_id
          AND n.data->>'warn_key' = v_key
          AND n.created_at > NOW() - INTERVAL '7 days'
      ) THEN
        INSERT INTO public.notifications (user_id, type, title, body, data)
        VALUES (
          v_group.owner_id, 'system',
          '⏱ Tu tiempo de respuesta es alto',
          'Tardas en promedio ' || ROUND(COALESCE(v_resp_mins, 0)) ||
          ' minutos en responder solicitudes. Los clientes prefieren grupos que responden en menos de 15 minutos. ¡Activa las notificaciones push!',
          jsonb_build_object('screen', 'Dashboard', 'warn_key', v_key)
        );
        v_sent := v_sent + 1;
      END IF;
    END IF;

    -- ── Cancelaciones frecuentes (> 2 en 60 días) ────────────────────────
    SELECT COUNT(*) INTO v_cancel_rate
    FROM public.reservations
    WHERE group_id   = v_group.id
      AND status     = 'cancelled'
      AND cancelled_by = 'group'
      AND created_at >= NOW() - INTERVAL '60 days';

    IF v_cancel_rate >= 2 THEN
      v_key := 'warn_cancellations';
      IF NOT EXISTS (
        SELECT 1 FROM public.notifications n
        WHERE n.user_id = v_group.owner_id
          AND n.data->>'warn_key' = v_key
          AND n.created_at > NOW() - INTERVAL '7 days'
      ) THEN
        INSERT INTO public.notifications (user_id, type, title, body, data)
        VALUES (
          v_group.owner_id, 'system',
          '⚠️ Las cancelaciones afectan tu visibilidad',
          'Has cancelado ' || v_cancel_rate ||
          ' eventos en los últimos 60 días. Las cancelaciones reducen tu ranking y confiabilidad. Los clientes prefieren grupos con historial limpio.',
          jsonb_build_object('screen', 'Dashboard', 'warn_key', v_key,
                             'action', 'improve_reliability')
        );
        v_sent := v_sent + 1;
      END IF;
    END IF;

    -- ── reliability_score muy bajo (< 40) ────────────────────────────────
    IF COALESCE(v_group.reliability_score, 0) < 40 THEN
      v_key := 'warn_low_reliability';
      IF NOT EXISTS (
        SELECT 1 FROM public.notifications n
        WHERE n.user_id = v_group.owner_id
          AND n.data->>'warn_key' = v_key
          AND n.created_at > NOW() - INTERVAL '7 days'
      ) THEN
        INSERT INTO public.notifications (user_id, type, title, body, data)
        VALUES (
          v_group.owner_id, 'system',
          '🔴 Tu puntaje de confiabilidad es bajo',
          'Tu puntaje de confiabilidad está en ' || ROUND(v_group.reliability_score) ||
          '/100. Esto afecta cuántas solicitudes recibes. Acepta más eventos, responde rápido y evita cancelaciones para mejorar.',
          jsonb_build_object('screen', 'Dashboard', 'warn_key', v_key)
        );
        v_sent := v_sent + 1;
      END IF;
    END IF;

  END LOOP;

  RETURN jsonb_build_object('ok', true, 'warnings_sent', v_sent);

EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$$;

GRANT EXECUTE ON FUNCTION public.send_group_health_warnings() TO service_role;


-- ────────────────────────────────────────────────────────────────────────────
-- PARTE 5: MONITOREO PERIÓDICO — review_group_health()
-- ────────────────────────────────────────────────────────────────────────────
-- Recalcula reliability_score y ranking_score para todos los grupos activos,
-- expira penalizaciones vencidas y ajusta badges de confianza.
-- Se ejecuta cada 6 horas.
-- ────────────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION public.review_group_health()
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_gid      UUID;
  v_updated  INT := 0;
  v_expired  INT := 0;
BEGIN
  -- Expirar penalizaciones vencidas
  FOR v_gid IN
    SELECT id FROM public.groups
    WHERE penalty_expires_at IS NOT NULL AND penalty_expires_at < NOW()
  LOOP
    UPDATE public.groups
    SET reliability_penalty = 0,
        penalty_expires_at  = NULL
    WHERE id = v_gid;
    v_expired := v_expired + 1;
  END LOOP;

  -- Recalcular reliability y ranking para todos los grupos activos
  FOR v_gid IN
    SELECT id FROM public.groups WHERE is_active = TRUE
  LOOP
    PERFORM public.calculate_group_reliability(v_gid);
    PERFORM public.recalculate_group_reputation(v_gid);
    v_updated := v_updated + 1;
  END LOOP;

  RETURN jsonb_build_object(
    'ok',              true,
    'groups_updated',  v_updated,
    'penalties_expired', v_expired
  );

EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$$;

GRANT EXECUTE ON FUNCTION public.review_group_health() TO service_role;


-- ────────────────────────────────────────────────────────────────────────────
-- RPC PÚBLICA: get_group_trust_profile()
-- ────────────────────────────────────────────────────────────────────────────
-- Devuelve el perfil de confianza completo de un grupo para mostrarlo
-- al cliente en GroupDetail: reliability_score, badges de confianza y métricas.

CREATE OR REPLACE FUNCTION public.get_group_trust_profile(p_group_id UUID)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_g     RECORD;
  v_label TEXT;
  v_trust_badges JSONB[] := ARRAY[]::JSONB[];
BEGIN
  SELECT
    g.reliability_score,
    g.ranking_score,
    g.average_rating,
    g.total_reviews,
    g.badges,
    g.availability,
    g.available_now
  INTO v_g
  FROM public.groups g
  WHERE g.id = p_group_id;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_found');
  END IF;

  -- Traducir badges a etiquetas visibles para el cliente
  IF 'trusted_group'    = ANY(v_g.badges) THEN
    v_trust_badges := array_append(v_trust_badges,
      jsonb_build_object('key', 'trusted_group',   'label', 'Grupo confiable',           'icon', 'shield-check'));
  END IF;
  IF 'high_acceptance'  = ANY(v_g.badges) THEN
    v_trust_badges := array_append(v_trust_badges,
      jsonb_build_object('key', 'high_acceptance', 'label', 'Alta tasa de aceptación',   'icon', 'thumbs-up'));
  END IF;
  IF 'quick_response'   = ANY(v_g.badges) OR 'fast_responder' = ANY(v_g.badges) THEN
    v_trust_badges := array_append(v_trust_badges,
      jsonb_build_object('key', 'quick_response',  'label', 'Respuesta rápida',          'icon', 'zap'));
  END IF;
  IF 'top_ciudad'       = ANY(v_g.badges) THEN
    v_trust_badges := array_append(v_trust_badges,
      jsonb_build_object('key', 'top_ciudad',      'label', 'Top grupo en tu ciudad',    'icon', 'award'));
  END IF;
  IF 'top_artist'       = ANY(v_g.badges) THEN
    v_trust_badges := array_append(v_trust_badges,
      jsonb_build_object('key', 'top_artist',      'label', 'Artista destacado',         'icon', 'star'));
  END IF;
  IF 'high_demand'      = ANY(v_g.badges) THEN
    v_trust_badges := array_append(v_trust_badges,
      jsonb_build_object('key', 'high_demand',     'label', 'Alta demanda',              'icon', 'trending-up'));
  END IF;
  IF 'reliable'         = ANY(v_g.badges) THEN
    v_trust_badges := array_append(v_trust_badges,
      jsonb_build_object('key', 'reliable',        'label', 'Alta tasa de aceptación',   'icon', 'check-circle'));
  END IF;

  -- Nivel de confiabilidad resumido
  v_label := CASE
    WHEN COALESCE(v_g.reliability_score, 0) >= 85 THEN 'Muy confiable'
    WHEN COALESCE(v_g.reliability_score, 0) >= 70 THEN 'Confiable'
    WHEN COALESCE(v_g.reliability_score, 0) >= 50 THEN 'En desarrollo'
    ELSE 'Nuevo en la plataforma'
  END;

  RETURN jsonb_build_object(
    'ok',               true,
    'reliability_score', ROUND(COALESCE(v_g.reliability_score, 0)::NUMERIC, 0),
    'reliability_label', v_label,
    'ranking_score',     ROUND(COALESCE(v_g.ranking_score, 0)::NUMERIC, 2),
    'average_rating',    COALESCE(v_g.average_rating, 0),
    'total_reviews',     COALESCE(v_g.total_reviews, 0),
    'trust_badges',      to_jsonb(v_trust_badges),
    'availability',      COALESCE(v_g.availability, 'available'),
    'available_now',     COALESCE(v_g.available_now, FALSE)
  );

EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$$;

GRANT EXECUTE ON FUNCTION public.get_group_trust_profile(UUID) TO authenticated, anon;


-- ────────────────────────────────────────────────────────────────────────────
-- CRONS
-- ────────────────────────────────────────────────────────────────────────────

-- Monitoreo de salud cada 6 horas
DO $$ BEGIN PERFORM cron.unschedule('review-group-health'); EXCEPTION WHEN OTHERS THEN NULL; END; $$;
SELECT cron.schedule('review-group-health', '0 */6 * * *', $$ SELECT public.review_group_health(); $$);

-- Advertencias a grupos: diario a las 8am GDL (14:00 UTC)
DO $$ BEGIN PERFORM cron.unschedule('group-health-warnings'); EXCEPTION WHEN OTHERS THEN NULL; END; $$;
SELECT cron.schedule('group-health-warnings', '0 14 * * *', $$ SELECT public.send_group_health_warnings(); $$);


-- ════════════════════════════════════════════════════════════════════════════
-- USO DESDE EL FRONTEND
-- ════════════════════════════════════════════════════════════════════════════
--
-- 1. Perfil del grupo (GroupDetail): mostrar badges y reliability_score
--    supabase.rpc('get_group_trust_profile', { p_group_id: id })
--    → { reliability_score: 87, reliability_label: 'Muy confiable',
--        trust_badges: [{ key, label, icon }, ...] }
--
-- 2. El grupo cancela una reserva (GroupDashboard / ReservationDetail):
--    supabase.rpc('group_cancel_reservation', { p_reservation_id: id })
--    → { ok, penalty_pts, penalty_days, hours_to_event }
--    El cliente recibe notificación push automáticamente.
--
-- 3. Sección "¿Por qué confiar en este grupo?":
--    Mostrar reliability_score como barra de progreso (0–100)
--    + badges debajo del nombre del grupo en GroupDetail
-- ════════════════════════════════════════════════════════════════════════════

SELECT '107_reliability_system: reliability_score + penalizaciones + protección + advertencias ✅' AS status;
