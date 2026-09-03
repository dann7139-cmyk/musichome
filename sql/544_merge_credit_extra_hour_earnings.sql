-- ============================================================
-- sql/544_merge_credit_extra_hour_earnings.sql
--
-- BUG CONFIRMADO (auditoría 2026-08-09): credit_extra_hour_earnings
-- referencia columnas inexistentes en wallet_transactions
-- (reference_event_id, status), no tiene ninguna verificación de
-- autenticación/autorización, recibe el monto como parámetro no
-- verificado del caller, y se invoca fire-and-forget desde
-- EventTimerScreen.tsx en una transacción SEPARADA de la que
-- descuenta al cliente (group_confirm_extra_hours) — rompiendo
-- atomicidad por diseño, no solo por el bug de columnas. Verificado:
-- la combinación de estado que dispara la secuencia completa
-- (status='awaiting_group_confirmation' + payment_method≠'stripe')
-- es hoy inalcanzable por ningún camino de la app — extra_hours
-- tiene 0 filas en producción, sin impacto histórico.
--
-- CORRECCIÓN (alcance exacto autorizado):
--   1. Fusiona el crédito (grupo + comisión admin) DENTRO de
--      group_confirm_extra_hours, en la misma transacción que el
--      débito al cliente — antes de marcar extra_hours='accepted'.
--      Si el crédito falla, TODO se revierte (incluido el débito),
--      por ser una sola invocación de función PL/pgSQL.
--   2. Monto: exactamente el ya persistido en extra_hours
--      (group_extra_earnings para el grupo, total_extra_cost menos
--      ese valor para Daricefy) — SIN recalcular el modelo de
--      comisión. La discrepancia 10%/20%-markup queda documentada
--      como hallazgo aparte, no se toca aquí.
--   3. Moneda: extra_hours.currency_code, con guard fail-closed
--      (unsupported_currency) si no es MXN/USD — mismo patrón que
--      confirm_extra_hour_stripe_payment y settle_group_cancellation.
--   4. Idempotencia: el guard de estado que YA existe al inicio de
--      group_confirm_extra_hours (status NOT IN (...) → skipped) es
--      suficiente — una vez que la función corre y confirma
--      (status pasa a 'accepted'), cualquier reintento cae en ese
--      guard antes de tocar nada. No se agrega columna nueva.
--   5. Autorización: SIN CAMBIOS — se mantiene exactamente el mismo
--      chequeo ya existente (auth.uid() = groups.owner_id de la
--      reserva).
--   6. Sin escritura a financial_ledger — tabla huérfana, ninguna
--      otra función del proyecto la usa.
--   7. credit_extra_hour_earnings(uuid, numeric) se elimina por
--      completo (DROP). Confirmado: único caller en todo el proyecto
--      era EventTimerScreen.tsx:3093-3098 (ver auditoría). Grants
--      actuales: PUBLIC, anon, authenticated, postgres, service_role
--      (heredados por default, nunca revocados) — al hacer DROP se
--      eliminan junto con la función, no hace falta REVOKE aparte.
--
-- NO CAMBIA:
--   - El modelo de comisión 10%/20% (documentado aparte, no tocado).
--   - El bucket held/available (se sigue acreditando directo a
--     available_balance, igual que el credit_extra_hour_earnings
--     original — no se rediseña el ciclo pending→release para este
--     flujo en esta ronda).
--   - Los flujos 'pending'/'client_requested' (legacy/Flow B) — el
--     crédito nuevo SOLO aplica cuando status='awaiting_group_confirmation'
--     Y NOT is_cash_payment, exactamente la misma condición que ya
--     usaba el débito existente. Pagos en efectivo NUNCA tocan wallet
--     (el grupo ya recibió el efectivo en mano).
--   - ExtraHoursScreen.tsx / ClientExtraHoursScreen.tsx /
--     approve_extra_hour_payment_atomic (Flow B) — fuera de alcance,
--     documentado como riesgo aparte.
-- ============================================================

BEGIN;

CREATE OR REPLACE FUNCTION public.group_confirm_extra_hours(p_extra_id uuid)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE
  v_extra        RECORD;
  v_res          RECORD;
  v_owner_id     UUID;
  v_caller       UUID := auth.uid();
  v_gw           RECORD;
  v_admin_id     UUID;
  v_group_amount NUMERIC(12,2);
  v_admin_amount NUMERIC(12,2);
  v_gw_bal_after NUMERIC(14,2);
BEGIN
  IF v_caller IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'unauthorized');
  END IF;

  SELECT * INTO v_extra
  FROM   public.extra_hours
  WHERE  id = p_extra_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'extra_not_found');
  END IF;

  -- Acepta el nuevo status 'awaiting_group_confirmation' (flujo cliente-inicia)
  -- además de los estados legacy 'pending' / 'client_requested'.
  -- Este mismo guard es el mecanismo de idempotencia: una vez que la
  -- función corre con éxito y el status avanza a 'accepted', cualquier
  -- reintento cae aquí antes de tocar cualquier saldo.
  IF v_extra.status NOT IN ('pending', 'client_requested', 'awaiting_group_confirmation') THEN
    RETURN jsonb_build_object('ok', true, 'skipped', true, 'reason', 'already_processed');
  END IF;

  SELECT r.*, g.owner_id AS group_owner_id
  INTO   v_res
  FROM   public.reservations r
  JOIN   public.groups g ON g.id = r.group_id
  WHERE  r.id = v_extra.reservation_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'reservation_not_found');
  END IF;

  v_owner_id := v_res.group_owner_id;

  -- Verificar que el caller es el owner del grupo (sin cambios)
  IF v_caller != v_owner_id THEN
    RETURN jsonb_build_object('ok', false, 'error', 'unauthorized: solo el owner del grupo puede confirmar');
  END IF;

  -- ── Fix financiero crítico: descontar saldo del cliente Y acreditar
  -- grupo + Daricefy, TODO en esta misma transacción ─────────────────
  -- Solo aplica en el flujo cliente-inicia (awaiting_group_confirmation)
  -- con pago vía saldo (not is_cash_payment). El flujo legacy ('pending')
  -- no debita ni acredita aquí (approve_extra_hour_payment_atomic es su
  -- propio camino, fuera de alcance de este fix).
  IF v_extra.status = 'awaiting_group_confirmation'
     AND NOT COALESCE(v_extra.is_cash_payment, false) THEN

    -- Moneda real de la hora extra — fail-closed, sin fallback silencioso.
    IF v_extra.currency_code IS NULL OR v_extra.currency_code NOT IN ('MXN', 'USD') THEN
      RETURN jsonb_build_object(
        'ok', false, 'error', 'unsupported_currency',
        'currency_code', v_extra.currency_code
      );
    END IF;

    IF COALESCE(v_res.client_available_balance, 0) < COALESCE(v_extra.total_extra_cost, 0) THEN
      RETURN jsonb_build_object(
        'ok',       false,
        'error',    'saldo_insuficiente',
        'balance',  COALESCE(v_res.client_available_balance, 0),
        'required', COALESCE(v_extra.total_extra_cost, 0)
      );
    END IF;

    -- Montos: exactamente los ya persistidos en extra_hours al crear la
    -- solicitud — sin recalcular el modelo de comisión (fuera de alcance).
    v_group_amount := COALESCE(v_extra.group_extra_earnings, 0);
    v_admin_amount := COALESCE(v_extra.total_extra_cost, 0) - v_group_amount;

    -- ── Acreditar al grupo (bucket según moneda, nunca mezclado) ──────
    PERFORM public.ensure_group_wallet(v_res.group_id);
    SELECT * INTO v_gw FROM public.group_wallets WHERE group_id = v_res.group_id FOR UPDATE;

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
      (v_gw.id, v_res.group_id, 'extra_hour', v_group_amount, v_extra.reservation_id,
       'Ganancia hora extra (saldo) · ' || v_res.event_date::TEXT,
       v_gw_bal_after, v_extra.currency_code);

    -- ── Comisión Daricefy (wallets admin — sin pending, directo a available) ──
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
        (v_admin_id, 'commission', v_admin_amount, v_extra.reservation_id,
         'Comisión hora extra (saldo) · reserva ' || v_extra.reservation_id::TEXT,
         v_extra.currency_code);
    END IF;

    -- Descontar del saldo del cliente — al final del bloque de dinero:
    -- si cualquier acreditación de arriba falló, esta línea nunca se
    -- alcanza y todo el bloque (incluidas las UPDATE de arriba) se
    -- revierte junto con el resto de la función.
    UPDATE public.reservations
    SET    client_available_balance =
             GREATEST(0, COALESCE(client_available_balance, 0)
                         - COALESCE(v_extra.total_extra_cost, 0))
    WHERE  id = v_extra.reservation_id;
  END IF;

  -- Estado: accepted + timestamp (igual que antes)
  UPDATE public.extra_hours
  SET status             = 'accepted',
      group_confirmed_at = NOW()
  WHERE id = p_extra_id;

  -- Extender el evento en reservations (igual que antes)
  UPDATE public.reservations
  SET extra_hours_added = COALESCE(extra_hours_added, 0) + v_extra.hours_added
  WHERE id = v_extra.reservation_id;

  -- Notificar al dueño del grupo — texto actualizado: el crédito ya
  -- ocurrió arriba en esta misma transacción, ya no es una promesa futura.
  IF v_owner_id IS NOT NULL THEN
    INSERT INTO public.notifications (user_id, type, title, body, data)
    VALUES (
      v_owner_id, 'payment',
      '💰 Hora extra registrada',
      v_extra.hours_added || 'h extra confirmadas.' ||
        CASE WHEN v_extra.status = 'awaiting_group_confirmation' AND NOT COALESCE(v_extra.is_cash_payment, false)
             THEN ' Las ganancias ya se acreditaron a tu billetera.'
             ELSE '' END,
      jsonb_build_object(
        'reservation_id', v_extra.reservation_id,
        'hours_added',    v_extra.hours_added,
        'screen',         'Wallet'
      )
    );
  END IF;

  -- Notificar al cliente (igual que antes)
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
$function$;

-- Eliminar credit_extra_hour_earnings por completo — ya no se necesita,
-- su lógica ahora vive dentro de group_confirm_extra_hours. Único
-- caller confirmado (EventTimerScreen.tsx:3093-3098) se elimina en el
-- mismo cambio del lado frontend (fuera de este archivo SQL).
DROP FUNCTION IF EXISTS public.credit_extra_hour_earnings(UUID, NUMERIC);

COMMIT;

-- ════════════════════════════════════════════════════════════════════
-- VERIFICACIONES (ejecutar separado después del COMMIT)
-- ════════════════════════════════════════════════════════════════════

-- V1: credit_extra_hour_earnings ya no existe
SELECT COUNT(*) = 0 AS eliminada
FROM   pg_proc p
JOIN   pg_namespace n ON n.oid = p.pronamespace
WHERE  n.nspname = 'public' AND p.proname = 'credit_extra_hour_earnings';
-- Esperado: true

-- V2: group_confirm_extra_hours existe con la misma firma de siempre
SELECT COUNT(*) = 1 AS firma_correcta
FROM   pg_proc p
JOIN   pg_namespace n ON n.oid = p.pronamespace
WHERE  n.nspname = 'public'
  AND  p.proname = 'group_confirm_extra_hours'
  AND  pg_get_function_identity_arguments(p.oid) = 'p_extra_id uuid';
-- Esperado: true

-- V3: SECURITY DEFINER
SELECT prosecdef FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'public' AND p.proname = 'group_confirm_extra_hours';
-- Esperado: true

-- V4: contiene el guard de moneda, ya no referencia financial_ledger,
-- ya no referencia reference_event_id/status de wallet_transactions
SELECT
  routine_definition LIKE '%unsupported_currency%'         AS tiene_guard_moneda,
  routine_definition NOT LIKE '%financial_ledger%'          AS sin_financial_ledger,
  routine_definition LIKE '%group_extra_earnings%'          AS usa_monto_persistido,
  routine_definition LIKE '%available_balance_usd%'         AS soporta_bucket_usd
FROM information_schema.routines
WHERE routine_schema = 'public' AND routine_name = 'group_confirm_extra_hours';
-- Esperado: true | true | true | true

-- V5: autorización sin cambios (mismo guard de owner)
SELECT routine_definition LIKE '%solo el owner del grupo puede confirmar%' AS mantiene_guard_owner
FROM information_schema.routines
WHERE routine_schema = 'public' AND routine_name = 'group_confirm_extra_hours';
-- Esperado: true

SELECT '544_merge_credit_extra_hour_earnings ✅' AS status;
