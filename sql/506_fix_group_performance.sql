-- ============================================================
-- sql/506_fix_group_performance.sql
-- 🐞 FIX "Mi desempeño" marcaba error al abrir (2026-07-18)
--
--  Causa: en sql/504, la sección 'money' anidaba agregados
--  (jsonb_agg con SUM adentro al mismo nivel) → Postgres:
--  "aggregate function calls cannot be nested".
--  Fix: pre-agregar por moneda en un subquery y luego armar el JSON.
--  Todo lo demás queda idéntico.
-- ============================================================

BEGIN;

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
    -- 💵 FIX: pre-agregar por moneda (antes: agregados anidados → error)
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
    'payments', COALESCE((
      SELECT jsonb_agg(item ORDER BY fecha DESC) FROM (
        SELECT pr.created_at AS fecha, jsonb_build_object(
          'tipo', 'retiro', 'label', 'Retiro',
          'amount', pr.amount, 'fecha', pr.created_at,
          'estado', pr.status) AS item
        FROM payout_requests pr
        WHERE pr.group_id = v_group_id
        UNION ALL
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

COMMIT;

-- ── VERIFICACIÓN ──────────────────────────────────────────────────────────────
-- Como DUEÑO de un grupo (no como admin):
-- SELECT group_performance_dashboard(NULL, NULL);
-- Esperado: JSON con ok:true (ya sin error de agregados anidados)

SELECT prosrc LIKE '%pre-agregar%' AS fix_aplicado
FROM pg_proc WHERE proname = 'group_performance_dashboard';
-- Esperado: true

SELECT '506_fix_group_performance.sql ejecutado ✅' AS status;
