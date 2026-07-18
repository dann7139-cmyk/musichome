-- ============================================================
-- sql/512_sync_group_rating.sql
-- ⭐ FIX "la calificación promedio siempre se ve igual" (2026-07-18)
--
--  Causa: el trigger de reseñas (recalculate_group_reputation,
--  sql/104) solo actualiza groups.average_rating — NADIE actualiza
--  groups.rating. Pero groups.rating es lo que leen: Estadísticas
--  del grupo, el explorador (get_groups_ranked_by_city), los tops,
--  Mi desempeño (508) y la comparativa de países. Todos congelados.
--
--  Fix en la FUENTE (un solo lugar, arregla todos los consumidores):
--   1. El recálculo ahora escribe rating = average_rating.
--   2. Backfill: sincroniza los ratings existentes ya desincronizados.
--  (Cuerpo copiado ÍNTEGRO de sql/104; solo se agrega la línea de
--   rating en el UPDATE final.)
-- ============================================================

BEGIN;

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
  SELECT CASE WHEN COUNT(*) = 0 THEN 0.5
              ELSE COUNT(*) FILTER (WHERE status IN ('confirmed','completed'))
                   ::NUMERIC / COUNT(*)
         END
  INTO   v_accept_rate
  FROM   public.reservations
  WHERE  group_id = p_group_id;

  -- ── Velocidad de respuesta ───────────────────────────────────────────────
  SELECT CASE WHEN COUNT(*) = 0 THEN 2.5
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

  -- ── Disputas activas ─────────────────────────────────────────────────────
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

  -- ── Boost temporal activo ────────────────────────────────────────────────
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
      -- ⭐ [512] rating SIEMPRE en sincronía — lo leen el explorador,
      -- Estadísticas, Mi desempeño, tops y comparativas
      rating          = COALESCE(v_avg, 0),
      total_reviews   = COALESCE(v_count, 0),
      ranking_score   = GREATEST(v_score, 0),
      badges          = v_badges
  WHERE id = p_group_id;
END;
$$;

-- Backfill: sincronizar los desincronizados de una vez
UPDATE public.groups
SET rating = average_rating
WHERE COALESCE(total_reviews, 0) > 0
  AND rating IS DISTINCT FROM average_rating;

COMMIT;

-- ── VERIFICACIÓN ──────────────────────────────────────────────────────────────
SELECT prosrc LIKE '%rating          = COALESCE(v_avg, 0)%' AS rating_sincronizado
FROM pg_proc WHERE proname = 'recalculate_group_reputation';
-- Esperado: true

SELECT COUNT(*) AS desincronizados   -- Esperado: 0
FROM groups
WHERE COALESCE(total_reviews, 0) > 0
  AND rating IS DISTINCT FROM average_rating;

SELECT '512_sync_group_rating.sql ejecutado ✅' AS status;
