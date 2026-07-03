-- ════════════════════════════════════════════════════════════════════
-- sql/402_commission_20pct.sql
--
-- REFACTOR: Modelo comisión 10% inclusivo → 20% markup.
--
-- MODELO NUEVO:
--   grupo escribe precio NETO       → base_price  = grupoNeto
--   cliente paga 20% más            → total_price = grupoNeto × 1.20
--   grupo recibe 100% de su precio  → group_earnings = grupoNeto
--   Daricefy retiene                → service_fee = total_price − grupoNeto
--
-- FÓRMULA CLAVE (inversa): grupoNeto = total_price / 1.20
--
-- FUNCIONES TOCADAS:
--   A) Trigger set_commission_before_insert   → DROP (supersedido)
--   A) calculate_commission()                 → actualizar fallback
--   A) set_reservation_financials()           → 0.10 → diferencia / 1.20
--   B) confirm_full_payment_and_credit_wallet → fallbacks actualizados
--   C) confirm_extra_hour_stripe_payment      → comisión diferencia
--   D) propose_event_request                  → 0.15 express → 0, markup 1.20
--   E) client_accept_proposal                 → 0.10 → diferencia
--   F) distribute_event_earnings              → 0.10 → diferencia (MP legacy)
--   F) mp_credit_pending_earnings             → 0.10 → diferencia (MP legacy)
--
-- NO TOCA:
--   release_group_earnings_atomic (liberación 50/50)
--   release_half_on_arrival       (liberación 50/50)
--   release_extra_hours_partial / _final
--   group_accept_extra_hour_stripe
--   Wallets existentes / datos históricos
-- ════════════════════════════════════════════════════════════════════

BEGIN;

-- ══════════════════════════════════════════════════════════════════════
-- A1. DROP trigger viejo que entra en conflicto con trg_set_reservation_financials
-- ══════════════════════════════════════════════════════════════════════
DROP TRIGGER IF EXISTS set_commission_before_insert ON public.reservations;

-- ══════════════════════════════════════════════════════════════════════
-- A2. calculate_commission() — actualizar fallback de 107% → 120%
--     (función sigue siendo SECURITY DEFINER, solo cambia 1 línea)
-- ══════════════════════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION public.calculate_commission()
RETURNS TRIGGER AS $func$
DECLARE
  v_base NUMERIC;
BEGIN
  -- base_price = precio neto del grupo (100%). Fallback: total / 1.20 (markup 20%).
  v_base := COALESCE(NEW.base_price, ROUND(NEW.total_price / 1.20, 2));
  NEW.platform_commission := ROUND(NEW.total_price - v_base, 2);
  NEW.group_earnings       := v_base;
  RETURN NEW;
END;
$func$ LANGUAGE plpgsql SECURITY DEFINER;

-- ══════════════════════════════════════════════════════════════════════
-- A3. set_reservation_financials() — 10% inclusivo → diferencia / 1.20
-- ══════════════════════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION public.set_reservation_financials()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
  v_fee      NUMERIC;
  v_earnings NUMERIC;
BEGIN
  -- Modelo markup 20%: cliente paga grupoNeto × 1.20
  -- service_fee = total_price − grupoNeto = total_price × (1 − 1/1.20)
  v_earnings := ROUND(NEW.total_price / 1.20, 2);
  v_fee      := NEW.total_price - v_earnings;

  IF NEW.service_fee_amount IS NULL THEN
    NEW.service_fee_amount := v_fee;
  END IF;

  IF NEW.platform_commission IS NULL OR NEW.platform_commission = 0 THEN
    NEW.platform_commission := NEW.service_fee_amount;
  END IF;

  IF NEW.group_earnings IS NULL OR NEW.group_earnings = 0 THEN
    NEW.group_earnings := v_earnings;
  END IF;

  -- Saldo disponible del cliente para horas extra (= precio neto grupo)
  IF NEW.client_available_balance IS NULL THEN
    NEW.client_available_balance := v_earnings;
  END IF;

  RETURN NEW;
END;
$$;

-- ══════════════════════════════════════════════════════════════════════
-- B. confirm_full_payment_and_credit_wallet — fallbacks actualizados
--    Única diferencia respecto a sql/240: las líneas de fallback
--    * 0.9 → / 1.20   y   * 0.10 → total − total/1.20
-- ══════════════════════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION public.confirm_full_payment_and_credit_wallet(
  p_reservation_id UUID,
  p_mp_payment_id  TEXT,
  p_amount_paid    NUMERIC DEFAULT NULL,
  p_stripe_fee     NUMERIC DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_reservation  RECORD;
  v_wallet_id    UUID;
  v_earnings     NUMERIC;
  v_service_fee  NUMERIC;
  v_msi_fee      NUMERIC;
  v_admin_bruto  NUMERIC;
  v_stripe_fee   NUMERIC;
  v_admin_neto   NUMERIC;
  v_admin_id     UUID;
  v_currency     TEXT;
BEGIN
  SELECT * INTO v_reservation
  FROM reservations WHERE id = p_reservation_id FOR UPDATE;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'reservation_not_found');
  END IF;

  IF v_reservation.payment_status IN ('paid','fully_paid') THEN
    RETURN jsonb_build_object('ok', true, 'skipped', true, 'reason', 'already_paid');
  END IF;

  v_currency    := COALESCE(v_reservation.currency_code, 'MXN');

  -- Modelo markup 20%: grupo recibe base_price (su neto).
  -- Fallback cuando base_price no está guardado: total_price / 1.20.
  v_earnings    := COALESCE(v_reservation.base_price,
                     ROUND(v_reservation.total_price / 1.20, 2));
  v_service_fee := COALESCE(v_reservation.service_fee_amount,
                     v_reservation.total_price - ROUND(v_reservation.total_price / 1.20, 2));
  v_msi_fee     := COALESCE(v_reservation.msi_fee_amount, 0);
  v_admin_bruto := v_service_fee + v_msi_fee;
  v_stripe_fee  := COALESCE(
                     p_stripe_fee,
                     COALESCE(v_reservation.stripe_fee_amount,
                       ROUND((v_reservation.total_price + v_msi_fee) * 0.036 + 3, 2))
                   );
  v_admin_neto  := GREATEST(0, v_admin_bruto - v_stripe_fee);

  PERFORM ensure_group_wallet(v_reservation.group_id);
  SELECT id INTO v_wallet_id FROM group_wallets WHERE group_id = v_reservation.group_id;

  IF v_currency = 'USD' THEN
    UPDATE group_wallets SET
      pending_balance_usd = pending_balance_usd + v_earnings,
      total_earned_usd    = total_earned_usd    + v_earnings,
      updated_at          = NOW()
    WHERE id = v_wallet_id;
  ELSE
    UPDATE group_wallets SET
      pending_balance = pending_balance + v_earnings,
      total_earned    = total_earned    + v_earnings,
      updated_at      = NOW()
    WHERE id = v_wallet_id;
  END IF;

  UPDATE reservations SET
    payment_status     = 'paid',
    payout_status      = 'held',
    held_at            = NOW(),
    mp_payment_id      = p_mp_payment_id,
    stripe_fee_amount  = COALESCE(p_stripe_fee, stripe_fee_amount),
    service_fee_amount = v_service_fee,
    group_earnings     = v_earnings,
    updated_at         = NOW()
  WHERE id = p_reservation_id;

  INSERT INTO wallet_transactions (
    group_wallet_id, group_id, type, amount,
    reservation_id, description, balance_after, currency_code
  )
  SELECT gw.id, gw.group_id, 'credit_pending', v_earnings,
    p_reservation_id,
    format('Pago confirmado — reserva %s', p_reservation_id),
    CASE WHEN v_currency = 'USD' THEN gw.pending_balance_usd ELSE gw.pending_balance END,
    v_currency
  FROM group_wallets gw WHERE gw.id = v_wallet_id;

  SELECT id INTO v_admin_id FROM profiles WHERE role = 'admin' ORDER BY created_at LIMIT 1;
  IF v_admin_id IS NOT NULL THEN
    INSERT INTO wallets (user_id, available_balance, pending_balance, total_earned)
    VALUES (v_admin_id, 0, 0, 0)
    ON CONFLICT (user_id) DO NOTHING;

    IF v_currency = 'USD' THEN
      UPDATE wallets SET
        available_balance_usd = available_balance_usd + v_admin_neto,
        total_earned_usd      = COALESCE(total_earned_usd, 0) + v_admin_neto,
        updated_at            = NOW()
      WHERE user_id = v_admin_id;
    ELSE
      UPDATE wallets SET
        available_balance = available_balance + v_admin_neto,
        total_earned      = COALESCE(total_earned, 0) + v_admin_neto,
        updated_at        = NOW()
      WHERE user_id = v_admin_id;
    END IF;

    INSERT INTO wallet_transactions (user_id, type, amount, reservation_id, description, currency_code)
    VALUES (v_admin_id, 'platform_income', v_admin_neto, p_reservation_id,
      format('Comisión $%s + MSI $%s − Stripe $%s = $%s neto — reserva %s',
        v_service_fee::TEXT, v_msi_fee::TEXT,
        v_stripe_fee::TEXT, v_admin_neto::TEXT,
        p_reservation_id),
      v_currency);
  END IF;

  INSERT INTO financial_audit_logs
    (entity_type, entity_id, action, actor_id, actor_role, amount, notes)
  VALUES ('reservation', p_reservation_id, 'hold', NULL, 'system', v_earnings,
    format('currency=%s group=%s svc=%s msi=%s stripe=%s admin_neto=%s',
      v_currency, v_earnings, v_service_fee, v_msi_fee, v_stripe_fee, v_admin_neto));

  RETURN jsonb_build_object(
    'ok',             true,
    'currency',       v_currency,
    'group_earnings', v_earnings,
    'service_fee',    v_service_fee,
    'msi_fee',        v_msi_fee,
    'admin_bruto',    v_admin_bruto,
    'stripe_fee',     v_stripe_fee,
    'admin_neto',     v_admin_neto
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.confirm_full_payment_and_credit_wallet(UUID, TEXT, NUMERIC, NUMERIC)
  TO authenticated, service_role;

-- ══════════════════════════════════════════════════════════════════════
-- C. confirm_extra_hour_stripe_payment — comisión diferencia (no %)
--    Única diferencia respecto a sql/401: v_service_fee usa diferencia
--    total_extra_cost − group_extra_earnings en lugar de * 0.10.
--    Correcto tanto antes como después de Fase D:
--      · Antes Fase D: total = grupoNeto, group_earnings = grupoNeto/1.20 (←pisa)
--      · Después Fase D: total = grupoNeto×1.20, group_earnings = grupoNeto ✓
-- ══════════════════════════════════════════════════════════════════════
DROP FUNCTION IF EXISTS public.confirm_extra_hour_stripe_payment(UUID, TEXT, NUMERIC, NUMERIC);

CREATE OR REPLACE FUNCTION public.confirm_extra_hour_stripe_payment(
  p_extra_id           UUID,
  p_stripe_payment_id  TEXT,
  p_amount_paid        NUMERIC,
  p_stripe_fee         NUMERIC DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_extra       RECORD;
  v_group_id    UUID;
  v_owner_id    UUID;
  v_client_id   UUID;
  v_res_id      UUID;
  v_wallet      RECORD;
  v_earnings    NUMERIC(12,2);
  v_bal_after   NUMERIC(14,2);
  v_service_fee NUMERIC(12,2);
  v_stripe_fee  NUMERIC(12,2);
  v_admin_neto  NUMERIC(12,2);
  v_admin_id    UUID;
BEGIN
  SELECT * INTO v_extra FROM public.extra_hours WHERE id = p_extra_id FOR UPDATE;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'extra_not_found');
  END IF;

  IF v_extra.status = 'paid' THEN
    RETURN jsonb_build_object('ok', true, 'skipped', true, 'reason', 'already_paid');
  END IF;

  IF v_extra.status NOT IN ('pending_payment') THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_status', 'status', v_extra.status);
  END IF;

  SELECT r.id, r.client_id, r.group_id INTO v_res_id, v_client_id, v_group_id
  FROM   public.reservations r WHERE r.id = v_extra.reservation_id FOR UPDATE;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'reservation_not_found');
  END IF;

  SELECT g.owner_id INTO v_owner_id FROM public.groups g WHERE g.id = v_group_id;

  SELECT * INTO v_wallet FROM public.group_wallets WHERE group_id = v_group_id FOR UPDATE;
  IF NOT FOUND THEN
    INSERT INTO public.group_wallets (group_id) VALUES (v_group_id) RETURNING * INTO v_wallet;
  END IF;

  -- Ganancia del grupo: 100% de su precio neto (almacenado en group_extra_earnings)
  v_earnings  := ROUND(COALESCE(v_extra.group_extra_earnings, 0), 2);
  v_bal_after := COALESCE(v_wallet.pending_balance, 0) + v_earnings;

  -- Comisión Daricefy: diferencia entre lo que pagó el cliente y lo que recibe el grupo.
  -- Modelo markup 20%: service_fee = total_extra_cost − group_extra_earnings.
  -- Fallback cuando group_extra_earnings no está guardado: total / 1.20.
  v_service_fee := ROUND(
    v_extra.total_extra_cost
    - COALESCE(v_extra.group_extra_earnings, ROUND(v_extra.total_extra_cost / 1.20, 2)),
    2
  );
  v_stripe_fee  := COALESCE(p_stripe_fee, ROUND(v_extra.total_extra_cost * 0.036 + 3, 2));
  v_admin_neto  := GREATEST(0, v_service_fee - v_stripe_fee);

  UPDATE public.group_wallets
  SET pending_balance = v_bal_after,
      total_earned    = COALESCE(total_earned, 0) + v_earnings,
      updated_at      = NOW()
  WHERE group_id = v_group_id;

  UPDATE public.extra_hours
  SET status            = 'paid',
      stripe_payment_id = p_stripe_payment_id,
      paid_at           = NOW(),
      payout_status     = 'held'
  WHERE id = p_extra_id;

  UPDATE public.reservations
  SET extra_hours_added = COALESCE(extra_hours_added, 0) + v_extra.hours_added
  WHERE id = v_res_id;

  INSERT INTO public.wallet_transactions (
    group_wallet_id, group_id, type, amount, reservation_id,
    mp_payment_id, description, balance_after
  ) VALUES (
    v_wallet.id, v_group_id, 'extra_hour', v_earnings, v_res_id,
    p_stripe_payment_id,
    'Hora extra (Stripe) — retenida hasta fin de evento',
    v_bal_after
  );

  INSERT INTO public.financial_audit_logs (
    entity_type, entity_id, action, actor_id, actor_role,
    before_state, after_state, amount, notes
  ) VALUES (
    'extra_hour', p_extra_id, 'stripe_paid', NULL, 'stripe_webhook',
    jsonb_build_object('status', 'pending_payment', 'payout_status', 'pending'),
    jsonb_build_object(
      'status',            'paid',
      'payout_status',     'held',
      'stripe_payment_id', p_stripe_payment_id,
      'amount_paid',       p_amount_paid,
      'service_fee',       v_service_fee,
      'stripe_fee',        v_stripe_fee,
      'admin_neto',        v_admin_neto
    ),
    p_amount_paid,
    'Pago Stripe hora extra confirmado por webhook'
  );

  -- platform_income → admin wallet
  SELECT id INTO v_admin_id FROM public.profiles WHERE role = 'admin' ORDER BY created_at LIMIT 1;
  IF v_admin_id IS NOT NULL THEN
    INSERT INTO public.wallets (user_id, available_balance, pending_balance, total_earned)
    VALUES (v_admin_id, 0, 0, 0)
    ON CONFLICT (user_id) DO NOTHING;

    UPDATE public.wallets
    SET available_balance = available_balance + v_admin_neto,
        total_earned      = COALESCE(total_earned, 0) + v_admin_neto,
        updated_at        = NOW()
    WHERE user_id = v_admin_id;

    INSERT INTO public.wallet_transactions (
      user_id, type, amount, reservation_id, description
    ) VALUES (
      v_admin_id, 'platform_income', v_admin_neto, v_res_id,
      format('Comisión extra-hora $%s − Stripe $%s = $%s neto — extra %s',
        v_service_fee::TEXT, v_stripe_fee::TEXT, v_admin_neto::TEXT, p_extra_id)
    );
  END IF;

  IF v_owner_id IS NOT NULL THEN
    INSERT INTO public.notifications (user_id, type, title, body, data)
    VALUES (
      v_owner_id, 'extra_hour_approved_by_client',
      '💰 ' || v_extra.hours_added || 'h extra pagadas con tarjeta',
      'El cliente pagó $' || ROUND(v_extra.total_extra_cost)::TEXT ||
        ' MXN. Las ganancias ($' || ROUND(v_earnings)::TEXT || ') se liberan al terminar.',
      jsonb_build_object(
        'reservation_id', v_res_id, 'extra_hour_id', p_extra_id, 'screen', 'EventTimer'
      )
    );
  END IF;

  IF v_client_id IS NOT NULL THEN
    INSERT INTO public.notifications (user_id, type, title, body, data)
    VALUES (
      v_client_id, 'extra_hour_payment_confirmed',
      '✅ ' || v_extra.hours_added || 'h extra confirmadas',
      'Tu pago fue procesado. El evento se extiende automáticamente.',
      jsonb_build_object('reservation_id', v_res_id, 'screen', 'EventTimer')
    );
  END IF;

  RETURN jsonb_build_object(
    'ok', true, 'extra_id', p_extra_id,
    'earnings', v_earnings, 'group_id', v_group_id,
    'service_fee', v_service_fee, 'stripe_fee', v_stripe_fee, 'admin_neto', v_admin_neto
  );

EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$$;

GRANT EXECUTE ON FUNCTION public.confirm_extra_hour_stripe_payment(UUID, TEXT, NUMERIC, NUMERIC)
  TO authenticated, service_role;

-- ══════════════════════════════════════════════════════════════════════
-- D. propose_event_request — eliminar recargo 15% express; markup 20% aplica igual.
--    Daricefy gana 20% en TODOS los flujos (normal y express) vía client_total=group×1.20.
--    express_fee=0 significa "sin recargo adicional por express" — NO significa comisión=0.
--    service_fee en proposal_data es la comisión explícita para uso interno/admin.
-- ══════════════════════════════════════════════════════════════════════
DO $$
DECLARE r RECORD;
BEGIN
  FOR r IN
    SELECT oid::regprocedure AS sig FROM pg_proc
    WHERE proname = 'propose_event_request' AND pronamespace = 'public'::regnamespace
  LOOP
    EXECUTE 'DROP FUNCTION IF EXISTS ' || r.sig || ' CASCADE';
  END LOOP;
END;
$$;

CREATE FUNCTION public.propose_event_request(
  p_request_id     UUID,
  p_price_per_hour NUMERIC  DEFAULT NULL,
  p_travel_cost    NUMERIC  DEFAULT 0,
  p_overtime_1h    NUMERIC  DEFAULT NULL,
  p_overtime_2h    NUMERIC  DEFAULT NULL,
  p_overtime_3h    NUMERIC  DEFAULT NULL,
  p_notes          TEXT     DEFAULT NULL,
  p_member_dist    JSONB    DEFAULT NULL,
  p_arrival_time   TEXT     DEFAULT NULL,
  p_start_time     TEXT     DEFAULT NULL,
  p_dispatch_id    UUID     DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_req           RECORD;
  v_group         RECORD;
  v_hours         INTEGER;
  v_base_price    NUMERIC;
  v_base_total    NUMERIC;
  v_multiplier    NUMERIC;
  v_group_total   NUMERIC;
  v_client_total  NUMERIC;
  v_service_fee   NUMERIC;
  v_proposal_data JSONB;
  v_is_first      BOOLEAN;
  v_is_express    BOOLEAN := false;
BEGIN
  SELECT * INTO v_group FROM public.groups WHERE owner_id = auth.uid() LIMIT 1;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'no_group_found');
  END IF;

  SELECT * INTO v_req FROM public.event_requests WHERE id = p_request_id FOR UPDATE;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'request_not_found');
  END IF;

  -- Express: triple palanca
  IF p_dispatch_id IS NOT NULL THEN v_is_express := true; END IF;
  IF NOT v_is_express THEN v_is_express := (v_req.express_window_until IS NOT NULL); END IF;
  IF NOT v_is_express THEN
    SELECT EXISTS (
      SELECT 1 FROM public.express_dispatches ed
      WHERE ed.request_id = p_request_id AND ed.group_id = v_group.id
    ) INTO v_is_express;
  END IF;

  IF v_req.status = 'cancelled' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'request_expired');
  END IF;
  IF v_req.status NOT IN ('open', 'en_negociacion', 'expired') THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_available');
  END IF;
  IF NOT v_is_express THEN
    IF v_req.expires_at < NOW() THEN
      RETURN jsonb_build_object('ok', false, 'error', 'request_expired');
    END IF;
    IF v_req.status = 'expired' THEN
      RETURN jsonb_build_object('ok', false, 'error', 'request_expired');
    END IF;
  END IF;

  IF v_group.genre <> v_req.genre THEN
    RETURN jsonb_build_object('ok', false, 'error', 'genre_mismatch');
  END IF;

  -- ── Cálculo de precios (modelo markup 20%) ───────────────────────────
  -- grupo escribe su precio NETO por hora → p_price_per_hour
  -- cliente paga grupoTotal × 1.20
  -- express ya no tiene recargo separado: la ventana express es un beneficio
  -- de servicio, no un cargo adicional al cliente.
  v_hours        := COALESCE(v_req.hours, 3);
  v_base_price   := COALESCE(p_price_per_hour, 0) * v_hours;
  v_base_total   := v_base_price + COALESCE(p_travel_cost, 0);
  v_multiplier   := COALESCE(v_req.demand_multiplier, 1.000);
  v_group_total  := ROUND(v_base_total * v_multiplier);
  v_client_total := ROUND(v_group_total * 1.20);
  v_service_fee  := v_client_total - v_group_total; -- comisión Daricefy 20% del neto

  v_proposal_data := jsonb_build_object(
    'price_per_hour',    p_price_per_hour,
    'travel_cost',       COALESCE(p_travel_cost, 0),
    'base_price',        v_base_price,
    'base_total',        v_base_total,
    'demand_multiplier', v_multiplier,
    'group_price',       v_group_total,
    'express_fee',       0,              -- sin recargo expreso adicional (recargo 15% eliminado)
    'service_fee',       v_service_fee,  -- comisión plataforma = group × 0.20 (uso interno)
    'total_amount',      v_client_total, -- lo que paga el cliente = group × 1.20
    'group_earnings',    v_group_total,  -- lo que recibe el grupo = 100% de su precio
    'overtime_1h_price', p_overtime_1h,
    'overtime_2h_price', p_overtime_2h,
    'overtime_3h_price', p_overtime_3h,
    'notes',             p_notes,
    'member_dist',       p_member_dist,
    'arrival_time',      p_arrival_time,
    'start_time',        p_start_time
  );

  INSERT INTO public.event_request_proposals
    (request_id, group_id, group_owner_id, proposal_data)
  VALUES
    (p_request_id, v_group.id, auth.uid(), v_proposal_data)
  ON CONFLICT (request_id, group_id)
  DO UPDATE SET proposal_data = EXCLUDED.proposal_data, updated_at = NOW();

  v_is_first := v_req.status IN ('open', 'expired');
  IF v_is_first THEN
    UPDATE public.event_requests
    SET status               = 'en_negociacion',
        negotiating_group_id = auth.uid(),
        proposal_data        = v_proposal_data
    WHERE id = p_request_id;
  END IF;

  INSERT INTO public.notifications (user_id, type, title, body, data)
  VALUES (
    v_req.client_id, 'booking',
    '🎵 ' || v_group.name || ' quiere tocar en tu evento',
    'Recibiste una cotización. Compara propuestas y elige la que más te conviene.',
    jsonb_build_object('request_id', p_request_id, 'group_id', v_group.id, 'screen', 'OpenRequest')
  );

  RETURN jsonb_build_object(
    'ok', true, 'group_name', v_group.name,
    'group_id', v_group.id, 'is_update', NOT v_is_first, 'is_express', v_is_express
  );

EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$$;

GRANT EXECUTE ON FUNCTION public.propose_event_request(
  UUID, NUMERIC, NUMERIC, NUMERIC, NUMERIC, NUMERIC, TEXT, JSONB, TEXT, TEXT, UUID
) TO authenticated;

-- ══════════════════════════════════════════════════════════════════════
-- E. client_accept_proposal — 10% → diferencia; leer total_amount
--    Corrección adicional: leer 'total_amount' (no 'price') de proposal_data
-- ══════════════════════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION public.client_accept_proposal(p_request_id UUID)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_req      RECORD;
  v_group    RECORD;
  v_comm     NUMERIC;
  v_earnings NUMERIC;
  v_res_id   UUID;
  v_price    NUMERIC;
  v_hours    INT;
BEGIN
  SELECT * INTO v_req FROM public.event_requests WHERE id = p_request_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'request_not_found');
  END IF;

  IF v_req.client_id <> auth.uid() THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_owner');
  END IF;
  IF v_req.status <> 'en_negociacion' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_in_negotiation');
  END IF;
  IF v_req.negotiating_group_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'no_group');
  END IF;

  SELECT * INTO v_group FROM public.groups WHERE id = v_req.negotiating_group_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'group_not_found');
  END IF;

  v_hours := COALESCE(v_req.hours, 1);

  -- Leer precio del proposal_data: 'total_amount' es lo que paga el cliente
  -- (guardado por propose_event_request). Fallback a 'price' (legacy) y budget_max.
  v_price := COALESCE(
    (v_req.proposal_data->>'total_amount')::NUMERIC,
    (v_req.proposal_data->>'price')::NUMERIC,
    v_req.budget_max,
    0
  );

  -- Modelo markup 20%: grupo recibe 100% de su neto = total / 1.20
  v_earnings := ROUND(v_price / 1.20, 2);
  v_comm     := v_price - v_earnings;

  INSERT INTO public.reservations (
    group_id, client_id, event_date, event_time, address,
    total_price, base_price, platform_commission, group_earnings, service_fee_amount,
    status, hours_count, event_request_id
  ) VALUES (
    v_group.id, v_req.client_id, v_req.event_date,
    COALESCE((v_req.proposal_data->>'start_time'), v_req.event_time, '20:00'),
    COALESCE(v_req.address, v_req.location_city, ''),
    v_price, v_earnings, v_comm, v_earnings, v_comm,
    'accepted', v_hours, p_request_id
  )
  RETURNING id INTO v_res_id;

  UPDATE public.event_requests
  SET status                  = 'accepted',
      accepted_by_group_id    = v_group.id,
      accepted_reservation_id = v_res_id
  WHERE id = p_request_id;

  RETURN jsonb_build_object('ok', true, 'reservation_id', v_res_id);
END;
$$;

GRANT EXECUTE ON FUNCTION public.client_accept_proposal(UUID) TO authenticated;

-- ══════════════════════════════════════════════════════════════════════
-- F1. distribute_event_earnings (MP legacy) — 10% → diferencia
-- ══════════════════════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION public.distribute_event_earnings(
  p_reservation_id UUID
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_res        RECORD;
  v_commission NUMERIC(12,2);
  v_group_net  NUMERIC(12,2);
  v_admin_id   UUID;
  v_wallet     RECORD;
  v_group_tx   RECORD;
  v_has_group_pending BOOLEAN := FALSE;
BEGIN
  SELECT * INTO v_res FROM public.reservations WHERE id = p_reservation_id FOR UPDATE;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'reservation_not_found');
  END IF;

  IF v_res.wallet_distributed THEN
    RETURN jsonb_build_object('ok', true, 'skipped', true, 'reason', 'already_distributed');
  END IF;

  -- Modelo markup 20%: grupo recibe base_price (su neto).
  -- commission = total_price − grupo_neto.
  v_group_net  := COALESCE(v_res.group_earnings,
                    COALESCE(v_res.base_price, ROUND(v_res.total_price / 1.20, 2)));
  v_commission := v_res.total_price - v_group_net;
  v_admin_id   := public.get_platform_admin_id();

  UPDATE public.reservations
  SET commission_amount  = v_commission,
      platform_fee       = v_commission,
      group_earnings     = v_group_net,
      wallet_distributed = TRUE,
      payout_completed   = TRUE,
      status             = 'completed',
      payment_status     = 'fully_paid',
      event_ended_at     = COALESCE(event_ended_at, NOW())
  WHERE id = p_reservation_id;

  IF v_admin_id IS NOT NULL THEN
    INSERT INTO public.wallets (user_id) VALUES (v_admin_id) ON CONFLICT (user_id) DO NOTHING;
    UPDATE public.wallets
    SET available_balance = available_balance + v_commission,
        pending_balance   = GREATEST(0, pending_balance - v_commission),
        total_earned      = total_earned + v_commission,
        updated_at        = NOW()
    WHERE user_id = v_admin_id;
  END IF;

  PERFORM public.ensure_group_wallet(v_res.group_id);
  SELECT * INTO v_wallet FROM public.group_wallets WHERE group_id = v_res.group_id FOR UPDATE;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'group_wallet_not_found');
  END IF;

  SELECT EXISTS (
    SELECT 1 FROM public.wallet_transactions
    WHERE reservation_id = p_reservation_id AND group_id = v_res.group_id AND type = 'credit_pending'
  ) INTO v_has_group_pending;

  IF v_has_group_pending THEN
    FOR v_group_tx IN
      SELECT id, amount FROM public.wallet_transactions
      WHERE reservation_id = p_reservation_id AND group_id = v_res.group_id AND type = 'credit_pending'
    LOOP
      UPDATE public.group_wallets
      SET available_balance = available_balance + v_group_tx.amount,
          pending_balance   = GREATEST(0, pending_balance - v_group_tx.amount),
          updated_at        = NOW()
      WHERE id = v_wallet.id;

      INSERT INTO public.wallet_transactions
        (group_wallet_id, group_id, type, amount, reservation_id, description, balance_after)
      SELECT gw.id, gw.group_id, 'credit_available', v_group_tx.amount, p_reservation_id,
        'Ganancias liberadas post-evento ' || v_res.event_date::TEXT,
        gw.available_balance + v_group_tx.amount
      FROM public.group_wallets gw WHERE gw.id = v_wallet.id;
    END LOOP;
  ELSE
    IF NOT EXISTS (
      SELECT 1 FROM public.wallet_transactions
      WHERE reservation_id = p_reservation_id AND group_id = v_res.group_id
        AND type IN ('credit_pending', 'credit_available')
    ) THEN
      UPDATE public.group_wallets
      SET available_balance = available_balance + v_group_net,
          total_earned      = total_earned + v_group_net,
          updated_at        = NOW()
      WHERE id = v_wallet.id;

      INSERT INTO public.wallet_transactions
        (group_wallet_id, group_id, type, amount, reservation_id, description, balance_after)
      SELECT gw.id, gw.group_id, 'credit_available', v_group_net, p_reservation_id,
        'Ganancia evento ' || v_res.event_date::TEXT || ' (acreditación directa)',
        gw.available_balance + v_group_net
      FROM public.group_wallets gw WHERE gw.id = v_wallet.id;
    END IF;
  END IF;

  UPDATE public.reservations
  SET payout_status      = 'released',
      released_at        = NOW(),
      wallet_released_at = NOW()
  WHERE id = p_reservation_id AND payout_status != 'released';

  INSERT INTO public.financial_audit_logs (
    entity_type, entity_id, action, actor_id, actor_role, amount, notes
  ) VALUES (
    'reservation', p_reservation_id, 'release', NULL, 'system', v_group_net,
    format('distribute_event_earnings: 20pct_markup, group=%s', v_res.group_id)
  );

  INSERT INTO public.notifications (user_id, type, title, body, data)
  SELECT g.owner_id, 'payout', '💰 ¡Ganancias disponibles!',
    format('$%s MXN disponibles en tu billetera por el evento del %s.',
      to_char(v_group_net, 'FM999,999,990'), v_res.event_date::TEXT),
    jsonb_build_object('reservation_id', p_reservation_id, 'amount', v_group_net, 'screen', 'Wallet')
  FROM public.groups g WHERE g.id = v_res.group_id;

  UPDATE public.event_payouts
  SET payout_status = 'paid'
  WHERE reservation_id = p_reservation_id AND role = 'owner' AND is_informational = FALSE;

  RETURN jsonb_build_object(
    'ok', true, 'reservation', p_reservation_id,
    'total', v_res.total_price, 'commission', v_commission,
    'group_net', v_group_net, 'model', 'owner_only_20pct_markup'
  );

EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$$;

GRANT EXECUTE ON FUNCTION public.distribute_event_earnings(UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION public.distribute_event_earnings(UUID) TO service_role;

-- ══════════════════════════════════════════════════════════════════════
-- F2. mp_credit_pending_earnings (MP legacy) — 10% → diferencia
-- ══════════════════════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION public.mp_credit_pending_earnings(
  p_reservation_id UUID,
  p_payment_id     TEXT,
  p_amount_paid    NUMERIC DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_res        RECORD;
  v_commission NUMERIC(12,2);
  v_group_net  NUMERIC(12,2);
  v_admin_id   UUID;
  v_wallet_id  UUID;
BEGIN
  SELECT * INTO v_res FROM public.reservations WHERE id = p_reservation_id FOR UPDATE;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'reservation_not_found');
  END IF;

  IF v_res.wallet_pending_credited THEN
    RETURN jsonb_build_object('ok', true, 'skipped', true, 'reason', 'already_pending_credited');
  END IF;

  -- Modelo markup 20%: grupo recibe base_price, comisión = diferencia
  v_group_net  := COALESCE(v_res.base_price, ROUND(v_res.total_price / 1.20, 2));
  v_commission := v_res.total_price - v_group_net;
  v_admin_id   := public.get_platform_admin_id();

  UPDATE public.reservations
  SET payment_status          = 'deposit_paid',
      mp_payment_id           = p_payment_id,
      wallet_pending_credited = TRUE,
      payout_status           = 'held',
      held_at                 = NOW()
  WHERE id = p_reservation_id;

  IF v_admin_id IS NOT NULL THEN
    INSERT INTO public.wallets (user_id) VALUES (v_admin_id) ON CONFLICT (user_id) DO NOTHING;
    UPDATE public.wallets
    SET pending_balance = pending_balance + v_commission,
        updated_at      = NOW()
    WHERE user_id = v_admin_id;
  END IF;

  PERFORM public.ensure_group_wallet(v_res.group_id);
  SELECT id INTO v_wallet_id FROM public.group_wallets WHERE group_id = v_res.group_id;

  IF v_wallet_id IS NOT NULL THEN
    UPDATE public.group_wallets
    SET pending_balance = pending_balance + v_group_net,
        total_earned    = total_earned    + v_group_net,
        updated_at      = NOW()
    WHERE id = v_wallet_id;

    INSERT INTO public.wallet_transactions
      (group_wallet_id, group_id, type, amount, reservation_id, description, balance_after)
    SELECT gw.id, gw.group_id, 'credit_pending', v_group_net, p_reservation_id,
      format('Pago MP:%s retenido · evento %s', p_payment_id, v_res.event_date::TEXT),
      gw.pending_balance + v_group_net
    FROM public.group_wallets gw WHERE gw.id = v_wallet_id;

    INSERT INTO public.financial_audit_logs (
      entity_type, entity_id, action, actor_id, actor_role, amount, notes
    ) VALUES (
      'reservation', p_reservation_id, 'hold', NULL, 'system', v_group_net,
      format('MP payment confirmed MP:%s — 20pct markup, earnings held in group_wallet', p_payment_id)
    );

    INSERT INTO public.notifications (user_id, type, title, body, data)
    SELECT g.owner_id, 'payment',
      '⏳ Pago recibido — retenido hasta fin del evento',
      format('$%s MXN reservados para tu grupo. Se liberarán automáticamente cuando termine el evento del %s.',
        to_char(v_group_net, 'FM999,999,990'), v_res.event_date::TEXT),
      jsonb_build_object('reservation_id', p_reservation_id, 'amount', v_group_net, 'screen', 'Wallet')
    FROM public.groups g WHERE g.id = v_res.group_id;
  END IF;

  RETURN jsonb_build_object(
    'ok', true, 'total', v_res.total_price,
    'commission', v_commission, 'group_net', v_group_net,
    'credited_to', 'group_wallet_only', 'model', 'owner_only_20pct_markup'
  );

EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$$;

GRANT EXECUTE ON FUNCTION public.mp_credit_pending_earnings(UUID, TEXT, NUMERIC) TO authenticated;
GRANT EXECUTE ON FUNCTION public.mp_credit_pending_earnings(UUID, TEXT, NUMERIC) TO service_role;

COMMIT;


-- ════════════════════════════════════════════════════════════════════
-- VERIFICACIONES (ejecutar separado, después del COMMIT)
-- ════════════════════════════════════════════════════════════════════

-- V1: Trigger viejo eliminado; trigger nuevo activo
SELECT
  (NOT EXISTS (
    SELECT 1 FROM pg_trigger
    WHERE tgname = 'set_commission_before_insert'
  )) AS trigger_viejo_eliminado,
  EXISTS (
    SELECT 1 FROM pg_trigger t
    JOIN pg_class c ON c.oid = t.tgrelid
    WHERE t.tgname = 'trg_set_reservation_financials'
      AND c.relname = 'reservations'
      AND t.tgenabled = 'O'
  ) AS trigger_nuevo_activo;
-- Esperado: true | true

-- V2: Funciones contienen 1.20 (markup) y NO contienen * 0.10 (comisión inclusiva)
SELECT
  proname,
  pg_get_functiondef(oid) LIKE '%/ 1.20%'  AS tiene_markup_120,
  pg_get_functiondef(oid) NOT LIKE '%* 0.10%' AS no_tiene_010
FROM pg_proc
WHERE proname IN (
  'set_reservation_financials',
  'calculate_commission',
  'confirm_full_payment_and_credit_wallet',
  'confirm_extra_hour_stripe_payment',
  'propose_event_request',
  'client_accept_proposal',
  'distribute_event_earnings',
  'mp_credit_pending_earnings'
)
AND pronamespace = 'public'::regnamespace
ORDER BY proname;
-- Esperado: todas las filas: tiene_markup_120=true, no_tiene_010=true

-- V3: propose_event_request NO tiene 0.15 (express fee eliminado)
SELECT
  pg_get_functiondef(oid) NOT LIKE '%0.15%' AS sin_express_fee_015,
  pg_get_functiondef(oid) LIKE '%1.20%'     AS con_markup_120
FROM pg_proc
WHERE proname = 'propose_event_request' AND pronamespace = 'public'::regnamespace;
-- Esperado: true | true

-- V4: confirm_extra_hour_stripe_payment — idempotente en extras ya pagadas
SELECT
  pg_get_functiondef(oid) LIKE '%already_paid%'  AS skip_si_paid,
  pg_get_functiondef(oid) LIKE '%/ 1.20%'        AS tiene_markup,
  pg_get_functiondef(oid) NOT LIKE '%0.10%'      AS sin_comision_010
FROM pg_proc
WHERE proname = 'confirm_extra_hour_stripe_payment'
  AND pronamespace = 'public'::regnamespace;
-- Esperado: true | true | true

SELECT 'sql/402_commission_20pct.sql listo para aplicar ✅' AS status;
