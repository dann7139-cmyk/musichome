-- ============================================================
-- sql/425_resolve_dispute_notify_group.sql
-- Hueco #1 de resolve_dispute: notificar TAMBIÉN al grupo el veredicto
--
-- ANTES (sql/184c:125-131): al resolver una disputa solo se notificaba
--   al CLIENTE — el owner del grupo nunca se enteraba del veredicto.
-- AHORA: insert espejo al owner con el resultado, mismo type 'dispute'
--   (ya está en el constraint vigente — cero cambios de constraint).
--
-- Todo lo demás de la función: byte a byte de sql/184c.
-- ⚠️ PENDIENTES CONOCIDOS (mini-lote financiero aparte, NO en este parche):
--   #2 resolved_client solo revierte pending_balance — el 50% ya
--      liberado a available (half_released) NO se revierte.
--   #3 el refund de Stripe al cliente NO se dispara automáticamente.
--   Por eso el frontend advierte al admin al resolver a favor del cliente.
-- ============================================================

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
  v_caller_id   UUID := auth.uid();
  v_dispute     RECORD;
  v_reservation RECORD;
  v_wallet_id   UUID;
  v_earnings    NUMERIC;
  v_owner_id    UUID;
BEGIN
  IF v_caller_id IS NULL THEN RAISE EXCEPTION 'unauthorized: sesión requerida'; END IF;

  IF NOT EXISTS (SELECT 1 FROM profiles WHERE id = v_caller_id AND role = 'admin') THEN
    RAISE EXCEPTION 'unauthorized: solo admins pueden resolver disputas';
  END IF;

  SELECT * INTO v_dispute FROM disputes WHERE id = p_dispute_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Disputa no encontrada'; END IF;

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

  IF p_resolution = 'resolved_client' THEN
    SELECT COALESCE(SUM(wt.amount), 0) INTO v_earnings
    FROM wallet_transactions wt
    WHERE wt.reservation_id = v_dispute.reservation_id AND wt.type = 'credit_pending';

    IF v_earnings > 0 THEN
      SELECT id INTO v_wallet_id FROM group_wallets WHERE group_id = v_reservation.group_id;

      UPDATE group_wallets
      SET pending_balance = GREATEST(0, pending_balance - v_earnings), updated_at = NOW()
      WHERE id = v_wallet_id;

      INSERT INTO wallet_transactions (
        group_wallet_id, group_id, type, amount, reservation_id,
        dispute_id, description, balance_after
      )
      SELECT
        gw.id, gw.group_id, 'refund_dispute', v_earnings, v_dispute.reservation_id,
        p_dispute_id,
        'Reembolso por disputa resuelta a favor del cliente',
        gw.pending_balance
      FROM group_wallets gw WHERE gw.id = v_wallet_id;
    END IF;
  END IF;

  -- Notificar al CLIENTE (como siempre)
  INSERT INTO notifications (user_id, type, title, body, data)
  VALUES (
    v_reservation.client_id, 'dispute',
    CASE p_resolution WHEN 'resolved_client' THEN '✅ Disputa resuelta a tu favor' ELSE '❌ Disputa resuelta' END,
    p_resolution_note,
    jsonb_build_object('screen','Reservations','reservation_id',v_dispute.reservation_id)
  );

  -- [425] Notificar TAMBIÉN al OWNER del grupo (hueco #1)
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
          ELSE 'El saldo pendiente del evento fue revertido.'
        END),
      jsonb_build_object('screen','GroupReservations','reservation_id',v_dispute.reservation_id)
    );
  END IF;

  RETURN jsonb_build_object('ok', true, 'resolution', p_resolution);
END;
$$;

COMMIT;

-- ── Verificaciones ────────────────────────────────────────────────────────────
-- V1: la función ahora notifica a ambas partes
SELECT
  routine_definition LIKE '%Notificar TAMBIÉN al OWNER%' AS notifica_grupo,
  routine_definition LIKE '%resolved_group%'             AS logica_intacta
FROM information_schema.routines
WHERE routine_schema = 'public' AND routine_name = 'resolve_dispute';
-- Esperado: true | true

-- V2: type 'dispute' sigue permitido (no se tocó el constraint)
SELECT pg_get_constraintdef(c.oid) LIKE '%''dispute''%' AS dispute_ok
FROM   pg_constraint c
WHERE  c.conname  = 'notifications_type_check'
  AND  c.conrelid = 'public.notifications'::regclass;
-- Esperado: true

SELECT '425_resolve_dispute_notify_group.sql ejecutado ✅' AS status;
