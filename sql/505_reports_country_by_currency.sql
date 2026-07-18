-- ============================================================
-- sql/505_reports_country_by_currency.sql
-- 🌎 FIX Reportes: con filtro 🇺🇸/🇨🇦 no salían ingresos (2026-07-18)
--
--  Causa: el país de cada cobro se tomaba SOLO de groups.country.
--  Cobros en USD/CAD de grupos sin país guardado (o grupo borrado)
--  caían en 'México' por defecto → el filtro de EE.UU./Canadá los
--  dejaba fuera.
--
--  Fix: el país del cobro se infiere con doble fuente:
--    1) groups.country si existe;
--    2) si no, por la MONEDA: USD → Estados Unidos · CAD → Canadá ·
--       resto → México.
--  (Solo cambia el WHERE de admin_reports_dashboard — mismas fórmulas.)
-- ============================================================

BEGIN;

CREATE OR REPLACE FUNCTION public.admin_reports_dashboard(
  p_from    DATE DEFAULT NULL,
  p_to      DATE DEFAULT NULL,
  p_country TEXT DEFAULT NULL,
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
           -- 🌎 País del cobro: groups.country o, si falta, por la moneda
           normalize_state_name(COALESCE(g.country,
             CASE COALESCE(r.currency_code, 'MXN')
               WHEN 'USD' THEN 'Estados Unidos'
               WHEN 'CAD' THEN 'Canadá'
               ELSE 'México'
             END))                                                 AS pais_norm,
           (COALESCE(r.total_price, 0) + COALESCE(r.msi_fee_amount, 0)) AS cobrado,
           COALESCE(r.group_earnings, r.base_price,
                    ROUND(COALESCE(r.total_price, 0) / 1.20, 2))   AS de_grupos,
           (COALESCE(r.service_fee_amount, r.commission_amount,
                     ROUND(COALESCE(r.total_price, 0) - COALESCE(r.group_earnings, r.base_price, ROUND(COALESCE(r.total_price,0)/1.20,2)), 2))
            + COALESCE(r.msi_fee_amount, 0))                       AS comision_bruta
    FROM reservations r
    LEFT JOIN groups g ON g.id = r.group_id
    WHERE (r.created_at AT TIME ZONE 'America/Mexico_City')::date BETWEEN v_from AND v_to
      AND (v_state IS NULL OR normalize_state_name(g.state) = v_state)
      AND (v_city  IS NULL OR normalize_city_name(COALESCE(r.event_city, g.city)) = v_city)
  ),
  base_pais AS (
    SELECT * FROM base WHERE (v_ctry IS NULL OR pais_norm = v_ctry)
  ),
  pagadas AS (
    SELECT * FROM base_pais WHERE payment_status IN ('paid', 'fully_paid', 'deposit_paid')
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
    FROM base_pais b WHERE b.payment_status = 'refunded'
    GROUP BY COALESCE(b.moneda, 'MXN')
  ),
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
      AND (v_ctry IS NULL OR normalize_state_name(COALESCE(g.country,
             CASE COALESCE(r.currency_code, 'MXN')
               WHEN 'USD' THEN 'Estados Unidos'
               WHEN 'CAD' THEN 'Canadá'
               ELSE 'México'
             END)) = v_ctry)
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
      ) FROM base_pais
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

COMMIT;

-- ── VERIFICACIÓN ──────────────────────────────────────────────────────────────
SELECT prosrc LIKE '%pais_norm%' AS pais_por_moneda
FROM pg_proc WHERE proname = 'admin_reports_dashboard';
-- Esperado: true

-- 🧪 Diagnóstico: ¿de qué país/moneda son tus cobros? (como admin)
-- SELECT COALESCE(g.country, 'SIN PAÍS') AS pais_grupo,
--        COALESCE(r.currency_code, 'MXN') AS moneda, COUNT(*), SUM(r.total_price)
-- FROM reservations r LEFT JOIN groups g ON g.id = r.group_id
-- WHERE r.payment_status IN ('paid','fully_paid','deposit_paid')
-- GROUP BY 1, 2 ORDER BY 1, 2;

SELECT '505_reports_country_by_currency.sql ejecutado ✅' AS status;
