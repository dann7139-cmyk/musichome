-- ============================================================
-- sql/507_intelligence_center.sql
-- 🧠 CENTRO DE INTELIGENCIA (cambios aprobados 2026-07-18)
--
--  1. admin_country_compare — comparativa por país: grupos, talentos,
--     eventos, ingresos (por moneda) y calificación promedio. Incluye
--     el balde "País no definido" — NUNCA se mezcla ni se inventa.
--  2. admin_pending_country_list / admin_set_country — la tarjeta
--     "Registros pendientes de clasificar": lista y corrección uno
--     por uno (solo admin).
--  3. Des-inventar países: los grupos que el backfill 321 forzó a
--     'México' SIN estado que lo respalde vuelven a NULL (reporta
--     cuántos). Reversible: solo toca los que no tienen estado.
--  4. admin_rankings — grupos (eventos, ingresos, rating,
--     crecimiento), talentos (contratados, rating, eventos) y
--     ciudades (eventos, ingresos, crecimiento).
--  5. admin_alerts — SOLO lo que requiere atención, con conteos.
--
--  Todo de solo lectura excepto admin_set_country (acción explícita
--  del admin). Fórmulas de dinero = las canónicas de sql/490.
-- ============================================================

BEGIN;

-- ── 3. Des-inventar: fallback 'México' sin estado → País no definido ──
DO $$
DECLARE v_fixed INT;
BEGIN
  UPDATE groups SET country = NULL
  WHERE country = 'México' AND (state IS NULL OR TRIM(state) = '');
  GET DIAGNOSTICS v_fixed = ROW_COUNT;
  RAISE NOTICE '[507] Grupos regresados a "País no definido": %', v_fixed;
END $$;

-- ── 1. Comparativa por país ──────────────────────────────────
CREATE OR REPLACE FUNCTION public.admin_country_compare(
  p_from DATE DEFAULT NULL,
  p_to   DATE DEFAULT NULL
)
RETURNS JSONB LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_from DATE := COALESCE(p_from, '2000-01-01');
  v_to   DATE := COALESCE(p_to, (NOW() AT TIME ZONE 'America/Mexico_City')::date);
BEGIN
  IF NOT EXISTS (SELECT 1 FROM profiles WHERE id = auth.uid() AND role = 'admin') THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_admin');
  END IF;

  RETURN jsonb_build_object(
    'ok', true,
    'countries', COALESCE((
      SELECT jsonb_agg(jsonb_build_object(
        'pais',        t.pais,
        'grupos',      t.grupos,
        'talentos',    t.talentos,
        'eventos',     t.eventos,
        'ingresos',    t.ingresos,
        'moneda',      t.moneda,
        'rating',      t.rating
      ) ORDER BY (t.pais = 'País no definido') ASC, t.eventos DESC)
      FROM (
        SELECT
          co.pais,
          (SELECT COUNT(*) FROM groups g
            WHERE COALESCE(g.country, 'País no definido') = co.pais AND g.is_active) AS grupos,
          (SELECT COUNT(*) FROM profiles p
            WHERE p.role = 'talent'
              AND COALESCE(p.country, 'País no definido') = co.pais)                AS talentos,
          (SELECT COUNT(*) FROM reservations r
            LEFT JOIN groups g2 ON g2.id = r.group_id
            WHERE r.payment_status IN ('paid','fully_paid','deposit_paid')
              AND (r.created_at AT TIME ZONE 'America/Mexico_City')::date BETWEEN v_from AND v_to
              AND COALESCE(g2.country,
                    CASE COALESCE(r.currency_code,'MXN')
                      WHEN 'USD' THEN 'Estados Unidos'
                      WHEN 'CAD' THEN 'Canadá' ELSE 'México' END) = co.pais)        AS eventos,
          (SELECT COALESCE(SUM(COALESCE(r.total_price,0) + COALESCE(r.msi_fee_amount,0)), 0)
            FROM reservations r
            LEFT JOIN groups g2 ON g2.id = r.group_id
            WHERE r.payment_status IN ('paid','fully_paid','deposit_paid')
              AND (r.created_at AT TIME ZONE 'America/Mexico_City')::date BETWEEN v_from AND v_to
              AND COALESCE(g2.country,
                    CASE COALESCE(r.currency_code,'MXN')
                      WHEN 'USD' THEN 'Estados Unidos'
                      WHEN 'CAD' THEN 'Canadá' ELSE 'México' END) = co.pais)        AS ingresos,
          CASE co.pais WHEN 'Estados Unidos' THEN 'USD' WHEN 'Canadá' THEN 'CAD' ELSE 'MXN' END AS moneda,
          (SELECT ROUND(AVG(g.rating)::NUMERIC, 2) FROM groups g
            WHERE COALESCE(g.country, 'País no definido') = co.pais
              AND g.rating IS NOT NULL AND COALESCE(g.total_reviews, 0) > 0)        AS rating
        FROM (
          SELECT DISTINCT COALESCE(country, 'País no definido') AS pais FROM groups
          UNION SELECT 'México' UNION SELECT 'Estados Unidos' UNION SELECT 'Canadá'
        ) co
      ) t
    ), '[]'::jsonb),
    'pendientes', jsonb_build_object(
      'grupos',   (SELECT COUNT(*) FROM groups   WHERE country IS NULL),
      'talentos', (SELECT COUNT(*) FROM profiles WHERE role = 'talent' AND country IS NULL)
    )
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.admin_country_compare(DATE, DATE) TO authenticated;

-- ── 2a. Lista de pendientes de clasificar ────────────────────
CREATE OR REPLACE FUNCTION public.admin_pending_country_list()
RETURNS JSONB LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM profiles WHERE id = auth.uid() AND role = 'admin') THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_admin');
  END IF;
  RETURN jsonb_build_object(
    'ok', true,
    'items', COALESCE((
      SELECT jsonb_agg(item ORDER BY item->>'name') FROM (
        SELECT jsonb_build_object(
          'entity', 'group', 'id', g.id, 'name', g.name,
          'state', g.state, 'city', g.city) AS item
        FROM groups g WHERE g.country IS NULL
        UNION ALL
        SELECT jsonb_build_object(
          'entity', 'talent', 'id', p.id, 'name', p.full_name,
          'state', p.state, 'city', p.city)
        FROM profiles p WHERE p.role = 'talent' AND p.country IS NULL
        LIMIT 200
      ) t
    ), '[]'::jsonb)
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.admin_pending_country_list() TO authenticated;

-- ── 2b. Asignar país (uno por uno, solo admin) ───────────────
CREATE OR REPLACE FUNCTION public.admin_set_country(
  p_entity  TEXT,   -- 'group' | 'talent'
  p_id      UUID,
  p_country TEXT    -- 'México' | 'Estados Unidos' | 'Canadá'
)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM profiles WHERE id = auth.uid() AND role = 'admin') THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_admin');
  END IF;
  IF p_country NOT IN ('México', 'Estados Unidos', 'Canadá') THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_country');
  END IF;

  IF p_entity = 'group' THEN
    UPDATE groups SET country = p_country WHERE id = p_id;
  ELSIF p_entity = 'talent' THEN
    UPDATE profiles SET country = p_country WHERE id = p_id AND role = 'talent';
  ELSE
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_entity');
  END IF;

  RETURN jsonb_build_object('ok', true);
END;
$$;

GRANT EXECUTE ON FUNCTION public.admin_set_country(TEXT, UUID, TEXT) TO authenticated;

-- ── 4. Rankings ──────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.admin_rankings(
  p_from    DATE DEFAULT NULL,
  p_to      DATE DEFAULT NULL,
  p_country TEXT DEFAULT NULL,
  p_state   TEXT DEFAULT NULL,
  p_limit   INT  DEFAULT 5
)
RETURNS JSONB LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_from DATE := COALESCE(p_from, '2000-01-01');
  v_to   DATE := COALESCE(p_to, (NOW() AT TIME ZONE 'America/Mexico_City')::date);
  -- Periodo anterior de la MISMA duración (para "mayor crecimiento")
  v_len  INT  := GREATEST((v_to - v_from), 1);
  v_prev_from DATE := v_from - v_len;
  v_ctry  TEXT := CASE WHEN p_country IS NULL THEN NULL ELSE normalize_state_name(p_country) END;
  v_state TEXT := CASE WHEN p_state   IS NULL THEN NULL ELSE normalize_state_name(p_state)   END;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM profiles WHERE id = auth.uid() AND role = 'admin') THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_admin');
  END IF;

  RETURN jsonb_build_object(
    'ok', true,
    -- ── Grupos ──
    'groups_events', COALESCE((
      SELECT jsonb_agg(jsonb_build_object('name', t.name, 'state', t.state, 'value', t.n) ORDER BY t.n DESC)
      FROM (
        SELECT g.name, g.state, COUNT(*) AS n
        FROM reservations r JOIN groups g ON g.id = r.group_id
        WHERE r.status = 'completed'
          AND (r.created_at AT TIME ZONE 'America/Mexico_City')::date BETWEEN v_from AND v_to
          AND (v_ctry  IS NULL OR normalize_state_name(COALESCE(g.country, '')) = v_ctry)
          AND (v_state IS NULL OR normalize_state_name(g.state) = v_state)
        GROUP BY g.id, g.name, g.state ORDER BY n DESC LIMIT p_limit
      ) t), '[]'::jsonb),
    'groups_income', COALESCE((
      SELECT jsonb_agg(jsonb_build_object('name', t.name, 'state', t.state, 'value', t.total) ORDER BY t.total DESC)
      FROM (
        SELECT g.name, g.state, SUM(COALESCE(r.group_earnings, 0)) AS total
        FROM reservations r JOIN groups g ON g.id = r.group_id
        WHERE r.payment_status IN ('paid','fully_paid','deposit_paid')
          AND (r.created_at AT TIME ZONE 'America/Mexico_City')::date BETWEEN v_from AND v_to
          AND (v_ctry  IS NULL OR normalize_state_name(COALESCE(g.country, '')) = v_ctry)
          AND (v_state IS NULL OR normalize_state_name(g.state) = v_state)
        GROUP BY g.id, g.name, g.state ORDER BY total DESC LIMIT p_limit
      ) t), '[]'::jsonb),
    'groups_rating', COALESCE((
      SELECT jsonb_agg(jsonb_build_object('name', g.name, 'state', g.state, 'value', g.rating,
                                          'extra', g.total_reviews) ORDER BY g.rating DESC)
      FROM (
        SELECT name, state, rating, total_reviews FROM groups
        WHERE is_active AND COALESCE(total_reviews, 0) > 0
          AND (v_ctry  IS NULL OR normalize_state_name(COALESCE(country, '')) = v_ctry)
          AND (v_state IS NULL OR normalize_state_name(state) = v_state)
        ORDER BY rating DESC, total_reviews DESC LIMIT p_limit
      ) g), '[]'::jsonb),
    'groups_growth', COALESCE((
      SELECT jsonb_agg(jsonb_build_object('name', t.name, 'state', t.state,
                                          'value', t.actual, 'extra', t.anterior) ORDER BY (t.actual - t.anterior) DESC)
      FROM (
        SELECT g.name, g.state,
               COUNT(*) FILTER (WHERE (r.created_at AT TIME ZONE 'America/Mexico_City')::date BETWEEN v_from AND v_to)      AS actual,
               COUNT(*) FILTER (WHERE (r.created_at AT TIME ZONE 'America/Mexico_City')::date BETWEEN v_prev_from AND v_from - 1) AS anterior
        FROM reservations r JOIN groups g ON g.id = r.group_id
        WHERE r.payment_status IN ('paid','fully_paid','deposit_paid')
          AND (r.created_at AT TIME ZONE 'America/Mexico_City')::date BETWEEN v_prev_from AND v_to
          AND (v_ctry  IS NULL OR normalize_state_name(COALESCE(g.country, '')) = v_ctry)
          AND (v_state IS NULL OR normalize_state_name(g.state) = v_state)
        GROUP BY g.id, g.name, g.state
        HAVING COUNT(*) FILTER (WHERE (r.created_at AT TIME ZONE 'America/Mexico_City')::date BETWEEN v_from AND v_to) > 0
        ORDER BY (COUNT(*) FILTER (WHERE (r.created_at AT TIME ZONE 'America/Mexico_City')::date BETWEEN v_from AND v_to)
                - COUNT(*) FILTER (WHERE (r.created_at AT TIME ZONE 'America/Mexico_City')::date BETWEEN v_prev_from AND v_from - 1)) DESC
        LIMIT p_limit
      ) t), '[]'::jsonb),
    -- ── Talentos ──
    'talents_hired', COALESCE((
      SELECT jsonb_agg(jsonb_build_object('name', t.name, 'value', t.n) ORDER BY t.n DESC)
      FROM (
        SELECT COALESCE(p.full_name, 'Talento') AS name, COUNT(*) AS n
        FROM job_invitations ji JOIN profiles p ON p.id = ji.invited_user_id
        WHERE ji.status = 'accepted'
          AND (ji.created_at AT TIME ZONE 'America/Mexico_City')::date BETWEEN v_from AND v_to
          AND (v_ctry IS NULL OR normalize_state_name(COALESCE(p.country, '')) = v_ctry)
        GROUP BY p.id, p.full_name ORDER BY n DESC LIMIT p_limit
      ) t), '[]'::jsonb),
    'talents_rating', COALESCE((
      SELECT jsonb_agg(jsonb_build_object('name', t.name, 'value', t.rating, 'extra', t.cnt) ORDER BY t.rating DESC)
      FROM (
        SELECT COALESCE(p.full_name, 'Talento') AS name, p.talent_rating AS rating, p.talent_reviews_count AS cnt
        FROM profiles p
        WHERE p.role = 'talent' AND p.talent_rating IS NOT NULL AND COALESCE(p.talent_reviews_count, 0) > 0
          AND (v_ctry IS NULL OR normalize_state_name(COALESCE(p.country, '')) = v_ctry)
        ORDER BY p.talent_rating DESC, p.talent_reviews_count DESC LIMIT p_limit
      ) t), '[]'::jsonb),
    'talents_events', COALESCE((
      SELECT jsonb_agg(jsonb_build_object('name', t.name, 'value', t.n) ORDER BY t.n DESC)
      FROM (
        SELECT COALESCE(p.full_name, 'Talento') AS name, COUNT(DISTINCT tr.reservation_id) AS n
        FROM talent_reviews tr JOIN profiles p ON p.id = tr.talent_id
        WHERE (tr.created_at AT TIME ZONE 'America/Mexico_City')::date BETWEEN v_from AND v_to
          AND (v_ctry IS NULL OR normalize_state_name(COALESCE(p.country, '')) = v_ctry)
        GROUP BY p.id, p.full_name ORDER BY n DESC LIMIT p_limit
      ) t), '[]'::jsonb),
    -- ── Ciudades ──
    'cities_events', COALESCE((
      SELECT jsonb_agg(jsonb_build_object('name', t.ciudad, 'value', t.n) ORDER BY t.n DESC)
      FROM (
        SELECT COALESCE(NULLIF(TRIM(r.event_city), ''), g.city, 'Sin ciudad') AS ciudad, COUNT(*) AS n
        FROM reservations r LEFT JOIN groups g ON g.id = r.group_id
        WHERE r.payment_status IN ('paid','fully_paid','deposit_paid')
          AND (r.created_at AT TIME ZONE 'America/Mexico_City')::date BETWEEN v_from AND v_to
          AND (v_ctry  IS NULL OR normalize_state_name(COALESCE(g.country, '')) = v_ctry)
          AND (v_state IS NULL OR normalize_state_name(g.state) = v_state)
        GROUP BY 1 ORDER BY n DESC LIMIT p_limit
      ) t), '[]'::jsonb),
    'cities_income', COALESCE((
      SELECT jsonb_agg(jsonb_build_object('name', t.ciudad, 'value', t.total) ORDER BY t.total DESC)
      FROM (
        SELECT COALESCE(NULLIF(TRIM(r.event_city), ''), g.city, 'Sin ciudad') AS ciudad,
               SUM(COALESCE(r.total_price, 0) + COALESCE(r.msi_fee_amount, 0)) AS total
        FROM reservations r LEFT JOIN groups g ON g.id = r.group_id
        WHERE r.payment_status IN ('paid','fully_paid','deposit_paid')
          AND (r.created_at AT TIME ZONE 'America/Mexico_City')::date BETWEEN v_from AND v_to
          AND (v_ctry  IS NULL OR normalize_state_name(COALESCE(g.country, '')) = v_ctry)
          AND (v_state IS NULL OR normalize_state_name(g.state) = v_state)
        GROUP BY 1 ORDER BY total DESC LIMIT p_limit
      ) t), '[]'::jsonb),
    'cities_growth', COALESCE((
      SELECT jsonb_agg(jsonb_build_object('name', t.ciudad, 'value', t.actual, 'extra', t.anterior)
                       ORDER BY (t.actual - t.anterior) DESC)
      FROM (
        SELECT COALESCE(NULLIF(TRIM(r.event_city), ''), g.city, 'Sin ciudad') AS ciudad,
               COUNT(*) FILTER (WHERE (r.created_at AT TIME ZONE 'America/Mexico_City')::date BETWEEN v_from AND v_to)      AS actual,
               COUNT(*) FILTER (WHERE (r.created_at AT TIME ZONE 'America/Mexico_City')::date BETWEEN v_prev_from AND v_from - 1) AS anterior
        FROM reservations r LEFT JOIN groups g ON g.id = r.group_id
        WHERE r.payment_status IN ('paid','fully_paid','deposit_paid')
          AND (r.created_at AT TIME ZONE 'America/Mexico_City')::date BETWEEN v_prev_from AND v_to
          AND (v_ctry  IS NULL OR normalize_state_name(COALESCE(g.country, '')) = v_ctry)
          AND (v_state IS NULL OR normalize_state_name(g.state) = v_state)
        GROUP BY 1
        HAVING COUNT(*) FILTER (WHERE (r.created_at AT TIME ZONE 'America/Mexico_City')::date BETWEEN v_from AND v_to) > 0
        ORDER BY (COUNT(*) FILTER (WHERE (r.created_at AT TIME ZONE 'America/Mexico_City')::date BETWEEN v_from AND v_to)
                - COUNT(*) FILTER (WHERE (r.created_at AT TIME ZONE 'America/Mexico_City')::date BETWEEN v_prev_from AND v_from - 1)) DESC
        LIMIT p_limit
      ) t), '[]'::jsonb)
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.admin_rankings(DATE, DATE, TEXT, TEXT, INT) TO authenticated;

-- ── 5. Alertas — solo lo que requiere atención ───────────────
CREATE OR REPLACE FUNCTION public.admin_alerts()
RETURNS JSONB LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM profiles WHERE id = auth.uid() AND role = 'admin') THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_admin');
  END IF;

  RETURN jsonb_build_object(
    'ok', true,
    'retiros_pendientes', (
      SELECT COUNT(*) FROM payout_requests WHERE status = 'pending'),
    'fees_no_capturados', (
      SELECT COUNT(*) FROM reservations
      WHERE payment_status IN ('paid','fully_paid','deposit_paid')
        AND stripe_fee_amount IS NULL),
    'sin_pais', (
      (SELECT COUNT(*) FROM groups WHERE country IS NULL)
      + (SELECT COUNT(*) FROM profiles WHERE role = 'talent' AND country IS NULL)),
    'grupos_suspendidos', (
      SELECT COUNT(*) FROM groups WHERE suspended_at IS NOT NULL),
    'disputas_abiertas', (
      SELECT COUNT(*) FROM disputes WHERE status IN ('open', 'under_review')),
    'reembolsos_pendientes', (
      SELECT COUNT(*) FROM manual_refunds WHERE status = 'pending'),
    'eventos_sin_cerrar', (
      SELECT COUNT(*) FROM reservations
      WHERE status = 'in_progress'
        AND event_date < (NOW() AT TIME ZONE 'America/Mexico_City')::date),
    'pagos_retenidos_viejos', (
      SELECT COUNT(*) FROM reservations
      WHERE payout_status = 'held'
        AND payment_status IN ('paid','fully_paid','deposit_paid')
        AND status = 'completed'
        AND held_at IS NOT NULL
        AND held_at < NOW() - INTERVAL '3 days')
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.admin_alerts() TO authenticated;

COMMIT;

-- ── VERIFICACIÓN ──────────────────────────────────────────────────────────────
SELECT proname FROM pg_proc WHERE proname IN
  ('admin_country_compare', 'admin_pending_country_list', 'admin_set_country',
   'admin_rankings', 'admin_alerts');
-- Esperado: 5 filas

SELECT COUNT(*) AS grupos_sin_pais FROM groups WHERE country IS NULL;
SELECT COUNT(*) AS talentos_sin_pais FROM profiles WHERE role = 'talent' AND country IS NULL;

SELECT '507_intelligence_center.sql ejecutado ✅' AS status;
