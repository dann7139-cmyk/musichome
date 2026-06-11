-- ─────────────────────────────────────────────────────────────────────────────
-- 203_payment_flow_v2.sql
-- Pago único completo: correcciones de flujo, MSI atómico, estado payment_failed,
-- calculate_final_price completo, create_booking_with_event v2.
--
-- Requiere: 182, 183, 184a/b/c aplicados.
-- ─────────────────────────────────────────────────────────────────────────────

-- ── 1. flow_version en reservations ──────────────────────────────────────────
-- Permite distinguir reservas nuevas (full_payment_v2) de legado (deposit).

ALTER TABLE reservations
  ADD COLUMN IF NOT EXISTS flow_version TEXT DEFAULT 'legacy';

CREATE INDEX IF NOT EXISTS idx_res_flow_version ON reservations(flow_version);

-- Marcar reservas nuevas (payment_mode='full') que ya existen
UPDATE reservations
SET flow_version = 'full_payment_v2'
WHERE payment_mode = 'full' AND flow_version = 'legacy';

-- ── 2. Agregar payment_failed al constraint de payment_status ─────────────────
-- Se eliminan TODOS los constraints existentes y se recrea con valores completos.

DO $$
BEGIN
  ALTER TABLE reservations DROP CONSTRAINT IF EXISTS reservations_payment_status_check;
EXCEPTION WHEN OTHERS THEN NULL;
END;
$$;
DO $$
BEGIN
  ALTER TABLE reservations DROP CONSTRAINT IF EXISTS chk_payment_status;
EXCEPTION WHEN OTHERS THEN NULL;
END;
$$;
DO $$
BEGIN
  ALTER TABLE reservations DROP CONSTRAINT IF EXISTS chk_res_payment_status;
EXCEPTION WHEN OTHERS THEN NULL;
END;
$$;
DO $$
BEGIN
  ALTER TABLE reservations DROP CONSTRAINT IF EXISTS chk_payment_status_v2;
EXCEPTION WHEN OTHERS THEN NULL;
END;
$$;
DO $$
BEGIN
  ALTER TABLE reservations DROP CONSTRAINT IF EXISTS chk_payment_status_v3;
EXCEPTION WHEN OTHERS THEN NULL;
END;
$$;

ALTER TABLE reservations
  ADD CONSTRAINT chk_payment_status_v3 CHECK (
    payment_status IN (
      'unpaid', 'pending', 'pending_payment',
      'deposit_pending', 'deposit_paid', 'remaining_pending',
      'fully_paid', 'paid',
      'payment_failed', 'refunded', 'cancelled'
    )
  );

-- ── 3. calculate_final_price — acepta p_is_express y p_state ─────────────────
-- Antes solo tenía p_base_price y p_city.
-- BookingScreen pasa p_is_express y p_state pero el RPC los ignoraba →
-- PostgREST devolvía error → validación backend siempre fallaba → usaba
-- precio client-side sin verificación.

DROP FUNCTION IF EXISTS public.calculate_final_price(NUMERIC, TEXT);
DROP FUNCTION IF EXISTS public.calculate_final_price(NUMERIC, BOOLEAN, TEXT);

CREATE OR REPLACE FUNCTION public.calculate_final_price(
  p_base_price NUMERIC,
  p_is_express BOOLEAN DEFAULT FALSE,
  p_state      TEXT    DEFAULT NULL,
  p_city       TEXT    DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_rate        NUMERIC;
  v_commission  NUMERIC(12,2);
  v_final       NUMERIC(12,2);
  v_multiplier  NUMERIC := 1.0;
BEGIN
  IF p_base_price IS NULL OR p_base_price < 0 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_base_price');
  END IF;

  -- Comisión dinámica por tier de precio base
  v_rate       := public.get_commission_rate(p_base_price);   -- retorna 7, 8, 9 o 10
  v_commission := ROUND(p_base_price * v_rate / 100.0, 2);
  v_final      := p_base_price + v_commission;

  RAISE NOTICE '[CALCULATE_FINAL_PRICE] base=% rate=%% commission=% final=% express=% state=%',
    p_base_price, v_rate, v_commission, v_final, p_is_express, p_state;

  RETURN jsonb_build_object(
    'ok',               true,
    'base_price',       p_base_price,
    'commission_rate',  v_rate,
    'commission_amount', v_commission,
    'final_price',      v_final,
    'group_earnings',   p_base_price,
    'multiplier',       v_multiplier,
    'is_express',       COALESCE(p_is_express, false)
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.calculate_final_price(NUMERIC, BOOLEAN, TEXT, TEXT)
  TO authenticated, anon;

-- ── 4. create_booking_with_event v2 — MSI atómico + payment_mode + flow_version
-- Elimina TODAS las sobrecargas anteriores y crea UNA versión definitiva.
-- Backward compat: todos los params nuevos tienen DEFAULT NULL o DEFAULT 'full'.

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
  -- Flow version
  v_flow_version := CASE
    WHEN p_payment_mode = 'full' THEN 'full_payment_v2'
    ELSE 'legacy'
  END;

  -- Crear evento padre
  INSERT INTO public.events (client_id, event_date, event_time, address, status)
  VALUES (p_client_id, p_event_date, p_event_time, p_address, 'active')
  RETURNING id INTO v_event_id;

  -- Crear reserva (trigger calculate_commission / set_reservation_financials corre aquí)
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

  RAISE NOTICE '[CREATE_BOOKING] reservation=% event=% mode=% flow=% msi=%',
    v_reservation_id, v_event_id, p_payment_mode, v_flow_version,
    COALESCE(p_installment_plan, '1_pago');

  RETURN jsonb_build_object(
    'reservation_id', v_reservation_id,
    'event_id',       v_event_id
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.create_booking_with_event TO authenticated;

-- ── 5. Índice para reservas pendientes de pago (útil para admin) ──────────────
CREATE INDEX IF NOT EXISTS idx_res_payment_failed
  ON reservations(payment_status)
  WHERE payment_status = 'payment_failed';

CREATE INDEX IF NOT EXISTS idx_res_pending_payment
  ON reservations(payment_status)
  WHERE payment_status = 'pending_payment';

SELECT '203_payment_flow_v2.sql ejecutado ✅' AS status;
