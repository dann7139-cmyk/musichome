-- ════════════════════════════════════════════════════════════════════════════
-- 131_top_recommendation.sql
-- Recomendación inteligente basada en scoring real de grupos.
--
-- get_top_recommendation(p_city, p_genre, p_limit)
--   Puntúa cada grupo activo con factores reales:
--     rating, reseñas, actividad reciente, verificación,
--     demanda, puntos de reputación, boost.
--   Devuelve el/los grupos con mayor score junto con
--   etiquetas de beneficios listas para mostrar en UI.
--
-- Ejecutar DESPUÉS de 130_activity_signals.sql
-- ════════════════════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION public.get_top_recommendation(
  p_city   TEXT DEFAULT NULL,
  p_genre  TEXT DEFAULT NULL,
  p_limit  INT  DEFAULT 1
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_result     JSONB := '[]'::JSONB;
  v_row        RECORD;
  v_benefits   JSONB;
BEGIN
  FOR v_row IN
    SELECT
      g.id,
      g.name,
      g.genre,
      g.city,
      g.country,
      g.profile_image,
      g.photo_status,
      g.price_from,
      g.rating,
      g.total_reviews,
      g.is_verified,
      g.nivel,
      COALESCE(g.is_high_demand,   FALSE) AS is_high_demand,
      g.last_booked_at,
      COALESCE(g.recent_completions, 0)   AS recent_completions,
      COALESCE(g.puntos_reputacion,  0)   AS puntos_reputacion,
      COALESCE(g.boost_score,        0)   AS boost_score,
      COALESCE(g.average_rating,     g.rating, 4.0) AS avg_rating,

      -- ── Score compuesto ──────────────────────────────────────────────
      (
        -- Calidad (max ~100)
        COALESCE(g.average_rating, g.rating, 4.0) * 20.0

        -- Confianza: reseñas (cap 25)
        + LEAST(COALESCE(g.total_reviews, 0), 25) * 1.5

        -- Actividad: eventos este mes (cap 10)
        + LEAST(COALESCE(g.recent_completions, 0), 10) * 3.0

        -- Verificación
        + CASE WHEN g.is_verified THEN 15.0 ELSE 0.0 END

        -- Demanda real (señal 130)
        + CASE WHEN COALESCE(g.is_high_demand, FALSE) THEN 10.0 ELSE 0.0 END

        -- Actividad reciente (reservado < 48 h)
        + CASE WHEN g.last_booked_at > NOW() - INTERVAL '48 hours' THEN 8.0
               WHEN g.last_booked_at > NOW() - INTERVAL '7 days'   THEN 4.0
               ELSE 0.0 END

        -- Reputación plataforma
        + COALESCE(g.puntos_reputacion, 0) * 0.1

        -- Boost pagado
        + COALESCE(g.boost_score, 0) * 2.0
      ) AS score

    FROM public.groups g
    WHERE g.is_active = TRUE
      -- Filtro opcional por ciudad
      AND (p_city  IS NULL OR g.city  ILIKE '%' || p_city  || '%')
      -- Filtro opcional por género/tipo
      AND (p_genre IS NULL OR g.genre ILIKE '%' || p_genre || '%')
      -- Solo grupos con rating >= 3.5 para no recomendar grupos pobres
      AND COALESCE(g.average_rating, g.rating, 0) >= 3.5

    ORDER BY score DESC
    LIMIT p_limit
  LOOP
    -- Construir array de beneficios visibles
    v_benefits := '[]'::JSONB;

    -- Calificación
    IF COALESCE(v_row.avg_rating, 4.0) >= 4.7 THEN
      v_benefits := v_benefits || jsonb_build_array(
        jsonb_build_object('icon', '⭐', 'label',
          round(v_row.avg_rating::NUMERIC, 1)::TEXT || ' calificación top')
      );
    ELSIF COALESCE(v_row.avg_rating, 4.0) >= 4.3 THEN
      v_benefits := v_benefits || jsonb_build_array(
        jsonb_build_object('icon', '⭐', 'label',
          round(v_row.avg_rating::NUMERIC, 1)::TEXT || ' calificación')
      );
    END IF;

    -- Verificado
    IF v_row.is_verified THEN
      v_benefits := v_benefits || jsonb_build_array(
        jsonb_build_object('icon', '✅', 'label', 'Grupo verificado')
      );
    END IF;

    -- Alta demanda
    IF v_row.is_high_demand THEN
      v_benefits := v_benefits || jsonb_build_array(
        jsonb_build_object('icon', '🔥', 'label', 'Alta demanda')
      );
    END IF;

    -- Activo recientemente
    IF v_row.last_booked_at > NOW() - INTERVAL '48 hours' THEN
      v_benefits := v_benefits || jsonb_build_array(
        jsonb_build_object('icon', '⚡', 'label', 'Reservado recientemente')
      );
    END IF;

    -- Eventos completados este mes
    IF v_row.recent_completions >= 3 THEN
      v_benefits := v_benefits || jsonb_build_array(
        jsonb_build_object('icon', '🎵', 'label',
          v_row.recent_completions::TEXT || ' eventos este mes')
      );
    END IF;

    -- Reseñas
    IF v_row.total_reviews >= 10 THEN
      v_benefits := v_benefits || jsonb_build_array(
        jsonb_build_object('icon', '💬', 'label',
          v_row.total_reviews::TEXT || ' reseñas')
      );
    END IF;

    v_result := v_result || jsonb_build_array(
      jsonb_build_object(
        'id',            v_row.id,
        'name',          v_row.name,
        'genre',         v_row.genre,
        'city',          v_row.city,
        'country',       v_row.country,
        'profile_image', v_row.profile_image,
        'photo_status',  v_row.photo_status,
        'price_from',    v_row.price_from,
        'rating',        v_row.avg_rating,
        'total_reviews', v_row.total_reviews,
        'is_verified',   v_row.is_verified,
        'is_high_demand',v_row.is_high_demand,
        'nivel',         v_row.nivel,
        'score',         round(v_row.score::NUMERIC, 1),
        'benefits',      v_benefits
      )
    );
  END LOOP;

  -- Si p_limit = 1 devolver el objeto directamente, si no el array
  IF p_limit = 1 THEN
    RETURN CASE WHEN jsonb_array_length(v_result) > 0
                THEN v_result -> 0
                ELSE NULL END;
  END IF;

  RETURN v_result;

EXCEPTION WHEN OTHERS THEN
  RETURN NULL;
END;
$$;

GRANT EXECUTE ON FUNCTION public.get_top_recommendation(TEXT, TEXT, INT) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_top_recommendation(TEXT, TEXT, INT) TO anon;

SELECT '131_top_recommendation.sql ejecutado ✅' AS status;
SELECT 'Función: get_top_recommendation(p_city, p_genre, p_limit)' AS info;
