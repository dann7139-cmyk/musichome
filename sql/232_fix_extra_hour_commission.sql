-- ============================================================
-- sql/232_fix_extra_hour_commission.sql
--
-- Corrige la tasa de comisión de horas extra: 3% → 10%
--
-- Motivo:
--   Después de FASE 1, overtime_Xh_price almacena el precio PÚBLICO
--   (precio_neto_grupo / 0.90). La comisión del 10% ya está implícita
--   en el markup. El modelo correcto es:
--
--     cliente paga:  overtime_price         (precio público)
--     grupo recibe:  overtime_price * 0.90  (su precio neto original)
--     plataforma:    overtime_price * 0.10  (= el markup)
--
--   Con la tasa anterior del 3%, el grupo recibía 97% del precio
--   público (más de su precio neto), y la plataforma cobraba menos
--   de lo que el markup implica.
--
-- Compatibilidad hacia atrás:
--   Las extra_hours históricas ya fueron procesadas (crédito inmediato
--   durante el evento). Este cambio solo afecta llamadas futuras.
--   No hay datos que corregir retroactivamente.
-- ============================================================

CREATE OR REPLACE FUNCTION public.credit_extra_hour_earnings(
  p_reservation_id UUID,
  p_extra_amount   NUMERIC   -- monto total cobrado por hora(s) extra (precio público)
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_res        RECORD;
  v_commission NUMERIC(12,2);
  v_net        NUMERIC(12,2);
  v_admin_id   UUID;
  v_owner_id   UUID;
BEGIN
  SELECT r.*, g.owner_id AS group_owner_id
  INTO   v_res
  FROM   public.reservations r
  JOIN   public.groups g ON g.id = r.group_id
  WHERE  r.id = p_reservation_id;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'reservation_not_found');
  END IF;

  IF p_extra_amount <= 0 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_amount');
  END IF;

  -- 10% comisión (el precio ya es público; el markup = la comisión)
  v_commission := ROUND(p_extra_amount * 0.10, 2);
  v_net        := p_extra_amount - v_commission;   -- 90% al grupo = su precio neto original
  v_admin_id   := public.get_platform_admin_id();
  v_owner_id   := v_res.group_owner_id;

  -- ── 10% al admin (disponible de inmediato) ───────────────────────────
  IF v_admin_id IS NOT NULL THEN
    INSERT INTO public.wallets (user_id)
    VALUES (v_admin_id)
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
       'Comisión 10% hora extra · evento ' || v_res.event_date::TEXT);

    INSERT INTO public.financial_ledger
      (reservation_id, user_id, entry_type, amount, currency, description)
    VALUES
      (p_reservation_id, v_admin_id, 'platform_commission', v_commission, 'mxn',
       'Comisión 10% hora extra · evento ' || v_res.event_date::TEXT);
  END IF;

  -- ── 90% al dueño del grupo (disponible de inmediato) ─────────────────
  IF v_owner_id IS NOT NULL THEN
    INSERT INTO public.wallets (user_id)
    VALUES (v_owner_id)
    ON CONFLICT (user_id) DO NOTHING;

    UPDATE public.wallets
    SET available_balance = available_balance + v_net,
        total_earned      = total_earned + v_net,
        updated_at        = NOW()
    WHERE user_id = v_owner_id;

    INSERT INTO public.wallet_transactions
      (user_id, amount, type, status, reference_event_id, description)
    VALUES
      (v_owner_id, v_net, 'extra_hour', 'completed', p_reservation_id,
       'Ganancia hora extra · evento ' || v_res.event_date::TEXT);

    INSERT INTO public.financial_ledger
      (reservation_id, user_id, entry_type, amount, currency, description)
    VALUES
      (p_reservation_id, v_owner_id, 'extra_hour', v_net, 'mxn',
       'Hora extra · evento ' || v_res.event_date::TEXT);

    INSERT INTO public.notifications
      (user_id, type, title, body, data)
    VALUES
      (v_owner_id, 'payment',
       '💰 Hora extra cobrada',
       'Se agregaron $' || v_net::TEXT ||
       ' MXN a tu billetera por hora(s) extra del evento.',
       jsonb_build_object(
         'reservation_id', p_reservation_id,
         'amount',         v_net,
         'screen',         'Wallet'
       ));
  END IF;

  RETURN jsonb_build_object(
    'ok',          true,
    'extra_amount', p_extra_amount,
    'commission',  v_commission,
    'net',         v_net,
    'admin_id',    v_admin_id,
    'owner_id',    v_owner_id
  );

EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$$;

GRANT EXECUTE ON FUNCTION public.credit_extra_hour_earnings(UUID, NUMERIC) TO authenticated;
GRANT EXECUTE ON FUNCTION public.credit_extra_hour_earnings(UUID, NUMERIC) TO service_role;

SELECT '232_fix_extra_hour_commission.sql: comisión hora extra 3% → 10% ✅' AS status;
