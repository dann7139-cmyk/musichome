-- ============================================================
-- 551_fix_group_confirm_extra_hours_payout_status.sql
--
-- PROPÓSITO
--   Cerrar la misma laguna estructural que ya se corrigió en
--   approve_extra_hour_payment_atomic (sql/550): group_confirm_extra_hours
--   nunca fija extra_hours.payout_status, que se queda en el default de
--   tabla 'held' en las 3 ramas (legado, saldo, efectivo) — incluida la
--   rama saldo, donde SÍ se acredita dinero real de forma directa e
--   inmediata a group_wallets.available_balance.
--
--   Diferencia con approve_extra_hour_payment_atomic: esta función deja
--   status='accepted' (no 'paid'), así que HOY release_extra_hours_partial/
--   _final NO la recogen (su filtro exige status='paid') — confirmado en
--   la auditoría de solo lectura previa. NO hay doble crédito activo hoy.
--   Este fix es preventivo/defensivo: la protección actual es accidental
--   (depende de que 'accepted' nunca coincida con el filtro 'paid' de las
--   funciones de liberación), no un diseño explícito. Fijar payout_status
--   correctamente en el origen elimina la dependencia de esa coincidencia.
--
-- CAMBIOS (2)
--   1. Agregar `payout_status = 'released'` al ÚNICO UPDATE final de
--      extra_hours (el que ya pone status='accepted' + group_confirmed_at),
--      aplicado siempre — en las 3 ramas (legado, saldo, efectivo) nunca
--      queda dinero pendiente de liberar vía esta función: en saldo ya se
--      acreditó directo a available_balance; en efectivo y legado nunca
--      se acredita nada aquí.
--   2. Agregar un INSERT a financial_audit_logs, SOLO en la rama saldo
--      (la única de las 3 que mueve dinero real en esta función) —
--      laguna de trazabilidad detectada en la auditoría: a diferencia de
--      sus funciones hermanas (approve_extra_hour_payment_atomic,
--      confirm_extra_hour_stripe_payment), esta función nunca dejaba
--      rastro en el log de auditoría financiera pese a acreditar dinero
--      real. Autorizado explícitamente para incluirse en este mismo
--      archivo.
--
-- EXPLÍCITAMENTE FUERA DE ALCANCE DE ESTE ARCHIVO
--   - No se toca confirm_cash_extra_payment (bug relacionado pero en una
--     función distinta, encontrado en la misma auditoría — se preparará
--     aparte como sql/552, después de cerrar este archivo).
--   - No se toca approve_extra_hour_payment_atomic, confirm_extra_hour_stripe_payment,
--     release_extra_hours_partial, release_extra_hours_final.
--   - Sin backfill: no hay ninguna fila histórica con status='accepted'
--     que corregir — el cambio solo afecta filas futuras.
--
-- SEGURIDAD: PRE-CHECK DE VERSIÓN
--   Igual que sql/550: se verifica el md5() del código fuente desplegado
--   contra el auditado antes de reemplazar. Si no coincide, aborta
--   completo sin tocar nada.
--
-- NO EJECUTAR hasta autorización explícita. Este archivo se entrega
-- primero para revisión.
-- ============================================================

BEGIN;

-- ── Pre-check: la versión desplegada debe ser EXACTAMENTE la auditada ──
DO $$
DECLARE
  v_current_hash  TEXT;
  v_expected_hash CONSTANT TEXT := '53a368624f81295dc1391767575e9e51';
BEGIN
  SELECT md5(prosrc) INTO v_current_hash
  FROM   pg_proc p
  JOIN   pg_namespace n ON n.oid = p.pronamespace
  WHERE  n.nspname = 'public' AND p.proname = 'group_confirm_extra_hours';

  IF v_current_hash IS NULL THEN
    RAISE EXCEPTION 'ABORT: group_confirm_extra_hours no existe en esta base — no se puede aplicar este fix';
  END IF;

  IF v_current_hash <> v_expected_hash THEN
    RAISE EXCEPTION 'ABORT: la definición actual de group_confirm_extra_hours (md5=%) no coincide con la versión auditada (md5=%). Alguien la modificó desde que se preparó este fix — revisar manualmente antes de reemplazarla.',
      v_current_hash, v_expected_hash;
  END IF;

  RAISE NOTICE 'Pre-check OK: versión desplegada coincide con la auditada (md5=%)', v_current_hash;
END $$;

-- ── Reemplazo: función completa, sin abreviar ──────────────────────────
CREATE OR REPLACE FUNCTION public.group_confirm_extra_hours(p_extra_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
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

    -- financial_audit_logs (ÚNICO CAMBIO #2 de este archivo): esta rama
    -- SÍ mueve dinero real (crédito directo a available_balance del
    -- grupo + comisión admin) pero nunca quedaba registrada en el log
    -- de auditoría financiera, a diferencia de sus funciones hermanas
    -- (approve_extra_hour_payment_atomic, confirm_extra_hour_stripe_payment).
    -- Se agrega solo aquí, en la rama saldo — la única de las 3 que
    -- mueve dinero en esta función.
    INSERT INTO public.financial_audit_logs (
      entity_type, entity_id, action, actor_id, actor_role,
      before_state, after_state, amount, notes
    ) VALUES (
      'extra_hour', p_extra_id, 'group_confirmed_balance', v_caller, 'group',
      jsonb_build_object(
        'extra_hour_status', v_extra.status,
        'reservation_id',    v_extra.reservation_id
      ),
      jsonb_build_object(
        'extra_hour_status', 'accepted',
        'payout_status',     'released',
        'reservation_id',    v_extra.reservation_id,
        'group_amount',      v_group_amount,
        'admin_amount',      v_admin_amount,
        'currency',          v_extra.currency_code
      ),
      v_group_amount,
      format('Hora extra confirmada por el grupo (saldo) · reserva %s', v_extra.reservation_id::TEXT)
    );
  END IF;

  -- Estado: accepted + timestamp (igual que antes) + payout_status='released'
  -- (ÚNICO CAMBIO de este archivo): en las 3 ramas que llegan hasta aquí
  -- (legado, saldo, efectivo) nunca queda dinero pendiente de liberar vía
  -- esta función — en saldo ya se acreditó arriba, directo a
  -- available_balance; en efectivo y legado nunca se acredita nada aquí.
  -- Dejar payout_status en el default 'held' sería incorrecto en los 3
  -- casos. Hoy esto no causa doble crédito porque status='accepted' nunca
  -- coincide con el filtro status='paid' de release_extra_hours_partial/
  -- _final — pero esa es una protección accidental, no por diseño; fijar
  -- payout_status correctamente en el origen la vuelve robusta ante
  -- cualquier cambio futuro de esos valores de status.
  UPDATE public.extra_hours
  SET status             = 'accepted',
      group_confirmed_at = NOW(),
      payout_status      = 'released'
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

COMMIT;

-- ============================================================
-- VERIFICACIÓN POST-FIX (ejecutar por separado después del COMMIT,
-- NO se auto-ejecuta — todo lo siguiente está comentado)
-- ============================================================

-- V1: la función existe y su código fuente ahora fija payout_status='released'
-- SELECT prosrc LIKE '%payout_status      = ''released''%' OR prosrc LIKE '%payout_status = ''released''%' AS tiene_released
-- FROM pg_proc WHERE proname = 'group_confirm_extra_hours' AND pronamespace='public'::regnamespace;

-- V2: confirmar que approve_extra_hour_payment_atomic, confirm_extra_hour_stripe_payment,
-- release_extra_hours_partial, release_extra_hours_final NO cambiaron
-- (comparar contra hashes ya capturados en auditorías previas)
-- SELECT proname, md5(prosrc) FROM pg_proc
-- WHERE proname IN ('approve_extra_hour_payment_atomic','confirm_extra_hour_stripe_payment',
--                    'release_extra_hours_partial','release_extra_hours_final')
--   AND pronamespace='public'::regnamespace;

-- V3: no debe haber ninguna fila histórica afectada por este cambio (el
-- fix es hacia adelante; no hay backfill)
-- SELECT COUNT(*) AS accepted_rows_total FROM extra_hours WHERE status='accepted';

SELECT '551_fix_group_confirm_extra_hours_payout_status preparado — NO EJECUTADO' AS status;
