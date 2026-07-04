-- ============================================================
-- sql/427_dispute_full_reversal.sql
-- PIEZA 1 del mini-lote financiero — detiene el sangrado #2 y #2b
--
-- resolve_dispute v4 (base: sql/425, que a su vez conserva 184c).
-- Cambia SOLO el bloque resolved_client:
--
--   #2  ANTES: revertía SUM(credit_pending) solo de pending_balance con
--       GREATEST(0,…) → con half_released el grupo se quedaba el 50%
--       ya liberado, y el asiento refund_dispute mentía por ese monto.
--       AHORA: contabilidad REAL desde wallet_transactions:
--         v_liberado  = SUM(credit_available de la reserva)
--         v_pendiente = SUM(credit_pending) − v_liberado (≥0)
--       Revierte pending (con clamp: pending no representa deuda) Y
--       available SIN clamp → puede quedar NEGATIVO = deuda del grupo
--       (firma (a): se netea contra sus próximos eventos).
--       Dos asientos con montos reales.
--   #2b ANTES: payout_status quedaba half_released → el cron de 12h
--       re-liberaba "el 50% restante" DESPUÉS del veredicto.
--       AHORA: payout_status='refunded' → el release lo bloquea
--       (sql/240:252) y el futuro refund de tarjeta también.
--
-- IDEMPOTENCIA (4 capas):
--   1. status NOT IN (open, under_review) — impide re-resolver
--   2. NOT EXISTS de asiento 'refund_dispute' para la reserva
--   3. payout_status = 'refunded' como tercer candado
--   4. FOR UPDATE en disputa y wallet
--
-- TYPES: se REUSA 'refund_dispute' en ambos asientos (distinguidos por
--   description). Razón: chk_wt_type fue reconstruido varias veces en
--   el repo (184a/226/227/229a/233/302) con listas divergentes —
--   agregar types nuevos repetiría la lección del quote_expired.
--   'refund_dispute' está en TODAS las versiones.
--   Notif de deuda al admin: type 'admin' (ya en notifications_type_check).
--
-- request_payout: YA valida available < monto → EXCEPTION (sql/184c:162)
--   — la deuda no se puede burlar con un retiro. Sin parche necesario.
--
-- ⚠️ PRE-CHECK OBLIGATORIO (corre ANTES; si alguno da false, DETENTE):
-- ============================================================

-- P1: 'refund_dispute' permitido en chk_wt_type
SELECT pg_get_constraintdef(c.oid) LIKE '%refund_dispute%' AS refund_dispute_ok,
       pg_get_constraintdef(c.oid)                          AS chk_wt_type_actual
FROM   pg_constraint c
WHERE  c.conname  = 'chk_wt_type'
  AND  c.conrelid = 'public.wallet_transactions'::regclass;
-- Esperado: true

-- P2: 'admin' permitido en notifications_type_check
SELECT pg_get_constraintdef(c.oid) LIKE '%''admin''%' AS admin_ok
FROM   pg_constraint c
WHERE  c.conname  = 'notifications_type_check'
  AND  c.conrelid = 'public.notifications'::regclass;
-- Esperado: true


BEGIN;

CREATE OR REPLACE FUNCTION resolve_dispute(
  p_dispute_id      UUID,
  p_resolution      TEXT,
  p_resolution_note TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_caller_id     UUID := auth.uid();
  v_dispute       RECORD;
  v_reservation   RECORD;
  v_wallet        RECORD;
  v_owner_id      UUID;
  v_group_name    TEXT;
  v_currency      TEXT;
  v_pending_total NUMERIC;
  v_liberado      NUMERIC;
  v_pendiente     NUMERIC;
  v_avail_after   NUMERIC;
  v_admin_id      UUID;
BEGIN
  IF v_caller_id IS NULL THEN RAISE EXCEPTION 'unauthorized: sesión requerida'; END IF;

  IF NOT EXISTS (SELECT 1 FROM profiles WHERE id = v_caller_id AND role = 'admin') THEN
    RAISE EXCEPTION 'unauthorized: solo admins pueden resolver disputas';
  END IF;

  SELECT * INTO v_dispute FROM disputes WHERE id = p_dispute_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Disputa no encontrada'; END IF;

  -- Capa 1 de idempotencia
  IF v_dispute.status NOT IN ('open','under_review') THEN
    RAISE EXCEPTION 'Esta disputa ya fue resuelta';
  END IF;

  SELECT * INTO v_reservation FROM reservations WHERE id = v_dispute.reservation_id;

  UPDATE disputes
  SET
    status          = p_resolution,
    resolution_note = p_resolution_note,
    resolved_by     = v_caller_id,
    resolved_at     = NOW(),
    updated_at      = NOW()
  WHERE id = p_dispute_id;

  IF p_resolution = 'resolved_group' THEN
    PERFORM release_event_payment(v_dispute.reservation_id);
  END IF;

  -- ══════════════════════════════════════════════════════════════
  -- [427] resolved_client: REVERSA COMPLETA (pending + available)
  -- ══════════════════════════════════════════════════════════════
  IF p_resolution = 'resolved_client' THEN

    -- Capas 2 y 3 de idempotencia: reversa ya ejecutada antes → no repetir
    IF v_reservation.payout_status = 'refunded'
       OR EXISTS (
         SELECT 1 FROM wallet_transactions
         WHERE reservation_id = v_dispute.reservation_id
           AND type = 'refund_dispute'
       )
    THEN
      RAISE NOTICE '[resolve_dispute] Reversa ya aplicada para reserva % — skip',
        v_dispute.reservation_id;
    ELSE
      v_currency := COALESCE(v_reservation.currency_code, 'MXN');

      SELECT * INTO v_wallet FROM group_wallets
      WHERE group_id = v_reservation.group_id
      FOR UPDATE;

      -- Contabilidad REAL: qué se le acreditó al grupo por ESTA reserva
      SELECT COALESCE(SUM(amount), 0) INTO v_pending_total
      FROM wallet_transactions
      WHERE reservation_id = v_dispute.reservation_id AND type = 'credit_pending';

      SELECT COALESCE(SUM(amount), 0) INTO v_liberado
      FROM wallet_transactions
      WHERE reservation_id = v_dispute.reservation_id AND type = 'credit_available';

      v_pendiente := GREATEST(v_pending_total - v_liberado, 0);

      -- 1) Parte aún PENDIENTE (clamp: pending nunca representa deuda)
      IF v_pendiente > 0 THEN
        IF v_currency = 'USD' THEN
          UPDATE group_wallets
          SET pending_balance_usd = GREATEST(0, pending_balance_usd - v_pendiente),
              updated_at = NOW()
          WHERE id = v_wallet.id;
        ELSE
          UPDATE group_wallets
          SET pending_balance = GREATEST(0, pending_balance - v_pendiente),
              updated_at = NOW()
          WHERE id = v_wallet.id;
        END IF;

        INSERT INTO wallet_transactions (
          group_wallet_id, group_id, type, amount, reservation_id,
          dispute_id, description, balance_after, currency_code
        )
        SELECT gw.id, gw.group_id, 'refund_dispute', v_pendiente,
               v_dispute.reservation_id, p_dispute_id,
               'Reversa por disputa — parte pendiente',
               CASE WHEN v_currency = 'USD' THEN gw.pending_balance_usd
                    ELSE gw.pending_balance END,
               v_currency
        FROM group_wallets gw WHERE gw.id = v_wallet.id;
      END IF;

      -- 2) Lo YA LIBERADO — SIN clamp: puede dejar deuda (saldo negativo)
      IF v_liberado > 0 THEN
        IF v_currency = 'USD' THEN
          UPDATE group_wallets
          SET available_balance_usd = available_balance_usd - v_liberado,
              updated_at = NOW()
          WHERE id = v_wallet.id;
        ELSE
          UPDATE group_wallets
          SET available_balance = available_balance - v_liberado,
              updated_at = NOW()
          WHERE id = v_wallet.id;
        END IF;

        INSERT INTO wallet_transactions (
          group_wallet_id, group_id, type, amount, reservation_id,
          dispute_id, description, balance_after, currency_code
        )
        SELECT gw.id, gw.group_id, 'refund_dispute', v_liberado,
               v_dispute.reservation_id, p_dispute_id,
               'Reversa por disputa — monto ya liberado (50% llegada / release)',
               CASE WHEN v_currency = 'USD' THEN gw.available_balance_usd
                    ELSE gw.available_balance END,
               v_currency
        FROM group_wallets gw WHERE gw.id = v_wallet.id;
      END IF;

      -- 3) Candado anti re-liberación: mata #2b (el cron bloquea 'refunded')
      UPDATE reservations
      SET payout_status = 'refunded', updated_at = NOW()
      WHERE id = v_dispute.reservation_id;

      -- 4) ¿Quedó deudor? → alerta admin + auditoría de deuda
      SELECT CASE WHEN v_currency = 'USD' THEN available_balance_usd
                  ELSE available_balance END
      INTO v_avail_after
      FROM group_wallets WHERE id = v_wallet.id;

      SELECT name INTO v_group_name FROM groups WHERE id = v_reservation.group_id;

      IF v_avail_after < 0 THEN
        SELECT id INTO v_admin_id FROM profiles WHERE role = 'admin' LIMIT 1;
        IF v_admin_id IS NOT NULL THEN
          INSERT INTO notifications (user_id, type, title, body, data)
          VALUES (
            v_admin_id, 'admin',
            '⚠️ Grupo con saldo deudor por disputa',
            COALESCE(v_group_name, 'Un grupo') || ' quedó con saldo ' ||
              to_char(v_avail_after, 'FM-999,999,990.00') || ' ' || v_currency ||
              ' tras la reversa. La deuda se netea contra sus próximos eventos.',
            jsonb_build_object(
              'reservation_id', v_dispute.reservation_id,
              'dispute_id',     p_dispute_id,
              'group_id',       v_reservation.group_id,
              'screen',         'AdminDisputes'
            )
          );
        END IF;

        INSERT INTO financial_audit_logs
          (entity_type, entity_id, action, actor_id, actor_role, amount, notes)
        VALUES ('group_wallet', v_wallet.id, 'dispute_debt', v_caller_id, 'admin',
          v_avail_after,
          format('Saldo deudor tras reversa completa de disputa %s', p_dispute_id));
      END IF;

      -- Auditoría de la reversa (montos reales)
      INSERT INTO financial_audit_logs
        (entity_type, entity_id, action, actor_id, actor_role, amount, notes)
      VALUES ('reservation', v_dispute.reservation_id, 'dispute_reversal',
        v_caller_id, 'admin', v_pendiente + v_liberado,
        format('resolved_client: pendiente=%s liberado=%s currency=%s dispute=%s',
               v_pendiente, v_liberado, v_currency, p_dispute_id));
    END IF;
  END IF;

  -- Notificar al CLIENTE (igual que siempre)
  INSERT INTO notifications (user_id, type, title, body, data)
  VALUES (
    v_reservation.client_id, 'dispute',
    CASE p_resolution WHEN 'resolved_client' THEN '✅ Disputa resuelta a tu favor' ELSE '❌ Disputa resuelta' END,
    p_resolution_note,
    jsonb_build_object('screen','Reservations','reservation_id',v_dispute.reservation_id)
  );

  -- Notificar al OWNER del grupo (sql/425)
  SELECT g.owner_id INTO v_owner_id FROM groups g WHERE g.id = v_reservation.group_id;
  IF v_owner_id IS NOT NULL THEN
    INSERT INTO notifications (user_id, type, title, body, data)
    VALUES (
      v_owner_id, 'dispute',
      CASE p_resolution
        WHEN 'resolved_group' THEN '✅ Disputa resuelta a tu favor'
        ELSE '⚠️ Disputa resuelta a favor del cliente'
      END,
      COALESCE(p_resolution_note,
        CASE p_resolution
          WHEN 'resolved_group' THEN 'El pago del evento fue liberado.'
          ELSE 'El saldo del evento fue revertido.'
        END),
      jsonb_build_object('screen','GroupReservations','reservation_id',v_dispute.reservation_id)
    );
  END IF;

  RETURN jsonb_build_object('ok', true, 'resolution', p_resolution);
END;
$$;

COMMIT;

-- ── Verificaciones ────────────────────────────────────────────────────────────
-- V1: la reversa completa está en la definición
SELECT
  routine_definition LIKE '%monto ya liberado%'          AS revierte_available,
  routine_definition LIKE '%parte pendiente%'            AS revierte_pending,
  routine_definition LIKE '%payout_status = ''refunded''%' AS mata_2b,
  routine_definition LIKE '%saldo deudor%'               AS alerta_deuda,
  routine_definition LIKE '%Notificar al OWNER%'         AS notif_grupo_425_intacta
FROM information_schema.routines
WHERE routine_schema = 'public' AND routine_name = 'resolve_dispute';
-- Esperado: true | true | true | true | true

SELECT '427_dispute_full_reversal.sql ejecutado ✅' AS status;
