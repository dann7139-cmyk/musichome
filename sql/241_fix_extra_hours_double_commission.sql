-- ============================================================
-- sql/241_fix_extra_hours_double_commission.sql
--
-- Fix: doble crédito de comisión admin en overtime
--
-- Problema:
--   group_confirm_extra_hours (sql/135) creditaba admin wallet.
--   credit_extra_hour_earnings (sql/240) también creditaba admin wallet.
--   Resultado: admin recibía 2× comisión por cada overtime.
--
-- Fix:
--   Eliminar el bloque de comisión admin de group_confirm_extra_hours.
--   credit_extra_hour_earnings es el único responsable de acreditar:
--     - Comisión admin (10%)  → wallets (MXN) o wallets USD
--     - Ganancia grupo (90%)  → group_wallets (MXN o USD)
--
-- Lo que NO cambia:
--   - FOR UPDATE en extra_hours (idempotencia)
--   - Guards: extra_not_found, already_processed, reservation_not_found
--   - extra_hours.status = 'accepted' + group_confirmed_at
--   - reservations.extra_hours_added
--   - Bloque de ganancia neta al owner (wallets legacy — invisible en WalletScreen)
--   - Notificaciones al grupo y al cliente
--   - EXCEPTION handler
-- ============================================================

CREATE OR REPLACE FUNCTION public.group_confirm_extra_hours(
  p_extra_id UUID
)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_extra      RECORD;
  v_res        RECORD;
  v_owner_id   UUID;
  v_commission NUMERIC(12,2);
  v_net        NUMERIC(12,2);
BEGIN
  SELECT * INTO v_extra
  FROM   public.extra_hours
  WHERE  id = p_extra_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'extra_not_found');
  END IF;

  IF v_extra.status NOT IN ('pending', 'client_requested') THEN
    RETURN jsonb_build_object('ok', true, 'skipped', true, 'reason', 'already_processed');
  END IF;

  SELECT r.*, g.owner_id AS group_owner_id
  INTO   v_res
  FROM   public.reservations r
  JOIN   public.groups g ON g.id = r.group_id
  WHERE  r.id = v_extra.reservation_id;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'reservation_not_found');
  END IF;

  v_commission := v_extra.platform_commission;
  v_net        := v_extra.group_extra_earnings;
  v_owner_id   := v_res.group_owner_id;

  -- Actualizar estado de horas extra
  UPDATE public.extra_hours
  SET status             = 'accepted',
      group_confirmed_at = NOW()
  WHERE id = p_extra_id;

  -- Extender el evento: sumar horas al total
  UPDATE public.reservations
  SET extra_hours_added = COALESCE(extra_hours_added, 0) + v_extra.hours_added
  WHERE id = v_extra.reservation_id;

  -- ── Comisión admin: eliminada de esta función ──────────────────────────
  -- credit_extra_hour_earnings (sql/240) es el único responsable.
  -- Eliminado para evitar doble crédito de comisión al admin.

  -- ── Ganancia neta: disponible de inmediato para el grupo ──────────────
  IF v_owner_id IS NOT NULL AND v_net > 0 THEN
    INSERT INTO public.wallets (user_id) VALUES (v_owner_id)
      ON CONFLICT (user_id) DO NOTHING;

    UPDATE public.wallets
    SET available_balance = available_balance + v_net,
        pending_balance   = GREATEST(0, pending_balance - v_commission),
        total_earned      = total_earned + v_net,
        updated_at        = NOW()
    WHERE user_id = v_owner_id;

    INSERT INTO public.wallet_transactions
      (user_id, amount, type, status, reference_event_id, description)
    VALUES
      (v_owner_id, v_net, 'extra_hour', 'completed', v_extra.reservation_id,
       'Hora extra confirmada · evento ' || v_res.event_date::TEXT);

    INSERT INTO public.financial_ledger
      (reservation_id, user_id, entry_type, amount, currency, description)
    VALUES
      (v_extra.reservation_id, v_owner_id, 'extra_hour', v_net, 'mxn',
       'Hora extra · evento ' || v_res.event_date::TEXT);

    -- Notificar al grupo
    INSERT INTO public.notifications (user_id, type, title, body, data)
    VALUES (v_owner_id, 'payment',
      '💰 Hora extra registrada',
      '+$' || v_net::TEXT || ' MXN en tu billetera por ' || v_extra.hours_added || 'h extra.',
      jsonb_build_object('reservation_id', v_extra.reservation_id, 'amount', v_net, 'screen', 'Wallet'));
  END IF;

  -- Notificar al cliente que el grupo confirmó
  IF v_res.client_id IS NOT NULL THEN
    INSERT INTO public.notifications (user_id, type, title, body, data)
    VALUES (v_res.client_id, 'reservation',
      '✅ ¡' || v_extra.hours_added || 'h extra confirmadas!',
      'El grupo confirmó que continuará el servicio. El timer se extendió.',
      jsonb_build_object(
        'reservation_id', v_extra.reservation_id,
        'hours_added',    v_extra.hours_added,
        'screen',         'LiveEvent'
      ));
  END IF;

  RETURN jsonb_build_object(
    'ok',          true,
    'extra_id',    p_extra_id,
    'hours_added', v_extra.hours_added,
    'commission',  v_commission,
    'net',         v_net
  );

EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$$;

GRANT EXECUTE ON FUNCTION public.group_confirm_extra_hours(UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION public.group_confirm_extra_hours(UUID) TO service_role;

-- ── Verificación: confirmar que el bloque admin fue eliminado ─────────────────
DO $$
DECLARE
  v_src TEXT;
BEGIN
  SELECT prosrc INTO v_src
  FROM pg_proc p
  JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public' AND p.proname = 'group_confirm_extra_hours';

  IF v_src LIKE '%get_platform_admin_id%' THEN
    RAISE WARNING '[241] ALERTA: bloque admin sigue presente en group_confirm_extra_hours';
  ELSE
    RAISE NOTICE '[241] group_confirm_extra_hours: bloque admin eliminado correctamente ✅';
  END IF;
END;
$$;

SELECT '241_fix_extra_hours_double_commission.sql: doble comisión admin corregida ✅' AS status;
