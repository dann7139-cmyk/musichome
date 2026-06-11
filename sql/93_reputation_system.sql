-- ═══════════════════════════════════════════════════════════════════════════════
-- 93_reputation_system.sql
-- Faltante 14: Sistema de reputación y ranking de artistas
-- ─ reviews table
-- ─ Columnas average_rating / total_reviews / ranking_score / badges en groups
-- ─ Trigger de recálculo automático
-- ─ RPCs: submit_review · get_group_reviews · check_review_eligibility
-- Ejecutar DESPUÉS de 92.
-- ═══════════════════════════════════════════════════════════════════════════════

-- ────────────────────────────────────────────────────────────────────────────
-- 1. TABLA REVIEWS
-- ────────────────────────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS reviews (
  id             UUID     PRIMARY KEY DEFAULT gen_random_uuid(),
  reservation_id UUID     UNIQUE REFERENCES reservations(id) ON DELETE CASCADE,
  client_id      UUID     REFERENCES profiles(id) ON DELETE SET NULL,
  group_id       UUID     NOT NULL REFERENCES groups(id) ON DELETE CASCADE,
  rating         SMALLINT NOT NULL CHECK (rating BETWEEN 1 AND 5),
  comment        TEXT,
  created_at     TIMESTAMPTZ DEFAULT now()
);

ALTER TABLE reviews ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "rev_public_read"  ON reviews;
DROP POLICY IF EXISTS "rev_client_insert" ON reviews;
DROP POLICY IF EXISTS "rev_admin_all"    ON reviews;

-- Clientes ven todas las reseñas (confianza pública)
CREATE POLICY "rev_public_read" ON reviews
  FOR SELECT TO authenticated USING (true);

-- Solo el cliente dueño de la reserva puede insertar su reseña
CREATE POLICY "rev_client_insert" ON reviews
  FOR INSERT TO authenticated
  WITH CHECK (auth.uid() = client_id);

-- Admin puede todo
CREATE POLICY "rev_admin_all" ON reviews
  FOR ALL TO authenticated
  USING (EXISTS (SELECT 1 FROM profiles WHERE id = auth.uid() AND role = 'admin'));

CREATE INDEX IF NOT EXISTS idx_rev_group_id    ON reviews(group_id);
CREATE INDEX IF NOT EXISTS idx_rev_client_id   ON reviews(client_id);
CREATE INDEX IF NOT EXISTS idx_rev_created_at  ON reviews(created_at DESC);

-- ────────────────────────────────────────────────────────────────────────────
-- 2. COLUMNAS EN GROUPS
-- ────────────────────────────────────────────────────────────────────────────

ALTER TABLE groups
  ADD COLUMN IF NOT EXISTS average_rating NUMERIC(3,2) DEFAULT 0,
  ADD COLUMN IF NOT EXISTS total_reviews   INT          DEFAULT 0,
  ADD COLUMN IF NOT EXISTS ranking_score   NUMERIC(8,4) DEFAULT 0,
  ADD COLUMN IF NOT EXISTS badges          TEXT[]       DEFAULT '{}';

-- ────────────────────────────────────────────────────────────────────────────
-- 3. FUNCIÓN: RECALCULAR REPUTACIÓN DEL GRUPO
-- ────────────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION update_group_reputation()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_group_id    UUID := COALESCE(NEW.group_id, OLD.group_id);
  v_avg         NUMERIC(3,2);
  v_count       INT;
  v_total_ev    INT;
  v_cancel_rate NUMERIC;
  v_score       NUMERIC(8,4);
  v_badges      TEXT[] := '{}';
BEGIN
  -- Promedio y conteo de reseñas
  SELECT ROUND(AVG(rating)::NUMERIC, 2), COUNT(*)
  INTO v_avg, v_count
  FROM reviews
  WHERE group_id = v_group_id;

  -- Total eventos completados
  SELECT COUNT(*) INTO v_total_ev
  FROM reservations
  WHERE group_id = v_group_id AND status = 'completed';

  -- Tasa de cancelaciones (últimos 90 días)
  SELECT
    CASE WHEN COUNT(*) = 0 THEN 0
         ELSE COUNT(*) FILTER (WHERE status = 'cancelled')::NUMERIC / COUNT(*)
    END
  INTO v_cancel_rate
  FROM reservations
  WHERE group_id = v_group_id
    AND created_at >= NOW() - INTERVAL '90 days';

  -- Ranking score
  -- (avg_rating * 0.5) + (eventos_norm * 5 * 0.3) - (cancel_rate * 5 * 0.2)
  v_score := (COALESCE(v_avg, 0) * 0.5)
           + (LEAST(v_total_ev, 50) / 50.0 * 5.0 * 0.3)
           - (COALESCE(v_cancel_rate, 0) * 5.0 * 0.2);

  -- Insignias automáticas
  IF COALESCE(v_avg, 0) >= 4.5 AND v_count >= 5 THEN
    v_badges := array_append(v_badges, 'top_artist');
  END IF;

  IF v_total_ev >= 10 THEN
    v_badges := array_append(v_badges, 'high_demand');
  END IF;

  -- "verified" lo maneja el flujo de verificación existente — no tocamos is_verified

  UPDATE groups
  SET average_rating = COALESCE(v_avg, 0),
      total_reviews   = v_count,
      ranking_score   = GREATEST(v_score, 0),
      badges          = v_badges
  WHERE id = v_group_id;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_update_group_reputation ON reviews;
CREATE TRIGGER trg_update_group_reputation
  AFTER INSERT OR UPDATE OR DELETE ON reviews
  FOR EACH ROW EXECUTE FUNCTION update_group_reputation();

-- ────────────────────────────────────────────────────────────────────────────
-- 4. RPC: VERIFICAR ELEGIBILIDAD PARA CALIFICAR
-- Devuelve si el cliente puede calificar una reserva completada.
-- ────────────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION check_review_eligibility(p_reservation_id UUID)
RETURNS JSON LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_res RECORD;
BEGIN
  SELECT r.id, r.status, r.group_id, r.client_id,
         EXISTS (SELECT 1 FROM reviews WHERE reservation_id = r.id) AS already_reviewed
  INTO v_res
  FROM reservations r
  WHERE r.id = p_reservation_id;

  IF NOT FOUND THEN
    RETURN json_build_object('eligible', false, 'reason', 'not_found');
  END IF;

  IF v_res.client_id != auth.uid() THEN
    RETURN json_build_object('eligible', false, 'reason', 'not_your_reservation');
  END IF;

  IF v_res.status != 'completed' THEN
    RETURN json_build_object('eligible', false, 'reason', 'not_completed');
  END IF;

  IF v_res.already_reviewed THEN
    RETURN json_build_object('eligible', false, 'reason', 'already_reviewed');
  END IF;

  RETURN json_build_object('eligible', true, 'group_id', v_res.group_id);
END;
$$;

GRANT EXECUTE ON FUNCTION check_review_eligibility(UUID) TO authenticated;

-- ────────────────────────────────────────────────────────────────────────────
-- 5. RPC: ENVIAR CALIFICACIÓN
-- ────────────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION submit_review(
  p_reservation_id UUID,
  p_rating         SMALLINT,
  p_comment        TEXT DEFAULT NULL
)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_res      RECORD;
  v_review_id UUID;
BEGIN
  -- Validar reserva: debe pertenecer al cliente y estar completada
  SELECT r.id, r.group_id, r.client_id, r.event_date
  INTO v_res
  FROM reservations r
  WHERE r.id       = p_reservation_id
    AND r.client_id = auth.uid()
    AND r.status    = 'completed';

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'reservation_not_eligible');
  END IF;

  -- Verificar que no haya reseña previa
  IF EXISTS (SELECT 1 FROM reviews WHERE reservation_id = p_reservation_id) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'already_reviewed');
  END IF;

  -- Validar calificación
  IF p_rating < 1 OR p_rating > 5 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_rating');
  END IF;

  -- Insertar reseña
  INSERT INTO reviews (reservation_id, client_id, group_id, rating, comment)
  VALUES (p_reservation_id, auth.uid(), v_res.group_id, p_rating, p_comment)
  RETURNING id INTO v_review_id;

  -- Notificar al dueño del grupo
  INSERT INTO notifications (user_id, type, title, message, reference_id)
  SELECT g.owner_id, 'general',
    '⭐ Nueva reseña — ' || p_rating || '/5',
    'Un cliente calificó tu evento del ' || v_res.event_date || ' con ' || p_rating || ' estrellas.' ||
    CASE WHEN p_comment IS NOT NULL AND p_comment != ''
      THEN ' Comentario: "' || LEFT(p_comment, 80) || '"'
      ELSE ''
    END,
    v_res.group_id
  FROM groups g
  WHERE g.id = v_res.group_id;

  RETURN jsonb_build_object(
    'ok',        true,
    'review_id', v_review_id,
    'group_id',  v_res.group_id
  );

EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$$;

GRANT EXECUTE ON FUNCTION submit_review(UUID, SMALLINT, TEXT) TO authenticated;

-- ────────────────────────────────────────────────────────────────────────────
-- 6. RPC: OBTENER RESEÑAS DE UN GRUPO (pública)
-- ────────────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION get_group_reviews(
  p_group_id UUID,
  p_limit    INT DEFAULT 20
)
RETURNS TABLE (
  review_id  UUID,
  rating     SMALLINT,
  comment    TEXT,
  created_at TIMESTAMPTZ,
  client_name TEXT
) LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
  RETURN QUERY
  SELECT
    rv.id,
    rv.rating,
    rv.comment,
    rv.created_at,
    COALESCE(p.full_name, 'Cliente') AS client_name
  FROM reviews rv
  LEFT JOIN profiles p ON p.id = rv.client_id
  WHERE rv.group_id = p_group_id
  ORDER BY rv.created_at DESC
  LIMIT p_limit;
END;
$$;

GRANT EXECUTE ON FUNCTION get_group_reviews(UUID, INT) TO authenticated, anon;

-- ────────────────────────────────────────────────────────────────────────────
-- 7. BACKFILL: recalcular reputación de grupos con reservas completadas
-- ────────────────────────────────────────────────────────────────────────────

DO $$
DECLARE
  v_group RECORD;
  v_avg         NUMERIC(3,2);
  v_count       INT;
  v_total_ev    INT;
  v_cancel_rate NUMERIC;
  v_score       NUMERIC(8,4);
  v_badges      TEXT[];
BEGIN
  FOR v_group IN SELECT DISTINCT group_id FROM reservations WHERE status = 'completed' LOOP
    SELECT ROUND(AVG(rating)::NUMERIC, 2), COUNT(*)
    INTO v_avg, v_count
    FROM reviews WHERE group_id = v_group.group_id;

    SELECT COUNT(*) INTO v_total_ev
    FROM reservations WHERE group_id = v_group.group_id AND status = 'completed';

    SELECT CASE WHEN COUNT(*) = 0 THEN 0
                ELSE COUNT(*) FILTER (WHERE status = 'cancelled')::NUMERIC / COUNT(*) END
    INTO v_cancel_rate
    FROM reservations
    WHERE group_id = v_group.group_id AND created_at >= NOW() - INTERVAL '90 days';

    v_score := (COALESCE(v_avg, 0) * 0.5)
             + (LEAST(v_total_ev, 50) / 50.0 * 5.0 * 0.3)
             - (COALESCE(v_cancel_rate, 0) * 5.0 * 0.2);

    v_badges := '{}';
    IF COALESCE(v_avg, 0) >= 4.5 AND v_count >= 5 THEN
      v_badges := array_append(v_badges, 'top_artist');
    END IF;
    IF v_total_ev >= 10 THEN
      v_badges := array_append(v_badges, 'high_demand');
    END IF;

    UPDATE groups
    SET average_rating = COALESCE(v_avg, 0),
        total_reviews   = v_count,
        ranking_score   = GREATEST(v_score, 0),
        badges          = v_badges
    WHERE id = v_group.group_id;
  END LOOP;
END;
$$;

SELECT '93_reputation_system: reviews + ranking + badges ✅' AS status;
