-- ════════════════════════════════════════════════════════════════════
-- sql/393 — Fix financiero + RPC de rechazo en flujo horas extra
--
-- Contexto (nuevo modelo):
--   El CLIENTE inicia la solicitud desde el EventTimerScreen
--   (status='awaiting_group_confirmation'). El GRUPO confirma o rechaza.
--
-- Problema A — group_confirm_extra_hours (sql/352):
--   1. Solo aceptaba status IN ('pending','client_requested').
--      El nuevo status 'awaiting_group_confirmation' no estaba incluido
--      → la función retornaba 'already_processed' (falso positivo).
--   2. No verificaba que el caller fuera el owner del grupo.
--   3. No descontaba client_available_balance. Al aceptar, el grupo
--      recibía el crédito en group_wallets (vía credit_extra_hour_earnings)
--      pero el saldo del cliente nunca disminuía → pérdida real de dinero.
--
-- Problema B — rechazo via UPDATE directo:
--   EventTimerScreen hacía UPDATE extra_hours SET status='rejected'
--   directamente vía PostgREST. Sin UPDATE policy para el grupo →
--   error RLS. Solución: RPC SECURITY DEFINER group_reject_extra_hour.
--
-- Cambios:
--   A. Reescritura de group_confirm_extra_hours:
--      - Acepta 'awaiting_group_confirmation' además de 'pending'/'client_requested'
--      - Verifica caller = group owner
--      - Descuenta client_available_balance cuando cliente inicia el flujo
--      - Valida saldo suficiente antes de proceder
--   B. Nueva RPC group_reject_extra_hour:
--      - SECURITY DEFINER, verifica caller = group owner
--      - UPDATE status='rejected' + notificación al cliente
-- ════════════════════════════════════════════════════════════════════

BEGIN;

-- ── A. Fix group_confirm_extra_hours ─────────────────────────────────────────

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
  v_caller   UUID := auth.uid();
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
  -- además de los estados legacy 'pending' / 'client_requested'
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

  -- Verificar que el caller es el owner del grupo
  IF v_caller != v_owner_id THEN
    RETURN jsonb_build_object('ok', false, 'error', 'unauthorized: solo el owner del grupo puede confirmar');
  END IF;

  -- ── Fix financiero crítico: descontar saldo del cliente ───────────────────
  -- Solo aplica en el flujo cliente-inicia (awaiting_group_confirmation)
  -- con pago vía saldo (not is_cash_payment). El flujo legacy ('pending') ya
  -- pasa por approve_extra_hour_payment_atomic que descuenta el saldo.
  IF v_extra.status = 'awaiting_group_confirmation'
     AND NOT COALESCE(v_extra.is_cash_payment, false) THEN

    IF COALESCE(v_res.client_available_balance, 0) < COALESCE(v_extra.total_extra_cost, 0) THEN
      RETURN jsonb_build_object(
        'ok',       false,
        'error',    'saldo_insuficiente',
        'balance',  COALESCE(v_res.client_available_balance, 0),
        'required', COALESCE(v_extra.total_extra_cost, 0)
      );
    END IF;

    -- Descontar del saldo del cliente (atómico: ya tenemos FOR UPDATE en reservations)
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

  -- Notificar al dueño del grupo (igual que antes)
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
$$;

GRANT EXECUTE ON FUNCTION public.group_confirm_extra_hours(UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION public.group_confirm_extra_hours(UUID) TO service_role;

-- ── B. Nueva RPC: group_reject_extra_hour ────────────────────────────────────
--
-- Reemplaza el UPDATE directo PostgREST en EventTimerScreen que fallaba
-- por falta de UPDATE policy para el grupo en extra_hours.
-- SECURITY DEFINER → bypass RLS + verifica caller internamente.

CREATE OR REPLACE FUNCTION public.group_reject_extra_hour(
  p_extra_id UUID
)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_extra  RECORD;
  v_res    RECORD;
  v_caller UUID := auth.uid();
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

  IF v_extra.status NOT IN ('pending', 'client_requested', 'awaiting_group_confirmation') THEN
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

  IF v_caller != v_res.group_owner_id THEN
    RETURN jsonb_build_object('ok', false, 'error', 'unauthorized: solo el owner del grupo puede rechazar');
  END IF;

  UPDATE public.extra_hours
  SET status = 'rejected'
  WHERE id = p_extra_id;

  IF v_res.client_id IS NOT NULL THEN
    INSERT INTO public.notifications (user_id, type, title, body, data)
    VALUES (
      v_res.client_id,
      'reservation',
      '❌ Hora extra no disponible',
      'El grupo no puede extender el servicio en este momento.',
      jsonb_build_object(
        'reservation_id', v_extra.reservation_id,
        'screen',         'EventTimer'
      )
    );
  END IF;

  RETURN jsonb_build_object('ok', true, 'extra_id', p_extra_id);

EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$$;

GRANT EXECUTE ON FUNCTION public.group_reject_extra_hour(UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION public.group_reject_extra_hour(UUID) TO service_role;

COMMIT;

-- ════════════════════════════════════════════════════════════════════
-- VERIFICACIONES (ejecutar separado después del COMMIT)
-- ════════════════════════════════════════════════════════════════════

-- V1: group_confirm_extra_hours acepta los 3 status y tiene fix financiero
SELECT
  routine_definition LIKE '%awaiting_group_confirmation%' AS acepta_nuevo_status,
  routine_definition LIKE '%saldo_insuficiente%'          AS valida_saldo,
  routine_definition LIKE '%client_available_balance%'    AS descuenta_balance,
  routine_definition LIKE '%v_caller != v_owner_id%'      AS verifica_ownership
FROM information_schema.routines
WHERE routine_schema = 'public'
  AND routine_name   = 'group_confirm_extra_hours';
-- Esperado: true | true | true | true

-- V2: group_reject_extra_hour existe con SECURITY DEFINER y verifica ownership
SELECT
  proname,
  prosecdef AS is_security_definer,
  routine_definition LIKE '%v_caller != v_res.group_owner_id%' AS verifica_ownership
FROM pg_proc
JOIN information_schema.routines ON routine_name = proname AND routine_schema = 'public'
WHERE proname = 'group_reject_extra_hour';
-- Esperado: 1 fila, is_security_definer=true, verifica_ownership=true

-- V3: ambas funciones tienen GRANT para authenticated
SELECT routine_name, grantee, privilege_type
FROM information_schema.routine_privileges
WHERE routine_schema = 'public'
  AND routine_name IN ('group_confirm_extra_hours', 'group_reject_extra_hour')
  AND grantee = 'authenticated';
-- Esperado: 2 filas con privilege_type = 'EXECUTE'

-- V4: group_confirm_extra_hours NO toca wallets directamente
-- (el dinero sigue yendo por credit_extra_hour_earnings llamado desde el cliente)
SELECT
  routine_definition LIKE '%UPDATE public.wallets%'       AS toca_wallets_legacy,
  routine_definition LIKE '%UPDATE public.group_wallets%' AS toca_group_wallets
FROM information_schema.routines
WHERE routine_schema = 'public'
  AND routine_name   = 'group_confirm_extra_hours';
-- Esperado: false | false
