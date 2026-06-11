-- ════════════════════════════════════════════════════════════════════
-- 183_dynamic_commission.sql
--
-- OBJETIVO: Comisión dinámica por tiers de precio. Fuente única en DB.
--
-- Tiers:
--   $0   – $3,000  → 7%
--   $3,001 – $6,000  → 8%
--   $6,001 – $10,000 → 9%
--   $10,001+         → 10%
--
-- Cambios:
--   1. Tabla commission_tiers (fuente única de verdad)
--   2. get_commission_rate(base_price) — función central
--   3. get_platform_fee_rate(base_price) — RPC pública para frontend
--   4. ALTER reservations ADD COLUMN base_price
--   5. create_booking_with_event — acepta p_base_price
--   6. calculate_commission() trigger — usa tiers dinámicos
--   7. mp_credit_pending_earnings — usa platform_commission almacenado
--
-- Requiere: 182_commission_7pct.sql
-- ════════════════════════════════════════════════════════════════════


-- ── 1. commission_tiers ──────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS public.commission_tiers (
  id        SERIAL  PRIMARY KEY,
  min_price NUMERIC NOT NULL DEFAULT 0,
  max_price NUMERIC,                     -- NULL = sin límite superior
  rate      NUMERIC NOT NULL,            -- entero: 7, 8, 9, 10
  label     TEXT
);

ALTER TABLE public.commission_tiers ENABLE ROW LEVEL SECURITY;

-- Cualquiera puede leer; solo service_role puede modificar
DROP POLICY IF EXISTS "tiers_read_all" ON public.commission_tiers;
CREATE POLICY "tiers_read_all" ON public.commission_tiers
  FOR SELECT USING (true);

-- Reinsertar tiers definitivos (idempotente)
TRUNCATE public.commission_tiers RESTART IDENTITY;
INSERT INTO public.commission_tiers (min_price, max_price, rate, label) VALUES
  (0,     3000,  7,  'Básico'),
  (3001,  6000,  8,  'Estándar'),
  (6001,  10000, 9,  'Premium'),
  (10001, NULL,  10, 'Elite');


-- ── 2. get_commission_rate(base_price) ───────────────────────────────────────
-- Retorna el rate como entero (7, 8, 9, 10).
-- Fallback: 7 si no encuentra tier (ej: price = 0 o tabla vacía).

DROP FUNCTION IF EXISTS public.get_commission_rate(NUMERIC);
CREATE OR REPLACE FUNCTION public.get_commission_rate(p_base_price NUMERIC)
RETURNS NUMERIC
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public
AS $$
  SELECT COALESCE(
    (SELECT rate
     FROM   public.commission_tiers
     WHERE  p_base_price >= min_price
       AND  (max_price IS NULL OR p_base_price <= max_price)
     ORDER  BY min_price DESC
     LIMIT  1),
    7.0
  );
$$;

GRANT EXECUTE ON FUNCTION public.get_commission_rate(NUMERIC) TO authenticated, anon;


-- ── 3. get_platform_fee_rate(base_price) — RPC pública ───────────────────────
-- El frontend llama esto para confirmar el rate antes de mostrar precios.
-- Retorna: { rate: 8, rate_pct: "8%", multiplier: 1.08 }

DROP FUNCTION IF EXISTS public.get_platform_fee_rate(NUMERIC);
CREATE OR REPLACE FUNCTION public.get_platform_fee_rate(
  p_base_price NUMERIC DEFAULT 0
)
RETURNS JSONB
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public
AS $$
  SELECT jsonb_build_object(
    'rate',       public.get_commission_rate(p_base_price),
    'rate_pct',   public.get_commission_rate(p_base_price)::TEXT || '%',
    'multiplier', ROUND((100.0 + public.get_commission_rate(p_base_price)) / 100.0, 4)
  );
$$;

GRANT EXECUTE ON FUNCTION public.get_platform_fee_rate(NUMERIC) TO authenticated, anon;


-- ── 4. reservations.base_price — precio base del grupo ───────────────────────

ALTER TABLE public.reservations
  ADD COLUMN IF NOT EXISTS base_price NUMERIC(12,2);


-- ── 5. create_booking_with_event — acepta p_base_price ───────────────────────
-- Agrega p_base_price NUMERIC DEFAULT NULL al final.
-- Backward compatible: callers que no lo pasen siguen funcionando.

DROP FUNCTION IF EXISTS public.create_booking_with_event(UUID, UUID, UUID, DATE, TIME, TEXT, NUMERIC, TEXT, TEXT);

CREATE FUNCTION public.create_booking_with_event(
  p_client_id   UUID,
  p_group_id    UUID,
  p_package_id  UUID,
  p_event_date  DATE,
  p_event_time  TIME,
  p_address     TEXT,
  p_total_price NUMERIC,
  p_notes       TEXT    DEFAULT NULL,
  p_break_type  TEXT    DEFAULT NULL,
  p_base_price  NUMERIC DEFAULT NULL   -- precio del grupo antes de comisión
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_event_id       UUID;
  v_reservation_id UUID;
BEGIN
  -- 1. Crear el evento padre
  INSERT INTO public.events (client_id, event_date, event_time, address, status)
  VALUES (p_client_id, p_event_date, p_event_time, p_address, 'active')
  RETURNING id INTO v_event_id;

  -- 2. Crear la reserva
  --    calculate_commission BEFORE INSERT trigger setea platform_commission y group_earnings
  INSERT INTO public.reservations (
    event_id, group_id, package_id, client_id,
    event_date, event_time, address, notes,
    break_type, total_price, base_price, status
  )
  VALUES (
    v_event_id, p_group_id, p_package_id, p_client_id,
    p_event_date, p_event_time, p_address, p_notes,
    p_break_type, p_total_price, p_base_price, 'pending_payment'
  )
  RETURNING id INTO v_reservation_id;

  RETURN jsonb_build_object(
    'reservation_id', v_reservation_id,
    'event_id',       v_event_id
  );
END;
$$;


-- ── 6. calculate_commission() trigger — tiers dinámicos ──────────────────────
--
-- Lee base_price si existe; si no, lo estima desde total_price asumiendo tier 7%.
-- group_earnings = base_price exacto (el grupo SIEMPRE recibe lo que cotizó).

CREATE OR REPLACE FUNCTION public.calculate_commission()
RETURNS TRIGGER AS $func$
DECLARE
  v_base NUMERIC;
  v_rate NUMERIC;
BEGIN
  -- base_price = precio del grupo sin comisión
  -- Fallback: estimar desde total_price asumiendo tier mínimo (7%)
  v_base := COALESCE(NEW.base_price, ROUND(NEW.total_price * 100.0 / 107.0, 2));

  -- Rate dinámico según tier
  v_rate := public.get_commission_rate(v_base) / 100.0;

  NEW.platform_commission := ROUND(v_base * v_rate, 2);
  NEW.group_earnings       := v_base;   -- grupo recibe su precio base exacto

  RAISE NOTICE '[COMMISSION_TRIGGER] group=% base=% rate=% commission=% group_earnings=%',
    NEW.group_id, v_base, v_rate * 100, NEW.platform_commission, NEW.group_earnings;

  RETURN NEW;
END;
$func$ LANGUAGE plpgsql SECURITY DEFINER;


-- ── 7. mp_credit_pending_earnings — usa platform_commission del trigger ───────
--
-- Reemplaza los hardcoded ×7/107 y ×0.08 por v_res.platform_commission
-- que ya fue calculado correctamente por el trigger al insertar la reserva.

CREATE OR REPLACE FUNCTION public.mp_credit_pending_earnings(
  p_reservation_id UUID,
  p_payment_id     TEXT,
  p_amount_paid    NUMERIC  DEFAULT NULL,
  p_is_deposit     BOOLEAN  DEFAULT FALSE
)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_res        RECORD;
  v_commission NUMERIC(12,2);
  v_group_net  NUMERIC(12,2);
  v_payout     RECORD;
  v_owner_id   UUID;
  v_admin_id   UUID;
  v_credited   INT := 0;
  v_deposit    NUMERIC(12,2);
BEGIN
  SELECT * INTO v_res
  FROM   public.reservations
  WHERE  id = p_reservation_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'reservation_not_found');
  END IF;

  IF v_res.wallet_pending_credited THEN
    RETURN jsonb_build_object('ok', true, 'skipped', true, 'reason', 'already_pending_credited');
  END IF;

  v_admin_id := public.get_platform_admin_id();

  -- Comisión: usar platform_commission calculado por el trigger (fuente única)
  -- Fallback seguro si por alguna razón es NULL
  v_commission := COALESCE(
    v_res.platform_commission,
    ROUND(v_res.total_price * 7.0 / 107.0, 2)
  );

  -- ── Modelo de anticipo (50%): comisión completa extraída del depósito ──
  IF p_is_deposit THEN
    v_deposit := COALESCE(p_amount_paid, ROUND(v_res.total_price * 0.5, 2));

    -- Si el anticipo no alcanza para cubrir la comisión completa
    IF v_commission > v_deposit THEN
      v_commission := v_deposit;
    END IF;

    v_group_net := v_deposit - v_commission;

    RAISE NOTICE '[COMMISSION_FLOW] deposit res=% total=% commission=% group_net=% deposit=%',
      p_reservation_id, v_res.total_price, v_commission, v_group_net, v_deposit;

    UPDATE public.reservations
    SET payment_status          = 'deposit_paid',
        mp_payment_id           = p_payment_id,
        wallet_pending_credited = TRUE,
        commission_extracted    = TRUE
    WHERE id = p_reservation_id;

    -- Comisión → admin (disponible de inmediato)
    IF v_admin_id IS NOT NULL THEN
      INSERT INTO public.wallets (user_id) VALUES (v_admin_id)
        ON CONFLICT (user_id) DO NOTHING;

      UPDATE public.wallets
      SET available_balance = available_balance + v_commission,
          total_earned      = total_earned + v_commission,
          updated_at        = NOW()
      WHERE user_id = v_admin_id;

      INSERT INTO public.wallet_transactions
        (user_id, amount, type, status, reference_event_id, description)
      VALUES
        (v_admin_id, v_commission, 'commission', 'completed', p_reservation_id,
         'Comisión plataforma extraída del anticipo · evento ' || v_res.event_date::TEXT);

      INSERT INTO public.financial_ledger
        (reservation_id, user_id, entry_type, amount, currency, description)
      VALUES
        (p_reservation_id, v_admin_id, 'platform_commission', v_commission, 'mxn',
         'Comisión completa del anticipo · evento ' || v_res.event_date::TEXT);
    END IF;

    -- Resto del anticipo → grupo (pending)
    SELECT g.owner_id INTO v_owner_id
    FROM   public.groups g
    WHERE  g.id = v_res.group_id;

    IF v_owner_id IS NOT NULL AND v_group_net > 0 THEN
      INSERT INTO public.wallets (user_id) VALUES (v_owner_id)
        ON CONFLICT (user_id) DO NOTHING;

      UPDATE public.wallets
      SET pending_balance = pending_balance + v_group_net,
          updated_at      = NOW()
      WHERE user_id = v_owner_id;

      INSERT INTO public.wallet_transactions
        (user_id, amount, type, status, reference_event_id, description)
      VALUES
        (v_owner_id, v_group_net, 'event_earning', 'pending', p_reservation_id,
         'Saldo del anticipo en espera · evento ' || v_res.event_date::TEXT);

      INSERT INTO public.notifications
        (user_id, type, title, body, data)
      VALUES
        (v_owner_id, 'payment',
         '⏳ Anticipo recibido',
         'Tienes $' || v_group_net::TEXT || ' MXN reservados. Se liberarán al terminar el evento.',
         jsonb_build_object(
           'reservation_id', p_reservation_id,
           'amount',         v_group_net,
           'screen',         'Wallet'
         ));
    END IF;

    RETURN jsonb_build_object(
      'ok',         true,
      'type',       'deposit',
      'deposit',    v_deposit,
      'commission', v_commission,
      'group_net',  v_group_net
    );
  END IF;

  -- ── Flujo normal (pago completo / segundo pago) ────────────────────────────

  IF v_res.commission_extracted THEN
    -- Comisión ya extraída en el anticipo — solo acreditar el saldo restante
    v_commission := 0;
    v_group_net  := COALESCE(p_amount_paid, v_res.total_price * 0.5);
  ELSE
    v_group_net := v_res.total_price - v_commission;
  END IF;

  RAISE NOTICE '[COMMISSION_FLOW] full res=% total=% commission=% group_net=% already_extracted=%',
    p_reservation_id, v_res.total_price, v_commission, v_group_net, v_res.commission_extracted;

  UPDATE public.reservations
  SET payment_status          = 'deposit_paid',
      mp_payment_id           = p_payment_id,
      wallet_pending_credited = TRUE
  WHERE id = p_reservation_id;

  -- Comisión al admin (solo si no se extrajo antes)
  IF v_admin_id IS NOT NULL AND v_commission > 0 THEN
    INSERT INTO public.wallets (user_id) VALUES (v_admin_id)
      ON CONFLICT (user_id) DO NOTHING;

    UPDATE public.wallets
    SET pending_balance = pending_balance + v_commission,
        updated_at      = NOW()
    WHERE user_id = v_admin_id;

    INSERT INTO public.wallet_transactions
      (user_id, amount, type, status, reference_event_id, description)
    VALUES
      (v_admin_id, v_commission, 'commission', 'pending', p_reservation_id,
       'Comisión plataforma en espera · evento ' || v_res.event_date::TEXT);
  END IF;

  -- Ganancias del grupo por payout breakdown
  FOR v_payout IN
    SELECT ep.user_id, ep.amount, ep.role
    FROM   public.event_payouts ep
    WHERE  ep.reservation_id = p_reservation_id
      AND  ep.payout_status  = 'pending'
      AND  ep.amount         > 0
  LOOP
    INSERT INTO public.wallets (user_id) VALUES (v_payout.user_id)
      ON CONFLICT (user_id) DO NOTHING;

    UPDATE public.wallets
    SET pending_balance = pending_balance + v_payout.amount,
        updated_at      = NOW()
    WHERE user_id = v_payout.user_id;

    INSERT INTO public.wallet_transactions
      (user_id, amount, type, status, reference_event_id, description)
    VALUES
      (v_payout.user_id, v_payout.amount, 'event_earning', 'pending',
       p_reservation_id,
       'Ganancia en espera · evento ' || v_res.event_date::TEXT || ' (' || v_payout.role || ')');

    INSERT INTO public.notifications (user_id, type, title, body, data)
    VALUES (v_payout.user_id, 'payment',
      '⏳ Dinero reservado para ti',
      'Tienes $' || v_payout.amount::TEXT || ' MXN reservados.',
      jsonb_build_object('reservation_id', p_reservation_id, 'amount', v_payout.amount, 'screen', 'Wallet'));

    v_credited := v_credited + 1;
  END LOOP;

  -- Fallback: sin breakdown → todo al owner del grupo
  IF v_credited = 0 THEN
    SELECT g.owner_id INTO v_owner_id FROM public.groups g WHERE g.id = v_res.group_id;
    IF v_owner_id IS NOT NULL THEN
      INSERT INTO public.wallets (user_id) VALUES (v_owner_id) ON CONFLICT (user_id) DO NOTHING;
      UPDATE public.wallets
      SET pending_balance = pending_balance + v_group_net, updated_at = NOW()
      WHERE user_id = v_owner_id;
      INSERT INTO public.wallet_transactions (user_id, amount, type, status, reference_event_id, description)
      VALUES (v_owner_id, v_group_net, 'event_earning', 'pending', p_reservation_id,
        'Ganancia en espera · evento ' || v_res.event_date::TEXT || ' (owner)');
    END IF;
  END IF;

  RETURN jsonb_build_object('ok', true, 'commission', v_commission, 'group_net', v_group_net);

EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$$;


-- ── Verificación ──────────────────────────────────────────────────────────────

-- Tiers cargados
SELECT id, min_price, max_price, rate, label FROM public.commission_tiers ORDER BY min_price;

-- Test de la función
SELECT
  base                                                     AS base_price,
  public.get_commission_rate(base)                         AS rate_pct,
  ROUND(base * public.get_commission_rate(base) / 100, 2)  AS commission,
  base + ROUND(base * public.get_commission_rate(base) / 100, 2) AS client_price
FROM (VALUES (2500), (5000), (8000), (12000)) AS t(base);

-- RPC pública
SELECT public.get_platform_fee_rate(5000);

SELECT '183_dynamic_commission.sql ejecutado ✅' AS status;
