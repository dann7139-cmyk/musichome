-- ============================================================
-- sql/451_release_arrival_gate.sql
-- Opción A (parte 2 de 2): candado de llegada en el PUNTO ÚNICO de release.
--
-- Parcheado sobre el functiondef VIVO de prod de release_group_earnings_atomic
-- (lección 429). ÚNICO cambio: se AGREGA el guard de llegada justo DESPUÉS
-- del guard de open_dispute y ANTES de la lógica de actor_role. Todo lo demás
-- queda byte-idéntico: guards already_released / blocked-refunded /
-- payment_not_confirmed / open_dispute, ruta currency USD-MXN, half_released,
-- ensure_group_wallet, UPDATE de payout, wallet_transactions,
-- financial_audit_logs, notifs y el RETURN final.
--
-- Efecto: si NO (group_arrived_at IS NOT NULL OR arrival_verified) el pago
-- NO se libera → queda 'held' para revisión admin. Hereda a todos los
-- llamadores (finishEvent, release_all_eligible_payments cron, admin).
-- Requiere sql/450 (columna arrival_verified) ya corrido.
-- ============================================================

-- ── PRE-CHECK: la columna arrival_verified debe existir (sql/450) ─────────────
DO $pre$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_name = 'reservations' AND column_name = 'arrival_verified'
  ) THEN
    RAISE EXCEPTION 'ABORT: falta reservations.arrival_verified — corre sql/450 primero.';
  END IF;
END
$pre$;

BEGIN;

CREATE OR REPLACE FUNCTION public.release_group_earnings_atomic(p_reservation_id uuid, p_released_by uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_reservation RECORD;
  v_wallet      RECORD;
  v_total       NUMERIC;
  v_to_release  NUMERIC;
  v_actor_role  TEXT := 'system';
  v_currency    TEXT;
BEGIN
  SELECT * INTO v_reservation FROM reservations WHERE id = p_reservation_id FOR UPDATE;
  IF NOT FOUND THEN RETURN jsonb_build_object('ok', false, 'error', 'not_found'); END IF;

  IF v_reservation.payout_status = 'released' THEN
    RETURN jsonb_build_object('ok', true, 'skipped', true, 'reason', 'already_released');
  END IF;
  IF v_reservation.payout_status IN ('blocked','refunded') THEN
    RETURN jsonb_build_object('ok', false, 'error', 'payout_blocked',
      'payout_status', v_reservation.payout_status);
  END IF;
  IF v_reservation.payment_status NOT IN ('paid','fully_paid','deposit_paid') THEN
    RETURN jsonb_build_object('ok', false, 'error', 'payment_not_confirmed');
  END IF;
  IF EXISTS (
    SELECT 1 FROM disputes
    WHERE reservation_id = p_reservation_id AND status IN ('open','under_review')
  ) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'open_dispute_blocks_release');
  END IF;

  -- [451] GUARD DE LLEGADA (Opción A): sin llegada GPS ni verificación del admin
  -- (force-start) el pago NO se libera → queda 'held' para revisión.
  IF NOT (v_reservation.group_arrived_at IS NOT NULL OR COALESCE(v_reservation.arrival_verified, false)) THEN
    RETURN jsonb_build_object('ok', true, 'skipped', true, 'reason', 'no_arrival_verification');
  END IF;

  IF p_released_by IS NOT NULL THEN
    SELECT COALESCE(role,'unknown') INTO v_actor_role FROM profiles WHERE id = p_released_by;
  END IF;

  v_currency := COALESCE(v_reservation.currency_code, 'MXN');

  PERFORM ensure_group_wallet(v_reservation.group_id);
  SELECT * INTO v_wallet FROM group_wallets WHERE group_id = v_reservation.group_id FOR UPDATE;

  v_total := COALESCE(v_reservation.group_earnings,
               COALESCE(v_reservation.base_price,
                 ROUND(v_reservation.total_price * 0.9, 2)));
  v_to_release := CASE
    WHEN v_reservation.payout_status = 'half_released' THEN v_total - ROUND(v_total / 2, 2)
    ELSE v_total
  END;

  IF v_currency = 'USD' THEN
    UPDATE group_wallets SET
      pending_balance_usd   = GREATEST(0, pending_balance_usd - v_to_release),
      available_balance_usd = available_balance_usd + v_to_release,
      updated_at            = NOW()
    WHERE id = v_wallet.id;
  ELSE
    UPDATE group_wallets SET
      pending_balance   = GREATEST(0, pending_balance - v_to_release),
      available_balance = available_balance + v_to_release,
      updated_at        = NOW()
    WHERE id = v_wallet.id;
  END IF;

  UPDATE reservations SET
    payout_status = 'released', released_at = NOW(),
    released_by = p_released_by, wallet_released_at = NOW(), updated_at = NOW()
  WHERE id = p_reservation_id;

  INSERT INTO wallet_transactions
    (group_wallet_id, group_id, type, amount, reservation_id, description, balance_after, currency_code)
  VALUES (v_wallet.id, v_reservation.group_id, 'credit_available', v_to_release,
    p_reservation_id,
    CASE WHEN v_reservation.payout_status = 'half_released'
      THEN format('50%% final al terminar evento — reserva %s', p_reservation_id)
      ELSE format('Ganancias liberadas post-evento — reserva %s', p_reservation_id)
    END,
    CASE WHEN v_currency = 'USD'
      THEN v_wallet.available_balance_usd + v_to_release
      ELSE v_wallet.available_balance + v_to_release
    END,
    v_currency);

  INSERT INTO financial_audit_logs
    (entity_type, entity_id, action, actor_id, actor_role, amount, notes)
  VALUES ('reservation', p_reservation_id, 'release', p_released_by, v_actor_role, v_to_release,
    format('currency=%s payout_status_was=%s', v_currency, v_reservation.payout_status));

  INSERT INTO notifications (user_id, type, title, body, data)
  SELECT g.owner_id, 'payout', '🎉 Ganancias liberadas',
    format('$%s %s disponibles en tu billetera.',
      to_char(v_to_release, 'FM999,999,990'), v_currency),
    jsonb_build_object('screen','Wallet','reservation_id',p_reservation_id)
  FROM groups g WHERE g.id = v_reservation.group_id;

  RETURN jsonb_build_object(
    'ok',            true,
    'released',      v_to_release,
    'currency',      v_currency,
    'payout_status', 'released'
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.release_group_earnings_atomic(UUID, UUID) TO authenticated, service_role;

COMMIT;

-- ══════════════════════════════════════════════════════════════════════════════
-- V1 — el guard nuevo existe y TODOS los guards/piezas viejas se conservan
-- ══════════════════════════════════════════════════════════════════════════════
SELECT
  prosrc LIKE '%no_arrival_verification%'         AS guard_llegada_nuevo,       -- true
  prosrc LIKE '%already_released%'                 AS conserva_already_released,  -- true
  prosrc LIKE '%payout_blocked%'                   AS conserva_blocked_refunded,  -- true
  prosrc LIKE '%payment_not_confirmed%'            AS conserva_payment_confirmed, -- true
  prosrc LIKE '%open_dispute_blocks_release%'      AS conserva_open_dispute,      -- true
  prosrc LIKE '%half_released%'                     AS conserva_half_released,     -- true
  prosrc LIKE '%ensure_group_wallet%'              AS conserva_ensure_wallet,     -- true
  prosrc LIKE '%credit_available%'                  AS conserva_wallet_tx,         -- true
  prosrc LIKE '%financial_audit_logs%'             AS conserva_audit              -- true
FROM pg_proc WHERE proname = 'release_group_earnings_atomic';
-- Esperado: todo true

-- ══════════════════════════════════════════════════════════════════════════════
-- V2 — SIMULACIÓN con ROLLBACK (no altera datos): (a) sin llegada → skipped;
--      (b) con group_arrived_at → libera normal.
-- ══════════════════════════════════════════════════════════════════════════════
BEGIN;  -- se revierte al final

DO $sim$
DECLARE
  v_id            UUID;
  v_r1            JSONB;
  v_r2            JSONB;
  v_payout_after1 TEXT;
BEGIN
  -- Toma una reserva pagada, con grupo, sin disputa abierta (solo para simular)
  SELECT r.id INTO v_id
  FROM reservations r
  WHERE r.payment_status IN ('paid','fully_paid','deposit_paid')
    AND r.group_id IS NOT NULL
    AND NOT EXISTS (SELECT 1 FROM disputes d
                    WHERE d.reservation_id = r.id AND d.status IN ('open','under_review'))
  LIMIT 1;

  IF v_id IS NULL THEN
    RAISE NOTICE 'SIM omitida: no hay reserva pagada disponible para simular.';
    RETURN;
  END IF;

  -- (a) held, SIN llegada ni verificación → debe quedar skipped/no_arrival_verification
  UPDATE reservations
  SET payout_status = 'held', group_arrived_at = NULL, arrival_verified = false
  WHERE id = v_id;

  v_r1 := release_group_earnings_atomic(v_id, NULL);
  SELECT payout_status INTO v_payout_after1 FROM reservations WHERE id = v_id;

  IF (v_r1->>'reason') IS DISTINCT FROM 'no_arrival_verification' THEN
    RAISE EXCEPTION 'SIM (a) FALLÓ: esperaba reason=no_arrival_verification, obtuvo %', v_r1;
  END IF;
  IF v_payout_after1 <> 'held' THEN
    RAISE EXCEPTION 'SIM (a) FALLÓ: payout debía seguir held, quedó %', v_payout_after1;
  END IF;
  RAISE NOTICE 'SIM (a) OK ✅ — sin llegada → skipped/no_arrival_verification, payout sigue held';

  -- (b) held, CON group_arrived_at → debe liberar normal
  UPDATE reservations
  SET payout_status = 'held', group_arrived_at = NOW(), arrival_verified = false
  WHERE id = v_id;

  v_r2 := release_group_earnings_atomic(v_id, NULL);

  IF NOT ((v_r2->>'ok')::boolean AND COALESCE(v_r2->>'skipped','false') = 'false') THEN
    RAISE EXCEPTION 'SIM (b) FALLÓ: con llegada esperaba release ok, obtuvo %', v_r2;
  END IF;
  RAISE NOTICE 'SIM (b) OK ✅ — con group_arrived_at → liberó normal (monto: %)', v_r2->>'released';
END;
$sim$;

ROLLBACK;  -- ⬅️ revierte TODA la simulación (nada se altera en prod)

SELECT '451_release_arrival_gate.sql ejecutado ✅ (revisa V1 todo-true y los NOTICE de la simulación)' AS status;
