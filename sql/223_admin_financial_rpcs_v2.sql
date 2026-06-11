-- ============================================================
-- sql/223_admin_financial_rpcs_v2.sql
--
-- Reescribe get_admin_financial_overview y
-- get_admin_event_financials para:
--   1. Consultar reservations directamente (no event_financial_summary)
--      → todas las pagadas, sin importar si el evento ya ocurrió.
--   2. Usar service_fee_amount (columna que el trigger sí llena)
--      en lugar de commission_amount (que queda en 0 para reservas
--      creadas desde QuotePaymentScreen).
--   3. total_facturado = total_price + msi_fee_amount
--      (monto real cobrado al cliente vía Stripe).
--
-- Columnas relevantes en reservations:
--   total_price         — precio base del grupo (sin MSI fee)
--   service_fee_amount  — tarifa 10% (seteada por trigger set_reservation_financials)
--   msi_fee_amount      — cargo MSI adicional (seteado por create-payment-intent)
--   group_earnings      — lo que recibe el grupo = total_price - service_fee_amount
--
-- Resultado correcto para el pago de prueba:
--   total_facturado = 9,000 + 270 = $9,270
--   ganancia_bruta  = 900   + 270 = $1,170
--   stripe_fees     ≈ 9,270 × 3.6% + $3 ≈ $336.72
--   ganancia_neta   ≈ $833.28
--   artistas_payout = $8,100
--
-- Ejecutar en: Supabase Dashboard → SQL Editor
-- ============================================================

-- ── 1. get_admin_financial_overview ──────────────────────────────────────────

CREATE OR REPLACE FUNCTION public.get_admin_financial_overview(
  p_days INT DEFAULT NULL
)
RETURNS JSON
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_result JSON;
  v_from   TIMESTAMPTZ;
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM profiles WHERE id = auth.uid() AND role = 'admin'
  ) THEN
    RAISE EXCEPTION 'Unauthorized';
  END IF;

  IF p_days IS NOT NULL THEN
    v_from := NOW() - (p_days || ' days')::INTERVAL;
  END IF;

  SELECT json_build_object(
    -- Monto real cobrado al cliente (base + MSI fee)
    'total_facturado',
      COALESCE(SUM(r.total_price + COALESCE(r.msi_fee_amount, 0)), 0),

    -- Ganancia de la plataforma: tarifa servicio + MSI fee
    -- service_fee_amount es el 10% (seteado por trigger).
    -- Fallback a commission_amount o cálculo si fuera nulo.
    'ganancia_bruta',
      COALESCE(SUM(
        COALESCE(r.service_fee_amount,
                 r.commission_amount,
                 ROUND(r.total_price * 0.10, 2))
        + COALESCE(r.msi_fee_amount, 0)
      ), 0),

    -- Estimación comisión Stripe: 3.6% del cobro total + $3 MXN
    'stripe_fees',
      COALESCE(SUM(
        ROUND((r.total_price + COALESCE(r.msi_fee_amount, 0)) * 0.036 + 3, 2)
      ), 0),

    'mercadopago_fees', 0,

    -- Ganancia neta = bruta - stripe
    'ganancia_neta',
      COALESCE(SUM(
        COALESCE(r.service_fee_amount,
                 r.commission_amount,
                 ROUND(r.total_price * 0.10, 2))
        + COALESCE(r.msi_fee_amount, 0)
        - ROUND((r.total_price + COALESCE(r.msi_fee_amount, 0)) * 0.036 + 3, 2)
      ), 0),

    -- Pago al grupo
    'artistas_payout',
      COALESCE(SUM(
        COALESCE(r.group_earnings,
                 r.base_price,
                 ROUND(r.total_price * 0.90, 2))
      ), 0),

    'event_count', COUNT(*)
  ) INTO v_result
  FROM reservations r
  WHERE r.payment_status IN ('paid', 'fully_paid', 'deposit_paid')
    AND (v_from IS NULL OR r.created_at >= v_from);

  RETURN v_result;
END;
$$;

GRANT EXECUTE ON FUNCTION public.get_admin_financial_overview TO authenticated;

-- ── 2. get_admin_event_financials ─────────────────────────────────────────────

CREATE OR REPLACE FUNCTION public.get_admin_event_financials(
  p_days  INT DEFAULT 30,
  p_limit INT DEFAULT 50
)
RETURNS TABLE (
  reservation_id      UUID,
  event_date          DATE,
  group_name          TEXT,
  event_total         NUMERIC,
  platform_fee        NUMERIC,
  stripe_fee          NUMERIC,
  mercadopago_fee     NUMERIC,
  net_platform_profit NUMERIC,
  artists_payout      NUMERIC,
  created_at          TIMESTAMPTZ
)
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM profiles WHERE id = auth.uid() AND role = 'admin'
  ) THEN
    RAISE EXCEPTION 'Unauthorized';
  END IF;

  RETURN QUERY
  SELECT
    r.id                                                       AS reservation_id,
    r.event_date,
    g.name                                                     AS group_name,

    -- Monto real cobrado
    (r.total_price + COALESCE(r.msi_fee_amount, 0))           AS event_total,

    -- Tarifa plataforma = service_fee + MSI fee
    (COALESCE(r.service_fee_amount,
              r.commission_amount,
              ROUND(r.total_price * 0.10, 2))
     + COALESCE(r.msi_fee_amount, 0))                         AS platform_fee,

    -- Stripe estimado
    ROUND((r.total_price + COALESCE(r.msi_fee_amount, 0)) * 0.036 + 3, 2)
                                                               AS stripe_fee,

    0::NUMERIC                                                 AS mercadopago_fee,

    -- Ganancia neta plataforma
    (COALESCE(r.service_fee_amount,
              r.commission_amount,
              ROUND(r.total_price * 0.10, 2))
     + COALESCE(r.msi_fee_amount, 0)
     - ROUND((r.total_price + COALESCE(r.msi_fee_amount, 0)) * 0.036 + 3, 2))
                                                               AS net_platform_profit,

    COALESCE(r.group_earnings,
             r.base_price,
             ROUND(r.total_price * 0.90, 2))                   AS artists_payout,

    r.created_at
  FROM reservations r
  LEFT JOIN groups g ON g.id = r.group_id
  WHERE r.payment_status IN ('paid', 'fully_paid', 'deposit_paid')
    AND (
      p_days IS NULL
      OR r.created_at >= NOW() - (p_days || ' days')::INTERVAL
    )
  ORDER BY r.created_at DESC
  LIMIT p_limit;
END;
$$;

GRANT EXECUTE ON FUNCTION public.get_admin_event_financials TO authenticated;

SELECT '223_admin_financial_rpcs_v2.sql ejecutado ✅' AS status;
