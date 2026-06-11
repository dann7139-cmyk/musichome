-- ════════════════════════════════════════════════════════════════════
-- 79_notify_client_on_event_complete.sql
-- Actualiza distribute_event_earnings para:
--   1. Notificar al CLIENTE que su evento terminó
--   2. Invitarlo a calificar al grupo (deep-link a EventTimer)
-- ════════════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION public.distribute_event_earnings(
  p_reservation_id UUID
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_res         RECORD;
  v_commission  NUMERIC(12,2);
  v_group_net   NUMERIC(12,2);
  v_payout      RECORD;
  v_owner_id    UUID;
  v_group_name  TEXT;
  v_result      JSONB;
  v_distributed INT := 0;
BEGIN
  -- ── 0. Bloquear la fila para evitar doble ejecución ──────────────────────
  SELECT *
  INTO v_res
  FROM public.reservations
  WHERE id = p_reservation_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'reservation_not_found');
  END IF;

  -- Idempotente: si ya se distribuyó, devolver OK sin volver a hacerlo
  IF v_res.wallet_distributed THEN
    RETURN jsonb_build_object('ok', true, 'skipped', true, 'reason', 'already_distributed');
  END IF;

  -- ── 1. Calcular comisión (8%) ─────────────────────────────────────────────
  v_commission := ROUND(v_res.total_price * 0.08, 2);
  v_group_net  := v_res.total_price - v_commission;

  -- ── 2. Actualizar columnas de comisión en la reserva ─────────────────────
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

  -- ── 3. Registrar comisión de plataforma en financial_ledger ───────────────
  INSERT INTO public.financial_ledger
    (reservation_id, entry_type, amount, currency, description)
  VALUES
    (p_reservation_id, 'platform_commission', v_commission, 'mxn',
     'Comisión 8% – evento ' || v_res.event_date::TEXT);

  -- ── 4. Obtener nombre del grupo para la notificación al cliente ───────────
  SELECT name INTO v_group_name
  FROM public.groups
  WHERE id = v_res.group_id;

  -- ── 5. Notificar al CLIENTE que su evento terminó y pedir calificación ────
  IF v_res.client_id IS NOT NULL THEN
    INSERT INTO public.notifications (user_id, type, title, body, data)
    VALUES (
      v_res.client_id,
      'reservation',
      '⭐ ¿Cómo estuvo el evento?',
      '¡Tu evento con ' || COALESCE(v_group_name, 'el grupo') || ' del ' ||
        TO_CHAR(v_res.event_date, 'DD/MM/YYYY') ||
        ' ha terminado! Cuéntanos cómo te fue.',
      jsonb_build_object(
        'reservation_id', p_reservation_id,
        'screen',         'EventTimer',
        'params',         jsonb_build_object(
          'reservationId', p_reservation_id,
          'readOnly',      true,
          'userRole',      'client'
        )
      )
    );
  END IF;

  -- ── 6. Distribuir a cada usuario según event_payouts ─────────────────────
  FOR v_payout IN
    SELECT ep.user_id, ep.amount, ep.role
    FROM   public.event_payouts ep
    WHERE  ep.reservation_id = p_reservation_id
      AND  ep.payout_status  = 'pending'
      AND  ep.amount         > 0
  LOOP
    -- Crear wallet si no existe aún
    INSERT INTO public.wallets (user_id)
    VALUES (v_payout.user_id)
    ON CONFLICT (user_id) DO NOTHING;

    -- Sumar a la wallet
    UPDATE public.wallets
    SET available_balance = available_balance + v_payout.amount,
        total_earned      = total_earned      + v_payout.amount,
        updated_at        = NOW()
    WHERE user_id = v_payout.user_id;

    -- Registrar transacción
    INSERT INTO public.wallet_transactions
      (user_id, amount, type, status, reference_event_id, description)
    VALUES
      (v_payout.user_id,
       v_payout.amount,
       'event_earning',
       'completed',
       p_reservation_id,
       'Ganancia evento ' || v_res.event_date::TEXT || ' (' || v_payout.role || ')');

    -- Registrar en financial_ledger
    INSERT INTO public.financial_ledger
      (reservation_id, user_id, entry_type, amount, currency, description)
    VALUES
      (p_reservation_id,
       v_payout.user_id,
       CASE v_payout.role
         WHEN 'owner'   THEN 'group_transfer'
         WHEN 'member'  THEN 'member_transfer'
         WHEN 'invited' THEN 'talent_transfer'
         ELSE 'group_transfer'
       END,
       v_payout.amount,
       'mxn',
       'Pago evento ' || v_res.event_date::TEXT);

    -- Marcar payout como pagado
    UPDATE public.event_payouts
    SET payout_status = 'paid'
    WHERE reservation_id = p_reservation_id
      AND user_id        = v_payout.user_id;

    -- Notificar al usuario (grupo/talento) sobre su pago
    INSERT INTO public.notifications
      (user_id, type, title, body, data)
    VALUES
      (v_payout.user_id,
       'payment',
       '💰 Pago agregado a tu billetera',
       'Tu pago de $' || v_payout.amount::TEXT || ' MXN del evento del ' ||
         TO_CHAR(v_res.event_date, 'DD/MM/YYYY') || ' fue acreditado.',
       jsonb_build_object(
         'reservation_id', p_reservation_id,
         'amount',         v_payout.amount,
         'screen',         'Wallet'
       ));

    v_distributed := v_distributed + 1;
  END LOOP;

  -- ── 7. Si event_payouts estaba vacío, pagar todo al dueño del grupo ────────
  IF v_distributed = 0 THEN
    SELECT g.owner_id INTO v_owner_id
    FROM   public.groups g
    WHERE  g.id = v_res.group_id;

    IF v_owner_id IS NOT NULL THEN
      INSERT INTO public.wallets (user_id)
      VALUES (v_owner_id)
      ON CONFLICT (user_id) DO NOTHING;

      UPDATE public.wallets
      SET available_balance = available_balance + v_group_net,
          total_earned      = total_earned      + v_group_net,
          updated_at        = NOW()
      WHERE user_id = v_owner_id;

      INSERT INTO public.wallet_transactions
        (user_id, amount, type, status, reference_event_id, description)
      VALUES
        (v_owner_id, v_group_net, 'event_earning', 'completed',
         p_reservation_id, 'Ganancia evento ' || v_res.event_date::TEXT || ' (owner)');

      INSERT INTO public.financial_ledger
        (reservation_id, user_id, entry_type, amount, currency, description)
      VALUES
        (p_reservation_id, v_owner_id, 'group_transfer', v_group_net, 'mxn',
         'Pago evento ' || v_res.event_date::TEXT);

      INSERT INTO public.notifications
        (user_id, type, title, body, data)
      VALUES
        (v_owner_id, 'payment',
         '💰 Pago agregado a tu billetera',
         'Tu pago de $' || v_group_net::TEXT || ' MXN del evento del ' ||
           TO_CHAR(v_res.event_date, 'DD/MM/YYYY') || ' fue acreditado.',
         jsonb_build_object('reservation_id', p_reservation_id, 'amount', v_group_net, 'screen', 'Wallet'));

      v_distributed := 1;
    END IF;
  END IF;

  -- ── 8. Notificar a administradores ────────────────────────────────────────
  INSERT INTO public.notifications
    (user_id, type, title, body, data)
  SELECT
    p.id,
    'payment',
    '📊 Evento completado — comisión $' || v_commission::TEXT,
    'El evento del ' || v_res.event_date::TEXT || ' fue completado. Comisión: $' || v_commission::TEXT || ' MXN.',
    jsonb_build_object('reservation_id', p_reservation_id, 'commission', v_commission)
  FROM public.profiles p
  WHERE p.role = 'admin';

  v_result := jsonb_build_object(
    'ok',          true,
    'reservation', p_reservation_id,
    'total',       v_res.total_price,
    'commission',  v_commission,
    'group_net',   v_group_net,
    'distributed', v_distributed
  );

  RETURN v_result;

EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$$;

GRANT EXECUTE ON FUNCTION public.distribute_event_earnings(UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION public.distribute_event_earnings(UUID) TO service_role;

SELECT '79_notify_client_on_event_complete: distribute_event_earnings con notificación al cliente ✅' AS status;
