-- ============================================================
-- sql/508_group_dashboard_v3.sql
-- 📈 group_performance_dashboard v3 (cierre de fase 2026-07-18)
--
--  Agrega lo que el PDF completo del grupo necesita — SIN duplicar
--  fórmulas (el PDF consume ESTE RPC):
--   · group: nombre, país, estado, ciudad
--   · stars: distribución de estrellas 1..5
--   · completion_rate: realizados / (realizados + cancelados + no-shows)
--   · payments: retiros ahora salen de withdrawals (con referencia de
--     transferencia y cuenta ENMASCARADA) y los eventos incluyen su
--     calificación cuando existe
--
--  El grupo sigue sin ver NADA de Daricefy: solo group_earnings
--  ("tu ganancia"), jamás total del cliente ni comisiones ni fees.
-- ============================================================

BEGIN;

CREATE OR REPLACE FUNCTION public.group_performance_dashboard(
  p_from DATE DEFAULT NULL,
  p_to   DATE DEFAULT NULL
)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_group_id UUID;
  v_owner    UUID := auth.uid();
  v_from     DATE := COALESCE(p_from, '2000-01-01');
  v_to       DATE := COALESCE(p_to, (NOW() AT TIME ZONE 'America/Mexico_City')::date);
  v_result   JSONB;
BEGIN
  SELECT id INTO v_group_id FROM groups WHERE owner_id = v_owner LIMIT 1;
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
  ),
  ev_counts AS (
    SELECT
      COUNT(*) FILTER (WHERE status = 'completed')                            AS realizados,
      COUNT(*) FILTER (WHERE status IN ('accepted','confirmed')
                        AND event_date >= (NOW() AT TIME ZONE 'America/Mexico_City')::date) AS proximos,
      COUNT(*) FILTER (WHERE status = 'cancelled')                            AS cancelados,
      COUNT(*) FILTER (WHERE status = 'cancelled' AND cancelled_by = 'group') AS cancel_tuyos,
      COUNT(*) FILTER (WHERE status = 'cancelled' AND cancelled_by = 'client') AS cancel_cliente,
      COUNT(*) FILTER (WHERE cancel_reason = 'no_show_grupo')                 AS no_shows
    FROM base
  )
  SELECT jsonb_build_object(
    'ok', true,
    'from', v_from, 'to', v_to,
    'group', (SELECT jsonb_build_object(
        'name', g.name, 'country', g.country, 'state', g.state, 'city', g.city)
      FROM groups g WHERE g.id = v_group_id),
    'rating', (SELECT jsonb_build_object(
        'promedio', COALESCE(g.rating, 0),
        'resenas',  COALESCE(g.total_reviews, 0))
      FROM groups g WHERE g.id = v_group_id),
    -- ⭐ Distribución de estrellas (todas las reseñas del grupo)
    'stars', COALESCE((
      SELECT jsonb_object_agg(t.estrella, t.n) FROM (
        SELECT rv.rating::TEXT AS estrella, COUNT(*) AS n
        FROM reviews rv WHERE rv.group_id = v_group_id
        GROUP BY rv.rating
      ) t
    ), '{}'::jsonb),
    'events', (SELECT jsonb_build_object(
        'realizados',     realizados,
        'proximos',       proximos,
        'cancelados',     cancelados,
        'cancel_tuyos',   cancel_tuyos,
        'cancel_cliente', cancel_cliente,
        'no_shows',       no_shows,
        -- Tasa de finalización: realizados / (realizados + cancelados + no-shows)
        'completion_rate', CASE
          WHEN (realizados + cancelados + no_shows) > 0
          THEN ROUND(realizados::NUMERIC / (realizados + cancelados + no_shows) * 100)
          ELSE NULL END
      ) FROM ev_counts),
    'money', COALESCE((
      SELECT jsonb_agg(jsonb_build_object(
        'moneda',    m.moneda,
        'total',     m.total,
        'pendiente', m.pendiente,
        'pagado',    m.pagado
      ) ORDER BY m.moneda)
      FROM (
        SELECT moneda,
               SUM(tu_ganancia) AS total,
               COALESCE(SUM(tu_ganancia) FILTER (WHERE payout_status = 'held'), 0)     AS pendiente,
               COALESCE(SUM(tu_ganancia) FILTER (WHERE payout_status = 'released'), 0) AS pagado
        FROM pagadas
        GROUP BY moneda
      ) m
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
    -- 🧾 Historial: retiros desde withdrawals (referencia + cuenta ENMASCARADA)
    -- y eventos con su calificación cuando existe
    'payments', COALESCE((
      SELECT jsonb_agg(item ORDER BY fecha DESC) FROM (
        SELECT w.created_at AS fecha, jsonb_build_object(
          'tipo', 'retiro', 'label', 'Retiro',
          'amount', w.amount, 'fecha', w.created_at,
          'estado', w.status,
          'ref',    w.transfer_reference,
          'cuenta', CASE WHEN w.bank_clabe IS NOT NULL
                         THEN '****' || RIGHT(w.bank_clabe, 4) ELSE NULL END) AS item
        FROM withdrawals w
        WHERE w.user_id = v_owner
          AND (w.created_at AT TIME ZONE 'America/Mexico_City')::date BETWEEN v_from AND v_to
        UNION ALL
        SELECT b.created_at, jsonb_build_object(
          'tipo', 'evento',
          'label', COALESCE('Evento ' || NULLIF(b.folio, ''), 'Evento'),
          'amount', b.tu_ganancia, 'fecha', b.created_at,
          'estado', COALESCE(b.payout_status, 'held'),
          'rating', rv.rating)
        FROM pagadas b
        LEFT JOIN reviews rv ON rv.reservation_id = b.id
        ORDER BY fecha DESC LIMIT 12
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

COMMIT;

-- ── VERIFICACIÓN ──────────────────────────────────────────────────────────────
SELECT prosrc LIKE '%completion_rate%' AS v3_aplicado
FROM pg_proc WHERE proname = 'group_performance_dashboard';
-- Esperado: true

SELECT '508_group_dashboard_v3.sql ejecutado ✅' AS status;
