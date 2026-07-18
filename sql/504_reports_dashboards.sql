-- ============================================================
-- sql/504_reports_dashboards.sql
-- 📊 MÓDULO REPORTES (diseño aprobado 2026-07-18)
--
--  1. admin_reports_dashboard(from,to,country,state,city)
--     Panel ejecutivo del admin: dinero por moneda (fórmulas
--     canónicas de sql/490 — cero duplicadas), eventos, comunidad
--     por país y tendencia mensual. SOLO LECTURA.
--  2. group_performance_dashboard(from,to)
--     Panel del grupo (group_id derivado del token): rating,
--     eventos, ganancias (solo "tu ganancia" — Daricefy invisible),
--     ciudades, historial de pagos, tendencia, comentarios.
--  3. Tops por país/estado para Estadísticas → Inteligencia:
--     get_top_groups_earnings / get_top_groups_rating con
--     p_country/p_state opcionales (antes solo era global).
--
--  Reglas: monedas SEPARADAS siempre · cero estimaciones · fechas
--  en horario de México.
-- ============================================================

BEGIN;

-- ════════════════════════════════════════════════════════════
-- 1. admin_reports_dashboard
-- ════════════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION public.admin_reports_dashboard(
  p_from    DATE DEFAULT NULL,
  p_to      DATE DEFAULT NULL,
  p_country TEXT DEFAULT NULL,   -- 'México' | 'Estados Unidos' | 'Canadá' | NULL=todos
  p_state   TEXT DEFAULT NULL,
  p_city    TEXT DEFAULT NULL
)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_from    DATE := COALESCE(p_from, (NOW() AT TIME ZONE 'America/Mexico_City')::date - 29);
  v_to      DATE := COALESCE(p_to,   (NOW() AT TIME ZONE 'America/Mexico_City')::date);
  v_hoy     DATE := (NOW() AT TIME ZONE 'America/Mexico_City')::date;
  v_ctry    TEXT := CASE WHEN p_country IS NULL THEN NULL ELSE normalize_state_name(p_country) END;
  v_state   TEXT := CASE WHEN p_state   IS NULL THEN NULL ELSE normalize_state_name(p_state)   END;
  v_city    TEXT := CASE WHEN p_city    IS NULL THEN NULL ELSE normalize_city_name(p_city)     END;
  v_result  JSONB;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM profiles WHERE id = auth.uid() AND role = 'admin') THEN
    RETURN jsonb_build_object('ok', false, 'error', 'Acceso restringido a administradores');
  END IF;

  WITH base AS (
    SELECT r.*,
           (r.created_at AT TIME ZONE 'America/Mexico_City')::date AS dia_mx,
           COALESCE(r.currency_code, 'MXN')                        AS moneda,
           (COALESCE(r.total_price, 0) + COALESCE(r.msi_fee_amount, 0)) AS cobrado,
           COALESCE(r.group_earnings, r.base_price,
                    ROUND(COALESCE(r.total_price, 0) / 1.20, 2))   AS de_grupos,
           (COALESCE(r.service_fee_amount, r.commission_amount,
                     ROUND(COALESCE(r.total_price, 0) - COALESCE(r.group_earnings, r.base_price, ROUND(COALESCE(r.total_price,0)/1.20,2)), 2))
            + COALESCE(r.msi_fee_amount, 0))                       AS comision_bruta
    FROM reservations r
    LEFT JOIN groups g ON g.id = r.group_id
    WHERE (r.created_at AT TIME ZONE 'America/Mexico_City')::date BETWEEN v_from AND v_to
      AND (v_ctry  IS NULL OR normalize_state_name(COALESCE(g.country, 'México')) = v_ctry)
      AND (v_state IS NULL OR normalize_state_name(g.state) = v_state)
      AND (v_city  IS NULL OR normalize_city_name(COALESCE(r.event_city, g.city)) = v_city)
  ),
  pagadas AS (
    SELECT * FROM base WHERE payment_status IN ('paid', 'fully_paid', 'deposit_paid')
  ),
  por_moneda AS (
    SELECT
      moneda,
      COUNT(*)                                                    AS eventos_cobrados,
      SUM(cobrado)                                                AS total_cobrado,
      SUM(de_grupos)                                              AS dinero_grupos,
      SUM(de_grupos) FILTER (WHERE payout_status = 'held')        AS pendiente_grupos,
      SUM(de_grupos) FILTER (WHERE payout_status = 'released')    AS pagado_grupos,
      SUM(comision_bruta)                                         AS comision_daricefy,
      SUM(COALESCE(stripe_fee_amount, 0))                         AS fees_reales,
      COUNT(*) FILTER (WHERE stripe_fee_amount IS NULL)           AS fees_no_capturados,
      SUM(comision_bruta) - SUM(COALESCE(stripe_fee_amount, 0))   AS neto_estimado
    FROM pagadas
    GROUP BY moneda
  ),
  reembolsos AS (
    SELECT COALESCE(b.moneda, 'MXN') AS moneda,
           SUM(b.cobrado) AS reembolsado_auto, COUNT(*) AS reembolsos_auto
    FROM base b WHERE b.payment_status = 'refunded'
    GROUP BY COALESCE(b.moneda, 'MXN')
  ),
  -- Tendencia: 6 meses terminando en v_to (misma zona horaria y filtros)
  tendencia AS (
    SELECT
      to_char(date_trunc('month', (r.created_at AT TIME ZONE 'America/Mexico_City')), 'YYYY-MM') AS mes,
      COALESCE(r.currency_code, 'MXN') AS moneda,
      SUM(COALESCE(r.total_price, 0) + COALESCE(r.msi_fee_amount, 0)) AS total
    FROM reservations r
    LEFT JOIN groups g ON g.id = r.group_id
    WHERE r.payment_status IN ('paid', 'fully_paid', 'deposit_paid')
      AND (r.created_at AT TIME ZONE 'America/Mexico_City')::date
          BETWEEN (date_trunc('month', v_to::timestamp) - INTERVAL '5 months')::date AND v_to
      AND (v_ctry  IS NULL OR normalize_state_name(COALESCE(g.country, 'México')) = v_ctry)
      AND (v_state IS NULL OR normalize_state_name(g.state) = v_state)
      AND (v_city  IS NULL OR normalize_city_name(COALESCE(r.event_city, g.city)) = v_city)
    GROUP BY 1, 2
    ORDER BY 1
  )
  SELECT jsonb_build_object(
    'ok',   true,
    'from', v_from,
    'to',   v_to,
    'currencies', COALESCE((
      SELECT jsonb_agg(jsonb_build_object(
        'moneda',              pm.moneda,
        'eventos_cobrados',    pm.eventos_cobrados,
        'total_cobrado',       pm.total_cobrado,
        'dinero_grupos',       pm.dinero_grupos,
        'pendiente_grupos',    COALESCE(pm.pendiente_grupos, 0),
        'pagado_grupos',       COALESCE(pm.pagado_grupos, 0),
        'comision_daricefy',   pm.comision_daricefy,
        'fees_reales',         pm.fees_reales,
        'fees_no_capturados',  pm.fees_no_capturados,
        'neto_estimado',       pm.neto_estimado,
        'reembolsado',         COALESCE(re.reembolsado_auto, 0),
        'reembolsos',          COALESCE(re.reembolsos_auto, 0)
      ) ORDER BY pm.moneda)
      FROM por_moneda pm
      LEFT JOIN reembolsos re ON re.moneda = pm.moneda
    ), '[]'::jsonb),
    'events', (
      SELECT jsonb_build_object(
        'total',        COUNT(*),
        'completados',  COUNT(*) FILTER (WHERE status = 'completed'),
        'en_curso',     COUNT(*) FILTER (WHERE status = 'in_progress'),
        'proximos',     COUNT(*) FILTER (WHERE status IN ('accepted','confirmed')
                                          AND event_date >= v_hoy),
        'cancelados',   COUNT(*) FILTER (WHERE status = 'cancelled'),
        'cancel_cliente', COUNT(*) FILTER (WHERE status = 'cancelled' AND cancelled_by = 'client'),
        'cancel_grupo',   COUNT(*) FILTER (WHERE status = 'cancelled' AND cancelled_by = 'group'),
        'no_shows',     COUNT(*) FILTER (WHERE cancel_reason = 'no_show_grupo'),
        'reembolsados', COUNT(*) FILTER (WHERE payment_status = 'refunded')
      ) FROM base
    ),
    'community', (
      SELECT jsonb_build_object(
        'grupos', (
          SELECT COALESCE(jsonb_agg(jsonb_build_object(
            'pais', pais, 'activos', activos, 'nuevos', nuevos) ORDER BY activos DESC), '[]'::jsonb)
          FROM (
            SELECT COALESCE(g.country, 'México') AS pais,
                   COUNT(*) FILTER (WHERE g.is_active) AS activos,
                   COUNT(*) FILTER (WHERE (g.created_at AT TIME ZONE 'America/Mexico_City')::date
                                    BETWEEN v_from AND v_to) AS nuevos
            FROM groups g
            WHERE (v_ctry IS NULL OR normalize_state_name(COALESCE(g.country, 'México')) = v_ctry)
              AND (v_state IS NULL OR normalize_state_name(g.state) = v_state)
            GROUP BY COALESCE(g.country, 'México')
          ) t
        ),
        'talentos', (
          SELECT COALESCE(jsonb_agg(jsonb_build_object(
            'pais', pais, 'activos', activos, 'nuevos', nuevos) ORDER BY activos DESC), '[]'::jsonb)
          FROM (
            SELECT COALESCE(p.country, 'México') AS pais,
                   COUNT(*) AS activos,
                   COUNT(*) FILTER (WHERE (p.created_at AT TIME ZONE 'America/Mexico_City')::date
                                    BETWEEN v_from AND v_to) AS nuevos
            FROM profiles p
            WHERE p.role = 'talent'
              AND (v_ctry IS NULL OR normalize_state_name(COALESCE(p.country, 'México')) = v_ctry)
            GROUP BY COALESCE(p.country, 'México')
          ) t
        ),
        'nuevos_registros', (
          SELECT COUNT(*) FROM profiles p
          WHERE (p.created_at AT TIME ZONE 'America/Mexico_City')::date BETWEEN v_from AND v_to
            AND (v_ctry IS NULL OR normalize_state_name(COALESCE(p.country, 'México')) = v_ctry)
        )
      )
    ),
    'trend', COALESCE((
      SELECT jsonb_agg(jsonb_build_object('mes', mes, 'moneda', moneda, 'total', total) ORDER BY mes)
      FROM tendencia
    ), '[]'::jsonb)
  ) INTO v_result;

  RETURN v_result;
END;
$$;

GRANT EXECUTE ON FUNCTION public.admin_reports_dashboard(DATE, DATE, TEXT, TEXT, TEXT) TO authenticated;

-- ════════════════════════════════════════════════════════════
-- 2. group_performance_dashboard — SOLO su grupo (token)
-- ════════════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION public.group_performance_dashboard(
  p_from DATE DEFAULT NULL,
  p_to   DATE DEFAULT NULL
)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_group_id UUID;
  v_from     DATE := COALESCE(p_from, '2000-01-01');
  v_to       DATE := COALESCE(p_to, (NOW() AT TIME ZONE 'America/Mexico_City')::date);
  v_result   JSONB;
BEGIN
  SELECT id INTO v_group_id FROM groups WHERE owner_id = auth.uid() LIMIT 1;
  IF v_group_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'group_not_found');
  END IF;

  WITH base AS (
    SELECT r.*,
           COALESCE(r.currency_code, 'MXN') AS moneda,
           COALESCE(r.group_earnings, r.base_price,
                    ROUND(COALESCE(r.total_price, 0) / 1.20, 2)) AS tu_ganancia
    FROM reservations r
    WHERE r.group_id = v_group_id
      AND (r.created_at AT TIME ZONE 'America/Mexico_City')::date BETWEEN v_from AND v_to
  ),
  pagadas AS (
    SELECT * FROM base WHERE payment_status IN ('paid', 'fully_paid', 'deposit_paid')
  )
  SELECT jsonb_build_object(
    'ok', true,
    'from', v_from, 'to', v_to,
    'rating', (SELECT jsonb_build_object(
        'promedio', COALESCE(g.rating, 0),
        'resenas',  COALESCE(g.total_reviews, 0))
      FROM groups g WHERE g.id = v_group_id),
    'events', (SELECT jsonb_build_object(
        'realizados',   COUNT(*) FILTER (WHERE status = 'completed'),
        'proximos',     COUNT(*) FILTER (WHERE status IN ('accepted','confirmed')
                                          AND event_date >= (NOW() AT TIME ZONE 'America/Mexico_City')::date),
        'cancelados',       COUNT(*) FILTER (WHERE status = 'cancelled'),
        'cancel_tuyos',     COUNT(*) FILTER (WHERE status = 'cancelled' AND cancelled_by = 'group'),
        'cancel_cliente',   COUNT(*) FILTER (WHERE status = 'cancelled' AND cancelled_by = 'client'),
        'no_shows',         COUNT(*) FILTER (WHERE cancel_reason = 'no_show_grupo')
      ) FROM base),
    'money', COALESCE((
      SELECT jsonb_agg(jsonb_build_object(
        'moneda',    moneda,
        'total',     SUM(tu_ganancia),
        'pendiente', COALESCE(SUM(tu_ganancia) FILTER (WHERE payout_status = 'held'), 0),
        'pagado',    COALESCE(SUM(tu_ganancia) FILTER (WHERE payout_status = 'released'), 0)
      ) ORDER BY moneda)
      FROM pagadas GROUP BY moneda
    ), '[]'::jsonb),
    'cities', COALESCE((
      SELECT jsonb_agg(jsonb_build_object('ciudad', ciudad, 'eventos', n) ORDER BY n DESC)
      FROM (
        SELECT COALESCE(NULLIF(TRIM(p2.event_city), ''), 'Sin ciudad') AS ciudad, COUNT(*) AS n
        FROM pagadas p2 WHERE p2.status = 'completed'
        GROUP BY 1 ORDER BY 2 DESC LIMIT 8
      ) t
    ), '[]'::jsonb),
    'trend', COALESCE((
      SELECT jsonb_agg(jsonb_build_object('mes', mes, 'total', total) ORDER BY mes)
      FROM (
        SELECT to_char(date_trunc('month', (r.created_at AT TIME ZONE 'America/Mexico_City')), 'YYYY-MM') AS mes,
               SUM(COALESCE(r.group_earnings, r.base_price, ROUND(COALESCE(r.total_price,0)/1.20,2))) AS total
        FROM reservations r
        WHERE r.group_id = v_group_id
          AND r.payment_status IN ('paid','fully_paid','deposit_paid')
          AND (r.created_at AT TIME ZONE 'America/Mexico_City')::date
              >= (date_trunc('month', v_to::timestamp) - INTERVAL '5 months')::date
        GROUP BY 1 ORDER BY 1
      ) t
    ), '[]'::jsonb),
    'payments', COALESCE((
      SELECT jsonb_agg(item ORDER BY fecha DESC) FROM (
        -- Retiros
        SELECT pr.created_at AS fecha, jsonb_build_object(
          'tipo', 'retiro', 'label', 'Retiro',
          'amount', pr.amount, 'fecha', pr.created_at,
          'estado', pr.status) AS item
        FROM payout_requests pr
        WHERE pr.group_id = v_group_id
        UNION ALL
        -- Eventos pagados (retenidos o liberados)
        SELECT b.created_at, jsonb_build_object(
          'tipo', 'evento',
          'label', COALESCE('Evento ' || NULLIF(b.folio, ''), 'Evento'),
          'amount', b.tu_ganancia, 'fecha', b.created_at,
          'estado', COALESCE(b.payout_status, 'held'))
        FROM pagadas b
        ORDER BY fecha DESC LIMIT 6
      ) t
    ), '[]'::jsonb),
    'reviews', COALESCE((
      SELECT jsonb_agg(jsonb_build_object(
        'rating', rv.rating, 'comment', rv.comment, 'fecha', rv.created_at,
        'cliente', COALESCE(SPLIT_PART(p.full_name, ' ', 1), 'Cliente'))
        ORDER BY rv.created_at DESC)
      FROM (
        SELECT * FROM reviews
        WHERE group_id = v_group_id AND comment IS NOT NULL AND TRIM(comment) <> ''
        ORDER BY created_at DESC LIMIT 3
      ) rv
      LEFT JOIN profiles p ON p.id = rv.client_id
    ), '[]'::jsonb)
  ) INTO v_result FROM (SELECT 1) x;

  RETURN v_result;
END;
$$;

GRANT EXECUTE ON FUNCTION public.group_performance_dashboard(DATE, DATE) TO authenticated;

-- ════════════════════════════════════════════════════════════
-- 3. Tops por país/estado (Estadísticas → Inteligencia)
-- ════════════════════════════════════════════════════════════
DROP FUNCTION IF EXISTS public.get_top_groups_earnings(INT);
CREATE OR REPLACE FUNCTION public.get_top_groups_earnings(
  p_limit   INT  DEFAULT 5,
  p_country TEXT DEFAULT NULL,
  p_state   TEXT DEFAULT NULL
)
RETURNS TABLE(group_name TEXT, group_state TEXT, group_country TEXT,
              total_earnings NUMERIC, event_count BIGINT)
LANGUAGE sql SECURITY DEFINER SET search_path = public AS $$
  SELECT
    g.name,
    g.state,
    COALESCE(g.country, 'México'),
    COALESCE(SUM(r.group_earnings), 0) AS total_earnings,
    COUNT(r.id)                        AS event_count
  FROM groups g
  LEFT JOIN reservations r
    ON r.group_id = g.id AND r.status = 'completed'
  WHERE (p_country IS NULL OR normalize_state_name(COALESCE(g.country, 'México')) = normalize_state_name(p_country))
    AND (p_state   IS NULL OR normalize_state_name(g.state) = normalize_state_name(p_state))
  GROUP BY g.id, g.name, g.state, g.country
  ORDER BY total_earnings DESC
  LIMIT p_limit;
$$;

GRANT EXECUTE ON FUNCTION public.get_top_groups_earnings(INT, TEXT, TEXT) TO authenticated;

CREATE OR REPLACE FUNCTION public.get_top_groups_rating(
  p_limit   INT  DEFAULT 5,
  p_country TEXT DEFAULT NULL,
  p_state   TEXT DEFAULT NULL
)
RETURNS TABLE(group_name TEXT, group_state TEXT, group_country TEXT,
              rating NUMERIC, total_reviews INT)
LANGUAGE sql SECURITY DEFINER SET search_path = public AS $$
  SELECT
    g.name,
    g.state,
    COALESCE(g.country, 'México'),
    COALESCE(g.rating, 0),
    COALESCE(g.total_reviews, 0)
  FROM groups g
  WHERE g.is_active = true
    AND COALESCE(g.total_reviews, 0) > 0
    AND (p_country IS NULL OR normalize_state_name(COALESCE(g.country, 'México')) = normalize_state_name(p_country))
    AND (p_state   IS NULL OR normalize_state_name(g.state) = normalize_state_name(p_state))
  ORDER BY g.rating DESC, g.total_reviews DESC
  LIMIT p_limit;
$$;

GRANT EXECUTE ON FUNCTION public.get_top_groups_rating(INT, TEXT, TEXT) TO authenticated;

COMMIT;

-- ── VERIFICACIÓN ──────────────────────────────────────────────────────────────
SELECT proname FROM pg_proc WHERE proname IN
  ('admin_reports_dashboard', 'group_performance_dashboard',
   'get_top_groups_earnings', 'get_top_groups_rating');
-- Esperado: 4 filas

SELECT COUNT(*) AS versiones_top_earnings  -- Esperado: 1 (solo la de 3 args)
FROM pg_proc WHERE proname = 'get_top_groups_earnings';

SELECT '504_reports_dashboards.sql ejecutado ✅' AS status;
