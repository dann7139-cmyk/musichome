-- ============================================================
-- sql/234_fix_event_financials_rpc.sql
--
-- get_admin_event_financials tenía RAISE EXCEPTION 'Unauthorized'
-- → el cliente JS caía al fallback y los números no se actualizaban.
-- Además usaba stripe fee estimado en vez del real (stripe_fee_amount).
-- ============================================================

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
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
BEGIN
  -- Retorna vacío en vez de lanzar excepción (el cliente JS lo maneja sin error)
  IF auth.uid() IS NULL OR NOT EXISTS (
    SELECT 1 FROM profiles WHERE id = auth.uid() AND role = 'admin'
  ) THEN
    RETURN;
  END IF;

  RETURN QUERY
  SELECT
    r.id,
    r.event_date,
    g.name::TEXT,

    -- Total cobrado al cliente (base + MSI)
    (r.total_price + COALESCE(r.msi_fee_amount, 0)),

    -- Comisión plataforma: 10% base + MSI fee íntegro (Opción 1)
    (COALESCE(r.service_fee_amount, ROUND(r.total_price * 0.10, 2))
     + COALESCE(r.msi_fee_amount, 0)),

    -- Fee Stripe: real si está guardado, estimado si no
    COALESCE(r.stripe_fee_amount,
      ROUND((r.total_price + COALESCE(r.msi_fee_amount, 0)) * 0.036 + 3, 2)),

    0::NUMERIC,

    -- Ganancia neta = platform_fee − stripe_fee
    (COALESCE(r.service_fee_amount, ROUND(r.total_price * 0.10, 2))
     + COALESCE(r.msi_fee_amount, 0)
     - COALESCE(r.stripe_fee_amount,
         ROUND((r.total_price + COALESCE(r.msi_fee_amount, 0)) * 0.036 + 3, 2))),

    -- Lo que recibe el grupo (90% base, guardado en group_earnings)
    COALESCE(r.group_earnings, r.base_price, ROUND(r.total_price * 0.90, 2)),

    r.created_at

  FROM reservations r
  LEFT JOIN groups g ON g.id = r.group_id
  WHERE r.payment_status IN ('paid','fully_paid','deposit_paid')
    AND r.created_at >= NOW() - (p_days || ' days')::INTERVAL
  ORDER BY r.created_at DESC
  LIMIT p_limit;
END;
$$;
GRANT EXECUTE ON FUNCTION public.get_admin_event_financials TO authenticated;

SELECT '234_fix_event_financials_rpc.sql ejecutado ✅' AS status;
