-- ════════════════════════════════════════════════════════════════════
-- sql/352_fix_extra_hour_credit.sql
--
-- Ronda 1 — Fix bugs financieros #1 + #2 en flujo de horas extra.
--
-- Bug #1: credit_extra_hour_earnings acreditaba a wallets (legacy).
--   El grupo nunca veía ni podía retirar sus ganancias de horas extra
--   porque WalletScreen y payout_requests usan group_wallets.
--
-- Bug #2: group_confirm_extra_hours también acreditaba 90% a wallets
--   (legacy), causando doble crédito: el grupo recibía 180% del monto
--   en wallets (invisible e irretirable) y 0% en group_wallets.
--
-- Fix A — group_confirm_extra_hours:
--   Elimina bloques UPDATE wallets / INSERT wallet_transactions /
--   INSERT financial_ledger del grupo. Queda como coordinadora de
--   estado (accepted + horas + notificaciones). No toca dinero.
--
-- Fix B — credit_extra_hour_earnings:
--   Cambia UPDATE wallets → UPDATE group_wallets para el 90% del
--   grupo. Admin mantiene wallets (correcto — admin usa tabla legacy).
--   Agrega guard de idempotencia: si ya existe wallet_transactions
--   con (owner_id, reservation_id, type='extra_hour', amount=v_net),
--   retorna skipped sin acreditar.
--
-- Contexto: cero extras procesadas en producción — no hay datos
-- históricos que migrar. EventTimerScreen puede seguir llamando
-- ambas RPCs en secuencia; group_confirm_extra_hours ya no toca
-- dinero, solo cambia estado.
--
-- Requiere: sql/184a_tables.sql (group_wallets creada).
-- ════════════════════════════════════════════════════════════════════

-- ── A. group_confirm_extra_hours — coordinadora de estado únicamente ─────────

CREATE OR REPLACE FUNCTION public.group_confirm_extra_hours(
  p_extra_id UUID
)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_extra    RECORD;
  v_res      RECORD;
  v_owner_id UUID;
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

  v_owner_id := v_res.group_owner_id;

  -- Estado: accepted + timestamp
  UPDATE public.extra_hours
  SET status             = 'accepted',
      group_confirmed_at = NOW()
  WHERE id = p_extra_id;

  -- Extender el evento en reservations
  UPDATE public.reservations
  SET extra_hours_added = COALESCE(extra_hours_added, 0) + v_extra.hours_added
  WHERE id = v_extra.reservation_id;

  -- Notificar al dueño del grupo (el crédito real lo hace credit_extra_hour_earnings)
  IF v_owner_id IS NOT NULL THEN
    INSERT INTO public.notifications (user_id, type, title, body, data)
    VALUES (
      v_owner_id, 'payment',
      '💰 Hora extra registrada',
      v_extra.hours_added || 'h extra confirmadas. Las ganancias se acreditarán en tu billetera.',
      jsonb_build_object(
        'reservation_id', v_extra.reservation_id,
        'hours_added',    v_extra.hours_added,
        'screen',         'Wallet'
      )
    );
  END IF;

  -- Notificar al cliente
  IF v_res.client_id IS NOT NULL THEN
    INSERT INTO public.notifications (user_id, type, title, body, data)
    VALUES (
      v_res.client_id, 'reservation',
      '✅ ¡' || v_extra.hours_added || 'h extra confirmadas!',
      'El grupo confirmó que continuará el servicio. El timer se extendió.',
      jsonb_build_object(
        'reservation_id', v_extra.reservation_id,
        'hours_added',    v_extra.hours_added,
        'screen',         'LiveEvent'
      )
    );
  END IF;

  RETURN jsonb_build_object(
    'ok',          true,
    'extra_id',    p_extra_id,
    'hours_added', v_extra.hours_added
  );

EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$$;

GRANT EXECUTE ON FUNCTION public.group_confirm_extra_hours(UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION public.group_confirm_extra_hours(UUID) TO service_role;

-- ── B. credit_extra_hour_earnings — acredita a group_wallets ─────────────────

CREATE OR REPLACE FUNCTION public.credit_extra_hour_earnings(
  p_reservation_id UUID,
  p_extra_amount   NUMERIC   -- monto total cobrado al cliente (precio público)
)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_res        RECORD;
  v_commission NUMERIC(12,2);
  v_net        NUMERIC(12,2);
  v_admin_id   UUID;
  v_owner_id   UUID;
  v_group_id   UUID;
BEGIN
  SELECT r.*, g.id AS grp_id, g.owner_id AS group_owner_id
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

  v_commission := ROUND(p_extra_amount * 0.10, 2);
  v_net        := p_extra_amount - v_commission;   -- 90% al grupo
  v_admin_id   := public.get_platform_admin_id();
  v_owner_id   := v_res.group_owner_id;
  v_group_id   := v_res.grp_id;

  -- ── Guard de idempotencia ──────────────────────────────────────────────────
  -- Previene doble acreditación si credit_extra_hour_earnings se llama dos
  -- veces para el mismo monto en la misma reserva (ej. re-render del grupo,
  -- retry de red, o llamada duplicada desde EventTimerScreen).
  IF EXISTS (
    SELECT 1
    FROM   public.wallet_transactions
    WHERE  user_id            = v_owner_id
      AND  reference_event_id = p_reservation_id
      AND  type               = 'extra_hour'
      AND  amount             = v_net
  ) THEN
    RETURN jsonb_build_object(
      'ok',      true,
      'skipped', true,
      'reason',  'already_credited'
    );
  END IF;

  -- ── 10% comisión al admin (wallets legacy — admin usa esta tabla) ─────────
  -- Admin NO usa group_wallets: correcto dejar wallets aquí.
  IF v_admin_id IS NOT NULL THEN
    INSERT INTO public.wallets (user_id)
    VALUES (v_admin_id)
    ON CONFLICT (user_id) DO NOTHING;

    UPDATE public.wallets
    SET available_balance = available_balance + v_commission,
        total_earned      = total_earned      + v_commission,
        updated_at        = NOW()
    WHERE user_id = v_admin_id;

    INSERT INTO public.wallet_transactions
      (user_id, amount, type, status, reference_event_id, description)
    VALUES
      (v_admin_id, v_commission, 'commission', 'completed', p_reservation_id,
       'Comisión 10% hora extra · ' || v_res.event_date::TEXT);

    INSERT INTO public.financial_ledger
      (reservation_id, user_id, entry_type, amount, currency, description)
    VALUES
      (p_reservation_id, v_admin_id, 'platform_commission', v_commission, 'mxn',
       'Comisión 10% hora extra · ' || v_res.event_date::TEXT);
  END IF;

  -- ── 90% al grupo → group_wallets (visible en WalletScreen, retirable) ─────
  IF v_owner_id IS NOT NULL AND v_group_id IS NOT NULL AND v_net > 0 THEN
    INSERT INTO public.group_wallets (group_id)
    VALUES (v_group_id)
    ON CONFLICT (group_id) DO NOTHING;

    UPDATE public.group_wallets
    SET available_balance = available_balance + v_net,
        total_earned      = total_earned      + v_net,
        updated_at        = NOW()
    WHERE group_id = v_group_id;

    -- wallet_transactions referencia al owner (historial por usuario)
    INSERT INTO public.wallet_transactions
      (user_id, amount, type, status, reference_event_id, description)
    VALUES
      (v_owner_id, v_net, 'extra_hour', 'completed', p_reservation_id,
       'Ganancia hora extra · ' || v_res.event_date::TEXT);

    INSERT INTO public.financial_ledger
      (reservation_id, user_id, entry_type, amount, currency, description)
    VALUES
      (p_reservation_id, v_owner_id, 'extra_hour', v_net, 'mxn',
       'Hora extra · ' || v_res.event_date::TEXT);

    INSERT INTO public.notifications (user_id, type, title, body, data)
    VALUES (
      v_owner_id, 'payment',
      '💰 Hora extra cobrada',
      'Se agregaron $' || v_net::TEXT || ' MXN a tu billetera por hora(s) extra.',
      jsonb_build_object(
        'reservation_id', p_reservation_id,
        'amount',         v_net,
        'screen',         'Wallet'
      )
    );
  END IF;

  RETURN jsonb_build_object(
    'ok',          true,
    'extra_amount', p_extra_amount,
    'commission',  v_commission,
    'net',         v_net,
    'credited_to', 'group_wallets'
  );

EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$$;

GRANT EXECUTE ON FUNCTION public.credit_extra_hour_earnings(UUID, NUMERIC) TO authenticated;
GRANT EXECUTE ON FUNCTION public.credit_extra_hour_earnings(UUID, NUMERIC) TO service_role;

SELECT '352_fix_extra_hour_credit.sql ejecutado ✅' AS status;

-- ═════════════════════════════════════════════════════════════════════════════
-- TESTS DE VERIFICACIÓN (ejecutar después del CREATE OR REPLACE anterior)
-- ═════════════════════════════════════════════════════════════════════════════

-- ── TEST 1: group_confirm_extra_hours NO toca dinero ─────────────────────────
-- Esperado: las 3 columnas = false
SELECT
  routine_definition LIKE '%UPDATE public.wallets%'       AS toca_wallets_legacy,
  routine_definition LIKE '%UPDATE public.group_wallets%' AS toca_group_wallets,
  routine_definition LIKE '%wallet_transactions%'         AS toca_wallet_transactions
FROM information_schema.routines
WHERE routine_schema = 'public'
  AND routine_name   = 'group_confirm_extra_hours';
-- Esperado: false | false | false

-- ── TEST 2: credit_extra_hour_earnings acredita a group_wallets ───────────────
-- Esperado: todas = true
SELECT
  routine_definition LIKE '%UPDATE public.group_wallets%' AS acredita_group_wallets,
  routine_definition LIKE '%already_credited%'            AS tiene_guard_idempotencia,
  routine_definition LIKE '%credited_to%'                 AS retorna_credited_to
FROM information_schema.routines
WHERE routine_schema = 'public'
  AND routine_name   = 'credit_extra_hour_earnings';
-- Esperado: true | true | true

-- ── TEST 3: Idempotencia — simulación de doble llamada ────────────────────────
-- Inserta una fila en wallet_transactions simulando que ya fue acreditado,
-- luego verifica que credit_extra_hour_earnings retorna skipped.
-- Requiere una reserva real con grupo asignado. Ajusta los UUIDs.
--
-- DO $$
-- DECLARE
--   v_rid  UUID := '<uuid-reserva-real>';
--   v_uid  UUID := '<uuid-owner-grupo>';
--   v_net  NUMERIC := 900;  -- ej: $1000 extra * 90%
--   v_res1 JSONB;
--   v_res2 JSONB;
-- BEGIN
--   -- Simula que ya existía el crédito
--   INSERT INTO public.wallet_transactions
--     (user_id, amount, type, status, reference_event_id, description)
--   VALUES
--     (v_uid, v_net, 'extra_hour', 'completed', v_rid, 'Test idempotencia');
--
--   -- Llama a la función — debe retornar skipped
--   SELECT public.credit_extra_hour_earnings(v_rid, 1000) INTO v_res1;
--   RAISE NOTICE 'Primera llamada (debe ser skipped): %', v_res1;
--
--   -- Limpieza
--   DELETE FROM public.wallet_transactions
--   WHERE reference_event_id = v_rid AND description = 'Test idempotencia';
--
--   -- Segunda llamada sin el registro — debe acreditar normalmente
--   SELECT public.credit_extra_hour_earnings(v_rid, 1000) INTO v_res2;
--   RAISE NOTICE 'Segunda llamada (debe acreditar): %', v_res2;
--
--   -- Revertir para no dejar dinero de prueba
--   UPDATE public.group_wallets gw
--   SET available_balance = available_balance - (v_res2->>'net')::NUMERIC,
--       total_earned      = total_earned      - (v_res2->>'net')::NUMERIC
--   FROM public.groups g
--   WHERE g.owner_id = v_uid AND gw.group_id = g.id;
--
--   DELETE FROM public.wallet_transactions
--   WHERE reference_event_id = v_rid AND type = 'extra_hour'
--     AND description = 'Ganancia hora extra · ' || (SELECT event_date FROM reservations WHERE id = v_rid)::TEXT;
-- END;
-- $$;
