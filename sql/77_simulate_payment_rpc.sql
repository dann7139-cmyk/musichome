-- ════════════════════════════════════════════════════════════════════
-- 77_simulate_payment_rpc.sql
-- RPC para simular pago en desarrollo/pruebas (sin MercadoPago).
-- NO usar en producción.
-- ════════════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION public.simulate_deposit_paid(p_reservation_id UUID)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  UPDATE public.reservations
  SET
    payment_status = 'deposit_paid',
    status         = CASE WHEN status = 'pending' THEN 'confirmed' ELSE status END
  WHERE id = p_reservation_id
    AND client_id = auth.uid();

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_found');
  END IF;

  RETURN jsonb_build_object('ok', true);
END;
$$;

GRANT EXECUTE ON FUNCTION public.simulate_deposit_paid(UUID) TO authenticated;

SELECT '77_simulate_payment_rpc: simulate_deposit_paid ✅' AS status;
