-- ============================================================================
-- ROLLBACK sql/652_concierge_extra_hours_admin_notify.sql
-- Restaura las 3 funciones a como quedaron antes de este archivo (sin el
-- aviso de conserjería al admin en pagos de horas extra, sin
-- negotiated_hourly en la cola de eventos en vivo).
-- ⚠️ NO correr salvo emergencia deliberada.
-- ============================================================================

CREATE OR REPLACE FUNCTION public.approve_extra_hour_payment_atomic(p_extra_hour_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_extra          RECORD;
  v_reservation    RECORD;
  v_caller_id      UUID    := auth.uid();
  v_before_balance NUMERIC;
  v_after_balance  NUMERIC;
  v_action         TEXT;
  v_group_owner_id UUID;
  v_gw             RECORD;
  v_admin_id       UUID;
  v_group_amount   NUMERIC(12,2);
  v_admin_amount   NUMERIC(12,2);
  v_gw_bal_after   NUMERIC(14,2);
BEGIN
  IF v_caller_id IS NULL THEN
    RAISE EXCEPTION 'unauthorized: sesión requerida';
  END IF;

  SELECT * INTO v_extra
  FROM   public.extra_hours
  WHERE  id = p_extra_hour_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Hora extra no encontrada: %', p_extra_hour_id;
  END IF;

  IF v_extra.status = 'paid' THEN
    RETURN jsonb_build_object('ok', true, 'skipped', true, 'reason', 'already_paid');
  END IF;

  IF v_extra.status = 'rejected' THEN
    RAISE EXCEPTION 'Esta hora extra fue rechazada y no puede aprobarse';
  END IF;

  SELECT * INTO v_reservation
  FROM   public.reservations
  WHERE  id = v_extra.reservation_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Reserva no encontrada para esta hora extra';
  END IF;

  IF v_reservation.client_id != v_caller_id THEN
    RAISE EXCEPTION 'unauthorized: solo el cliente de la reserva puede aprobar horas extra';
  END IF;

  SELECT owner_id INTO v_group_owner_id
  FROM   public.groups
  WHERE  id = v_reservation.group_id;

  v_before_balance := COALESCE(v_reservation.client_available_balance, 0);

  IF v_extra.is_cash_payment THEN
    UPDATE public.extra_hours
    SET    status = 'paid', payout_status = 'released'
    WHERE  id = p_extra_hour_id;
    v_after_balance := v_before_balance;
    v_action        := 'extra_approved_cash';
  ELSE
    IF v_extra.currency_code IS NULL OR v_extra.currency_code NOT IN ('MXN', 'USD') THEN
      RAISE EXCEPTION 'unsupported_currency: %', v_extra.currency_code;
    END IF;

    IF v_before_balance < COALESCE(v_extra.total_extra_cost, 0) THEN
      RAISE EXCEPTION 'Saldo insuficiente: disponible=$%, requerido=$%',
        v_before_balance, v_extra.total_extra_cost;
    END IF;

    UPDATE public.extra_hours
    SET    status = 'paid', payout_status = 'released'
    WHERE  id = p_extra_hour_id;

    UPDATE public.reservations
    SET    client_available_balance =
             GREATEST(0, COALESCE(client_available_balance, 0) - COALESCE(v_extra.total_extra_cost, 0))
    WHERE  id = v_reservation.id
    RETURNING client_available_balance INTO v_after_balance;

    v_group_amount := COALESCE(v_extra.group_extra_earnings, 0);
    v_admin_amount := COALESCE(v_extra.total_extra_cost, 0) - v_group_amount;

    PERFORM public.ensure_group_wallet(v_reservation.group_id);
    SELECT * INTO v_gw FROM public.group_wallets WHERE group_id = v_reservation.group_id FOR UPDATE;

    IF v_extra.currency_code = 'USD' THEN
      v_gw_bal_after := COALESCE(v_gw.available_balance_usd, 0) + v_group_amount;
      UPDATE public.group_wallets
      SET available_balance_usd = v_gw_bal_after,
          total_earned_usd      = COALESCE(total_earned_usd, 0) + v_group_amount,
          updated_at            = NOW()
      WHERE id = v_gw.id;
    ELSE
      v_gw_bal_after := COALESCE(v_gw.available_balance, 0) + v_group_amount;
      UPDATE public.group_wallets
      SET available_balance = v_gw_bal_after,
          total_earned      = COALESCE(total_earned, 0) + v_group_amount,
          updated_at        = NOW()
      WHERE id = v_gw.id;
    END IF;

    INSERT INTO public.wallet_transactions
      (group_wallet_id, group_id, type, amount, reservation_id, description, balance_after, currency_code)
    VALUES
      (v_gw.id, v_reservation.group_id, 'extra_hour', v_group_amount, v_reservation.id,
       'Ganancia hora extra (aprobada por cliente) · reserva ' || v_reservation.id::TEXT,
       v_gw_bal_after, v_extra.currency_code);

    v_admin_id := public.get_platform_admin_id();
    IF v_admin_id IS NOT NULL THEN
      INSERT INTO public.wallets (user_id) VALUES (v_admin_id) ON CONFLICT (user_id) DO NOTHING;

      IF v_extra.currency_code = 'USD' THEN
        UPDATE public.wallets
        SET available_balance_usd = COALESCE(available_balance_usd, 0) + v_admin_amount,
            total_earned_usd      = COALESCE(total_earned_usd, 0) + v_admin_amount,
            updated_at            = NOW()
        WHERE user_id = v_admin_id;
      ELSE
        UPDATE public.wallets
        SET available_balance = available_balance + v_admin_amount,
            total_earned      = COALESCE(total_earned, 0) + v_admin_amount,
            updated_at        = NOW()
        WHERE user_id = v_admin_id;
      END IF;

      INSERT INTO public.wallet_transactions
        (user_id, type, amount, reservation_id, description, currency_code)
      VALUES
        (v_admin_id, 'commission', v_admin_amount, v_reservation.id,
         'Comisión hora extra (aprobada por cliente) · reserva ' || v_reservation.id::TEXT,
         v_extra.currency_code);
    END IF;

    v_action := 'extra_approved_balance';
  END IF;

  INSERT INTO public.financial_audit_logs (
    entity_type, entity_id, action, actor_id, actor_role,
    before_state, after_state, amount, notes
  ) VALUES (
    'extra_hour', p_extra_hour_id, v_action, v_caller_id, 'client',
    jsonb_build_object(
      'client_available_balance', v_before_balance,
      'extra_hour_status',        v_extra.status,
      'reservation_id',           v_reservation.id
    ),
    jsonb_build_object(
      'client_available_balance', COALESCE(v_after_balance, v_before_balance),
      'extra_hour_status',        'paid',
      'reservation_id',           v_reservation.id
    ),
    COALESCE(v_extra.total_extra_cost, 0),
    CASE v_action
      WHEN 'extra_approved_cash'    THEN 'Hora extra aprobada (efectivo) · reserva ' || v_reservation.id::TEXT
      WHEN 'extra_approved_balance' THEN 'Hora extra aprobada (saldo) · reserva '   || v_reservation.id::TEXT
    END
  );

  IF v_extra.is_cash_payment THEN

    IF v_group_owner_id IS NOT NULL THEN
      INSERT INTO public.notifications (user_id, type, title, body, data)
      VALUES (
        v_group_owner_id,
        'extra_hour_approved_by_client',
        '✅ Cliente acordó hora extra en efectivo',
        'El cliente acordó pago en efectivo de $' ||
          COALESCE(v_extra.total_extra_cost, 0)::TEXT ||
          ' MXN. Confirma cuando lo recibas.',
        jsonb_build_object(
          'screen',         'EventTimer',
          'reservation_id', v_reservation.id,
          'extra_hour_id',  p_extra_hour_id
        )
      );
    END IF;

    INSERT INTO public.notifications (user_id, type, title, body, data)
    VALUES (
      v_caller_id,
      'reservation',
      '💵 Hora extra — pago en efectivo',
      'Acordaste pagar $' || COALESCE(v_extra.total_extra_cost, 0)::TEXT ||
        ' MXN en efectivo al grupo. No se descontó de tu saldo.',
      jsonb_build_object(
        'screen',         'ClientExtraHours',
        'reservation_id', v_reservation.id,
        'extra_hour_id',  p_extra_hour_id
      )
    );

  ELSE

    IF v_group_owner_id IS NOT NULL THEN
      INSERT INTO public.notifications (user_id, type, title, body, data)
      VALUES (
        v_group_owner_id,
        'extra_hour_approved_by_client',
        '✅ Cliente aprobó hora extra',
        'El cliente aprobó y pagó ' || COALESCE(v_extra.hours_added, 1)::TEXT ||
          'h extra ($' || COALESCE(v_extra.total_extra_cost, 0)::TEXT ||
          ' MXN). Confirma para continuar el evento.',
        jsonb_build_object(
          'screen',         'EventTimer',
          'reservation_id', v_reservation.id,
          'extra_hour_id',  p_extra_hour_id
        )
      );
    END IF;

    INSERT INTO public.notifications (user_id, type, title, body, data)
    VALUES (
      v_caller_id,
      'extra_hour_payment_confirmed',
      '💳 Cobro confirmado',
      'Se descontaron $' || COALESCE(v_extra.total_extra_cost, 0)::TEXT ||
        ' MXN de tu saldo por ' || COALESCE(v_extra.hours_added, 1)::TEXT ||
        'h extra. Saldo restante: $' ||
        COALESCE(v_after_balance, 0)::TEXT || ' MXN.',
      jsonb_build_object(
        'screen',         'ClientExtraHours',
        'reservation_id', v_reservation.id,
        'extra_hour_id',  p_extra_hour_id
      )
    );

  END IF;

  RETURN jsonb_build_object(
    'ok',             true,
    'skipped',        false,
    'is_cash',        v_extra.is_cash_payment,
    'amount',         COALESCE(v_extra.total_extra_cost, 0),
    'before_balance', v_before_balance,
    'after_balance',  COALESCE(v_after_balance, v_before_balance)
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.confirm_extra_hour_stripe_payment(p_extra_id uuid, p_stripe_payment_id text, p_amount_paid numeric, p_currency text, p_stripe_fee numeric DEFAULT NULL::numeric)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_extra         RECORD;
  v_group_id      UUID;
  v_owner_id      UUID;
  v_client_id     UUID;
  v_res_id        UUID;
  v_wallet        RECORD;
  v_earnings      NUMERIC(12,2);
  v_bal_after     NUMERIC(14,2);
  v_service_fee   NUMERIC(12,2);
  v_stripe_fee    NUMERIC(12,2);
  v_admin_neto    NUMERIC(12,2);
  v_admin_id      UUID;
  v_currency      TEXT;
  v_paid_currency TEXT;
  v_curr_label    TEXT;
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

  v_currency      := v_extra.currency_code;
  v_paid_currency := UPPER(COALESCE(p_currency, ''));

  IF v_paid_currency IS DISTINCT FROM v_currency THEN
    INSERT INTO public.financial_audit_logs (
      entity_type, entity_id, action, actor_id, actor_role,
      before_state, after_state, amount, notes
    ) VALUES (
      'extra_hour', p_extra_id, 'currency_mismatch_blocked', NULL, 'stripe_webhook',
      jsonb_build_object('status', v_extra.status, 'expected_currency', v_currency),
      jsonb_build_object(
        'expected_currency',        v_currency,
        'received_currency',        v_paid_currency,
        'stripe_payment_intent_id', p_stripe_payment_id
      ),
      p_amount_paid,
      'Pago Stripe hora extra BLOQUEADO: moneda esperada ' || COALESCE(v_currency, 'NULL') ||
        ' recibida ' || COALESCE(NULLIF(v_paid_currency, ''), 'NULL')
    );

    RETURN jsonb_build_object(
      'ok',       false,
      'error',    'currency_mismatch',
      'expected', v_currency,
      'received', v_paid_currency
    );
  END IF;

  SELECT g.owner_id INTO v_owner_id FROM public.groups g WHERE g.id = v_group_id;

  SELECT * INTO v_wallet FROM public.group_wallets WHERE group_id = v_group_id FOR UPDATE;
  IF NOT FOUND THEN
    INSERT INTO public.group_wallets (group_id) VALUES (v_group_id) RETURNING * INTO v_wallet;
  END IF;

  v_earnings := ROUND(COALESCE(v_extra.group_extra_earnings, 0), 2);

  v_service_fee := ROUND(
    v_extra.total_extra_cost
    - COALESCE(v_extra.group_extra_earnings, ROUND(v_extra.total_extra_cost / 1.20, 2)),
    2
  );
  v_stripe_fee := COALESCE(p_stripe_fee, ROUND(v_extra.total_extra_cost * 0.036 + 3, 2));
  v_admin_neto := GREATEST(0, v_service_fee - v_stripe_fee);
  v_curr_label := CASE WHEN v_currency = 'USD' THEN 'USD' ELSE 'MXN' END;

  IF v_currency = 'USD' THEN
    v_bal_after := COALESCE(v_wallet.pending_balance_usd, 0) + v_earnings;

    UPDATE public.group_wallets
    SET pending_balance_usd = v_bal_after,
        total_earned_usd    = COALESCE(total_earned_usd, 0) + v_earnings,
        updated_at          = NOW()
    WHERE group_id = v_group_id;
  ELSE
    v_bal_after := COALESCE(v_wallet.pending_balance, 0) + v_earnings;

    UPDATE public.group_wallets
    SET pending_balance = v_bal_after,
        total_earned    = COALESCE(total_earned, 0) + v_earnings,
        updated_at      = NOW()
    WHERE group_id = v_group_id;
  END IF;

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
    mp_payment_id, description, balance_after, currency_code
  ) VALUES (
    v_wallet.id, v_group_id, 'extra_hour', v_earnings, v_res_id,
    p_stripe_payment_id,
    'Hora extra (Stripe) — retenida hasta fin de evento',
    v_bal_after, v_currency
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
      'currency',          v_currency,
      'service_fee',       v_service_fee,
      'stripe_fee',        v_stripe_fee,
      'admin_neto',        v_admin_neto
    ),
    p_amount_paid,
    'Pago Stripe hora extra confirmado por webhook'
  );

  SELECT id INTO v_admin_id FROM public.profiles WHERE role = 'admin' ORDER BY created_at LIMIT 1;
  IF v_admin_id IS NOT NULL THEN
    INSERT INTO public.wallets (user_id, available_balance, pending_balance, total_earned)
    VALUES (v_admin_id, 0, 0, 0)
    ON CONFLICT (user_id) DO NOTHING;

    IF v_currency = 'USD' THEN
      UPDATE public.wallets
      SET available_balance_usd = COALESCE(available_balance_usd, 0) + v_admin_neto,
          total_earned_usd      = COALESCE(total_earned_usd, 0) + v_admin_neto,
          updated_at            = NOW()
      WHERE user_id = v_admin_id;
    ELSE
      UPDATE public.wallets
      SET available_balance = available_balance + v_admin_neto,
          total_earned      = COALESCE(total_earned, 0) + v_admin_neto,
          updated_at        = NOW()
      WHERE user_id = v_admin_id;
    END IF;

    INSERT INTO public.wallet_transactions (
      user_id, type, amount, reservation_id, description, currency_code
    ) VALUES (
      v_admin_id, 'platform_income', v_admin_neto, v_res_id,
      format('Comisión extra-hora $%s − Stripe $%s = $%s neto — extra %s',
        v_service_fee::TEXT, v_stripe_fee::TEXT, v_admin_neto::TEXT, p_extra_id),
      v_currency
    );
  END IF;

  IF v_owner_id IS NOT NULL THEN
    INSERT INTO public.notifications (user_id, type, title, body, data)
    VALUES (
      v_owner_id, 'extra_hour_approved_by_client',
      '💰 ' || v_extra.hours_added || 'h extra pagadas con tarjeta',
      'El cliente pagó $' || ROUND(v_extra.total_extra_cost)::TEXT ||
        ' ' || v_curr_label || '. Las ganancias ($' || ROUND(v_earnings)::TEXT || ') se liberan al terminar.',
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
    'currency', v_currency,
    'service_fee', v_service_fee, 'stripe_fee', v_stripe_fee, 'admin_neto', v_admin_neto
  );

EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$function$;

CREATE OR REPLACE FUNCTION public.admin_get_concierge_live_reservations(p_limit integer DEFAULT 50)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_caller_role TEXT;
  v_result      JSONB;
BEGIN
  SELECT role INTO v_caller_role FROM profiles WHERE id = auth.uid();
  IF v_caller_role NOT IN ('admin', 'admin_ops') THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_admin');
  END IF;

  SELECT jsonb_build_object(
    'ok', true,
    'items', COALESCE(jsonb_agg(x.item ORDER BY x.event_started_at ASC NULLS LAST), '[]'::jsonb)
  )
  INTO v_result
  FROM (
    SELECT
      r.event_started_at,
      jsonb_build_object(
        'reservation_id',   r.id,
        'group_id',         g.id,
        'group_name',       g.name,
        'group_phone',      po.phone,
        'client_name',      cp.full_name,
        'client_phone',     cp.phone,
        'event_date',       r.event_date,
        'hours_count',      r.hours_count,
        'event_started_at', r.event_started_at,
        'address',          r.address,
        'country',          COALESCE(g.country, 'México')
      ) AS item
    FROM reservations r
    JOIN groups g ON g.id = r.group_id
    LEFT JOIN profiles po ON po.id = g.owner_id
    LEFT JOIN profiles cp ON cp.id = r.client_id
    WHERE r.status = 'in_progress'
      AND g.concierge_mode = true
      AND (v_caller_role = 'admin' OR country_code_of(g.country) = admin_ops_country())
    ORDER BY r.event_started_at ASC NULLS LAST
    LIMIT p_limit
  ) x;

  RETURN v_result;
END;
$function$;
