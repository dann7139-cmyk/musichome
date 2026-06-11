-- ============================================================
-- sql/230_fix_financial_rpc_auth.sql
--
-- El RPC get_admin_financial_overview lanzaba EXCEPTION cuando
-- auth.uid() era NULL (contexto SECURITY DEFINER + JWT edge case),
-- haciendo que el cliente JS cayera al fallback JS.
-- Solución: el check de admin no lanza excepción — retorna vacío.
-- ============================================================

CREATE OR REPLACE FUNCTION public.get_admin_financial_overview(
  p_days INT DEFAULT NULL
)
RETURNS JSON
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_result JSON;
  v_from   TIMESTAMPTZ;
BEGIN
  -- Check admin (no lanza excepción — retorna datos vacíos si no es admin)
  IF auth.uid() IS NULL OR NOT EXISTS (
    SELECT 1 FROM profiles WHERE id = auth.uid() AND role = 'admin'
  ) THEN
    RETURN json_build_object(
      'total_facturado', 0, 'ganancia_bruta', 0, 'stripe_fees', 0,
      'mercadopago_fees', 0, 'ganancia_neta', 0, 'artistas_payout', 0,
      'event_count', 0
    );
  END IF;

  IF p_days IS NOT NULL THEN
    v_from := NOW() - (p_days || ' days')::INTERVAL;
  END IF;

  SELECT json_build_object(
    'total_facturado',
      COALESCE(SUM(r.total_price + COALESCE(r.msi_fee_amount, 0)), 0),
    'ganancia_bruta',
      COALESCE(SUM(
        COALESCE(r.service_fee_amount, r.commission_amount, ROUND(r.total_price * 0.10, 2))
        + COALESCE(r.msi_fee_amount, 0)
      ), 0),
    'stripe_fees',
      COALESCE(SUM(
        COALESCE(r.stripe_fee_amount,
          ROUND((r.total_price + COALESCE(r.msi_fee_amount, 0)) * 0.036 + 3, 2))
      ), 0),
    'mercadopago_fees', 0,
    'ganancia_neta',
      COALESCE(SUM(
        COALESCE(r.service_fee_amount, r.commission_amount, ROUND(r.total_price * 0.10, 2))
        + COALESCE(r.msi_fee_amount, 0)
        - COALESCE(r.stripe_fee_amount,
            ROUND((r.total_price + COALESCE(r.msi_fee_amount, 0)) * 0.036 + 3, 2))
      ), 0),
    'artistas_payout',
      COALESCE(SUM(
        COALESCE(r.group_earnings, r.base_price, ROUND(r.total_price * 0.90, 2))
      ), 0),
    'event_count', COUNT(*)
  ) INTO v_result
  FROM reservations r
  WHERE r.payment_status IN ('paid','fully_paid','deposit_paid')
    AND (v_from IS NULL OR r.created_at >= v_from);

  RETURN v_result;
END;
$$;
GRANT EXECUTE ON FUNCTION public.get_admin_financial_overview TO authenticated;

SELECT '230_fix_financial_rpc_auth.sql ejecutado ✅' AS status;
