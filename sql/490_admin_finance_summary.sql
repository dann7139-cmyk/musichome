-- ============================================================
-- sql/490_admin_finance_summary.sql
-- 📊 FUENTE ÚNICA DE VERDAD financiera (Fase 0.4, aprobada 2026-07-15).
--
-- UN RPC de SOLO LECTURA con las fórmulas canónicas. Dashboard y
-- Finanzas del admin leen de AQUÍ — mismos números en todas partes.
--
-- Criterios canónicos (definitivos):
--   • "Cobrado"  = reservas con payment_status IN (paid, fully_paid,
--     deposit_paid) — dinero realmente recibido (no por status).
--   • Total cobrado = total_price + msi_fee_amount.
--   • Dinero de grupos = group_earnings (fallback base_price, /1.20).
--   • Pendiente/pagado a grupos por payout_status (held / released).
--   • Reembolsos = automáticos (payment_status='refunded', total) +
--     manuales enviados (manual_refunds.status='sent', amount real).
--   • Comisión Daricefy (bruta) = service_fee_amount + msi_fee_amount
--     (modelo 20% vigente; fallback commission_amount).
--   • Fees de procesador: SOLO reales (stripe_fee_amount); los que no
--     existen se CUENTAN como no_capturados — jamás se estiman.
--   • Neto estimado = comisión bruta − fees reales.
--   • Fechas en HORARIO DE MÉXICO (created_at convertido a
--     America/Mexico_City antes de comparar contra el rango).
--   • Por moneda: MXN y USD (y futuras) SEPARADAS, nunca sumadas.
-- ============================================================

BEGIN;

CREATE OR REPLACE FUNCTION public.admin_finance_summary(
  p_from DATE DEFAULT NULL,   -- NULL = sin límite inferior
  p_to   DATE DEFAULT NULL    -- NULL = hoy (México)
)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_from   DATE := COALESCE(p_from, '2000-01-01');
  v_to     DATE := COALESCE(p_to, (NOW() AT TIME ZONE 'America/Mexico_City')::date);
  v_result JSONB;
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
    WHERE (r.created_at AT TIME ZONE 'America/Mexico_City')::date BETWEEN v_from AND v_to
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
    SELECT
      COALESCE(b.moneda, 'MXN') AS moneda,
      SUM(b.cobrado)            AS reembolsado_auto,
      COUNT(*)                  AS reembolsos_auto
    FROM base b
    WHERE b.payment_status = 'refunded'
    GROUP BY COALESCE(b.moneda, 'MXN')
  ),
  reembolsos_manuales AS (
    SELECT
      COALESCE(r.currency_code, 'MXN') AS moneda,
      SUM(mr.amount)                   AS reembolsado_manual,
      COUNT(*)                         AS reembolsos_manuales
    FROM manual_refunds mr
    JOIN reservations r ON r.id = mr.reservation_id
    WHERE mr.status = 'sent'
      AND (mr.created_at AT TIME ZONE 'America/Mexico_City')::date BETWEEN v_from AND v_to
    GROUP BY COALESCE(r.currency_code, 'MXN')
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
        'reembolsado_auto',    COALESCE(re.reembolsado_auto, 0),
        'reembolsos_auto',     COALESCE(re.reembolsos_auto, 0),
        'reembolsado_manual',  COALESCE(rm.reembolsado_manual, 0),
        'reembolsos_manuales', COALESCE(rm.reembolsos_manuales, 0)
      ) ORDER BY pm.moneda)
      FROM por_moneda pm
      LEFT JOIN reembolsos          re ON re.moneda = pm.moneda
      LEFT JOIN reembolsos_manuales rm ON rm.moneda = pm.moneda
    ), '[]'::jsonb),
    'counts', (
      SELECT jsonb_build_object(
        'total_reservas',   COUNT(*),
        'completadas',      COUNT(*) FILTER (WHERE status = 'completed'),
        'en_curso',         COUNT(*) FILTER (WHERE status = 'in_progress'),
        'canceladas',       COUNT(*) FILTER (WHERE status = 'cancelled'),
        'no_shows',         COUNT(*) FILTER (WHERE cancel_reason = 'no_show_grupo'),
        'reembolsadas',     COUNT(*) FILTER (WHERE payment_status = 'refunded')
      ) FROM base
    )
  ) INTO v_result;

  RETURN v_result;
END;
$$;

GRANT EXECUTE ON FUNCTION public.admin_finance_summary(DATE, DATE) TO authenticated;

COMMIT;

-- ── VERIFICACIÓN ──────────────────────────────────────────────────────────────
SELECT proname FROM pg_proc WHERE proname = 'admin_finance_summary';
-- Esperado: 1 fila

-- Prueba (como admin): últimos 90 días
-- SELECT admin_finance_summary((NOW() AT TIME ZONE 'America/Mexico_City')::date - 90, NULL);

SELECT '490_admin_finance_summary.sql ejecutado ✅' AS status;
