-- 203b_booking_v2.sql
-- create_booking_with_event v2: MSI atómico + payment_mode + flow_version.
-- Correr DESPUÉS de que flow_version column exista.

DO $$
DECLARE r RECORD;
BEGIN
  FOR r IN
    SELECT p.oid::regprocedure::TEXT AS sig
    FROM   pg_proc p
    JOIN   pg_namespace n ON n.oid = p.pronamespace
    WHERE  p.proname = 'create_booking_with_event'
      AND  n.nspname = 'public'
  LOOP
    EXECUTE 'DROP FUNCTION IF EXISTS ' || r.sig || ' CASCADE';
    RAISE NOTICE 'Dropped: %', r.sig;
  END LOOP;
END;
$$;

CREATE FUNCTION public.create_booking_with_event(
  p_client_id                  UUID,
  p_group_id                   UUID,
  p_package_id                 UUID,
  p_event_date                 DATE,
  p_event_time                 TIME,
  p_address                    TEXT,
  p_total_price                NUMERIC,
  p_notes                      TEXT    DEFAULT NULL,
  p_break_type                 TEXT    DEFAULT NULL,
  p_base_price                 NUMERIC DEFAULT NULL,
  p_installment_plan           TEXT    DEFAULT NULL,
  p_installment_months         INT     DEFAULT NULL,
  p_installment_monthly_amount NUMERIC DEFAULT NULL,
  p_payment_mode               TEXT    DEFAULT 'full'
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_event_id       UUID;
  v_reservation_id UUID;
  v_flow_version   TEXT;
BEGIN
  v_flow_version := CASE
    WHEN p_payment_mode = 'full' THEN 'full_payment_v2'
    ELSE 'legacy'
  END;

  INSERT INTO public.events (client_id, event_date, event_time, address, status)
  VALUES (p_client_id, p_event_date, p_event_time, p_address, 'active')
  RETURNING id INTO v_event_id;

  INSERT INTO public.reservations (
    event_id, group_id, package_id, client_id,
    event_date, event_time, address, notes, break_type,
    total_price, base_price, status,
    payment_mode, flow_version,
    installment_plan, installment_months, installment_monthly_amount
  )
  VALUES (
    v_event_id, p_group_id, p_package_id, p_client_id,
    p_event_date, p_event_time, p_address, p_notes, p_break_type,
    p_total_price, p_base_price, 'pending_payment',
    p_payment_mode, v_flow_version,
    p_installment_plan, p_installment_months, p_installment_monthly_amount
  )
  RETURNING id INTO v_reservation_id;

  RAISE NOTICE '[CREATE_BOOKING] reservation=% mode=% msi=%',
    v_reservation_id, p_payment_mode, COALESCE(p_installment_plan, '1_pago');

  RETURN jsonb_build_object(
    'reservation_id', v_reservation_id,
    'event_id',       v_event_id
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.create_booking_with_event TO authenticated;

-- Índices para monitoreo
CREATE INDEX IF NOT EXISTS idx_res_payment_failed
  ON reservations(payment_status) WHERE payment_status = 'payment_failed';

CREATE INDEX IF NOT EXISTS idx_res_pending_payment
  ON reservations(payment_status) WHERE payment_status = 'pending_payment';

SELECT 'create_booking_with_event v2 ✅' AS status;
