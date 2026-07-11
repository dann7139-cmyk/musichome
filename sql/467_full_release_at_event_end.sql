-- ============================================================
-- sql/467_full_release_at_event_end.sql
-- NUEVO MODELO DE LIBERACIÓN (decisión del usuario 2026-07-11):
--
--   · Se ELIMINA la liberación del 50% al llegar. El GPS se queda como
--     candado de VERIFICACIÓN de llegada (anti no-show), sin mover dinero.
--   · El 100% del base se libera al FINALIZAR el evento (el frontend ya
--     llama release_group_earnings_atomic en finishEvent; con payout 'held'
--     esa función libera el total — no requiere cambios).
--   · Retiro: el grupo solicita, el admin transfiere manual y sube
--     COMPROBANTE (espejo del flujo de reembolsos manuales).
--
-- Incluye además:
--   1. FIX settle_cancellation: fallback de base al modelo 20% (encontrado
--      en prueba real: con base_price NULL usaba 0.9 y sobre-descontaba $720).
--   2. Reconciliación del wallet afectado (+$1,440).
--   3. release_half_on_arrival → SOLO verificación (misma firma; el
--      frontend no cambia).
--   4. payout_requests con comprobante + admin_complete_payout.
-- ============================================================

BEGIN;

-- ═══════════════════════════════════════════════════════════════════
-- 1. FIX settle_cancellation — base con group_earnings/modelo 20%
-- ═══════════════════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION public.settle_cancellation(
  p_reservation_id UUID,
  p_refund_id      TEXT DEFAULT NULL,
  p_reason         TEXT DEFAULT 'client_cancelled'
)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_res        RECORD;
  v_charge     JSONB;
  v_grp_comp   NUMERIC;
  v_plat_ret   NUMERIC;
  v_base       NUMERIC;
  v_service    NUMERIC;
  v_admin_delta NUMERIC;
  v_wallet     RECORD;
  v_admin_id   UUID;
  v_group_name TEXT;
BEGIN
  SELECT * INTO v_res FROM reservations WHERE id = p_reservation_id FOR UPDATE;
  IF NOT FOUND THEN RETURN jsonb_build_object('ok', false, 'error', 'not_found'); END IF;

  IF v_res.status = 'cancelled' AND v_res.payout_status = 'refunded' THEN
    RETURN jsonb_build_object('ok', true, 'skipped', true, 'reason', 'already_settled');
  END IF;

  IF v_res.payout_status NOT IN ('held', 'blocked') THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_cancellable',
      'payout_status', v_res.payout_status);
  END IF;

  v_charge   := public.compute_cancellation_charge(p_reservation_id);
  v_grp_comp := (v_charge->>'group_compensation')::NUMERIC;
  v_plat_ret := (v_charge->>'platform_retained')::NUMERIC;

  -- 🔧 FIX: lo retenido del grupo es group_earnings (lo que se le acreditó).
  -- Fallbacks al modelo 20% actual, NUNCA al 0.9 viejo.
  v_base    := COALESCE(v_res.group_earnings, v_res.base_price,
                        ROUND(v_res.total_price / 1.20, 2));
  v_service := COALESCE(v_res.service_fee_amount,
                        ROUND(v_res.total_price - v_base, 2));

  PERFORM ensure_group_wallet(v_res.group_id);
  SELECT * INTO v_wallet FROM group_wallets WHERE group_id = v_res.group_id FOR UPDATE;

  UPDATE group_wallets SET
    pending_balance   = GREATEST(0, pending_balance - v_base),
    available_balance = available_balance + v_grp_comp,
    total_earned      = GREATEST(0, total_earned - (v_base - v_grp_comp)),
    updated_at        = NOW()
  WHERE id = v_wallet.id;

  INSERT INTO wallet_transactions
    (group_wallet_id, group_id, type, amount, reservation_id, description, balance_after)
  VALUES (v_wallet.id, v_res.group_id, 'adjustment', v_grp_comp, p_reservation_id,
    format('Compensación por cancelación del cliente — reserva %s', p_reservation_id),
    v_wallet.available_balance + v_grp_comp);

  v_admin_delta := v_plat_ret - v_service;
  SELECT id INTO v_admin_id FROM profiles WHERE role = 'admin' ORDER BY created_at LIMIT 1;
  IF v_admin_id IS NOT NULL AND v_admin_delta <> 0 THEN
    UPDATE wallets SET
      available_balance = GREATEST(0, available_balance + v_admin_delta),
      total_earned      = GREATEST(0, COALESCE(total_earned, 0) + v_admin_delta),
      updated_at        = NOW()
    WHERE user_id = v_admin_id;

    INSERT INTO wallet_transactions (user_id, type, amount, reservation_id, description)
    VALUES (v_admin_id,
      CASE WHEN v_admin_delta >= 0 THEN 'platform_income' ELSE 'debit_refund' END,
      ABS(v_admin_delta), p_reservation_id,
      format('Ajuste platform income por cancelación (%s) — reserva %s',
             v_charge->>'tier', p_reservation_id));
  END IF;

  UPDATE reservations SET
    status            = 'cancelled',
    cancelled_by      = 'client',
    cancellation_type = 'client_initiated',
    cancel_reason     = p_reason,
    cancelled_at      = NOW(),
    payout_status     = 'refunded',
    updated_at        = NOW()
  WHERE id = p_reservation_id;

  INSERT INTO financial_audit_logs
    (entity_type, entity_id, action, actor_id, actor_role, amount, notes)
  VALUES ('reservation', p_reservation_id, 'cancellation_settle', v_res.client_id, 'client',
    v_grp_comp + v_plat_ret,
    format('tier=%s refund=%s grp_comp=%s plat_ret=%s refund_id=%s',
      v_charge->>'tier', v_charge->>'refund_amount', v_grp_comp, v_plat_ret,
      COALESCE(p_refund_id, 'n/a')));

  SELECT name INTO v_group_name FROM groups WHERE id = v_res.group_id;

  INSERT INTO notifications (user_id, type, title, body, data)
  SELECT g.owner_id, 'booking',
    CASE WHEN v_grp_comp > 0 THEN '📅 Evento cancelado — compensación en tu wallet'
         ELSE '📅 Evento cancelado por el cliente' END,
    CASE WHEN v_grp_comp > 0
      THEN format('El cliente canceló el evento. Recibiste $%s MXN de compensación disponible en tu wallet por la fecha que reservaste.',
                  to_char(v_grp_comp, 'FM999,999,990'))
      ELSE 'El cliente canceló el evento con suficiente anticipación (sin cargo).'
    END,
    jsonb_build_object('screen', 'Wallet', 'reservation_id', p_reservation_id)
  FROM groups g WHERE g.id = v_res.group_id;

  IF v_admin_id IS NOT NULL THEN
    INSERT INTO notifications (user_id, type, title, body, data)
    VALUES (v_admin_id, 'admin',
      '💸 Cancelación con cargo',
      format('%s canceló (%s). Cargo total $%s: grupo $%s, Daricefy $%s. Reembolso al cliente $%s.',
        COALESCE(v_group_name, 'Reserva'), v_charge->>'tier',
        to_char(v_grp_comp + v_plat_ret, 'FM999,999,990'),
        to_char(v_grp_comp, 'FM999,999,990'),
        to_char(v_plat_ret, 'FM999,999,990'),
        v_charge->>'refund_amount'),
      jsonb_build_object('reservation_id', p_reservation_id, 'screen', 'AdminFinancial'));
  END IF;

  RETURN jsonb_build_object('ok', true,
    'tier', v_charge->>'tier',
    'refund_amount', (v_charge->>'refund_amount')::NUMERIC,
    'group_compensation', v_grp_comp,
    'platform_retained', v_plat_ret);
END;
$$;

GRANT EXECUTE ON FUNCTION public.settle_cancellation(UUID, TEXT, TEXT) TO service_role;

-- ═══════════════════════════════════════════════════════════════════
-- 2. RECONCILIACIÓN: devolver lo sobre-descontado por el fallback 0.9
--    (cancelaciones del 2026-07-11 con base_price NULL: $720 × 2 = $1,440)
-- ═══════════════════════════════════════════════════════════════════
DO $$
DECLARE
  v_row RECORD;
BEGIN
  FOR v_row IN
    SELECT r.group_id,
           SUM(ROUND(r.total_price * 0.9, 2) - r.group_earnings) AS delta
    FROM reservations r
    WHERE r.status = 'cancelled'
      AND r.payout_status = 'refunded'
      AND r.base_price IS NULL
      AND r.group_earnings IS NOT NULL
      AND r.cancelled_at >= '2026-07-11'
      AND ROUND(r.total_price * 0.9, 2) > r.group_earnings
    GROUP BY r.group_id
  LOOP
    UPDATE group_wallets SET
      pending_balance = pending_balance + v_row.delta,
      total_earned    = total_earned + v_row.delta,
      updated_at      = NOW()
    WHERE group_id = v_row.group_id;

    INSERT INTO wallet_transactions (group_wallet_id, group_id, type, amount, description)
    SELECT gw.id, v_row.group_id, 'adjustment', v_row.delta,
      'Corrección: settle usó fallback 0.9 (modelo viejo) en cancelaciones con base_price NULL — sql/467'
    FROM group_wallets gw WHERE gw.group_id = v_row.group_id;

    INSERT INTO financial_audit_logs (entity_type, entity_id, action, actor_role, amount, notes)
    VALUES ('group_wallet', v_row.group_id, 'reconciliation', 'system', v_row.delta,
      'sql/467: reversa del sobre-descuento del fallback 0.9 en settle_cancellation');

    RAISE NOTICE 'Wallet del grupo % reconciliado: +$%', v_row.group_id, v_row.delta;
  END LOOP;
END $$;

-- ═══════════════════════════════════════════════════════════════════
-- 3. release_half_on_arrival → SOLO VERIFICACIÓN DE LLEGADA
--    (misma firma — el frontend no cambia; NO mueve dinero; el 100%
--    se libera al finalizar con release_group_earnings_atomic)
-- ═══════════════════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION public.release_half_on_arrival(
  p_reservation_id UUID,
  p_lat            FLOAT8 DEFAULT NULL,
  p_lng            FLOAT8 DEFAULT NULL
)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_reservation RECORD;
  v_ev_lat      FLOAT8;
  v_ev_lng      FLOAT8;
  v_dist        NUMERIC;
  v_verified    BOOLEAN;
  v_admin_id    UUID;
  v_group_name  TEXT;
  c_umbral_m    CONSTANT NUMERIC := 250;  -- servidor 250 m (cliente 200 m)
BEGIN
  SELECT * INTO v_reservation FROM reservations WHERE id = p_reservation_id FOR UPDATE;
  IF NOT FOUND THEN RETURN jsonb_build_object('ok', false, 'error', 'not_found'); END IF;

  -- Idempotencia: llegada ya registrada
  IF v_reservation.group_arrived_at IS NOT NULL THEN
    RETURN jsonb_build_object('ok', true, 'skipped', true, 'reason', 'already_arrived',
                              'verified', v_reservation.arrival_gps_verified);
  END IF;

  -- ── CANDADO GPS (idéntico a sql/424) ───────────────────────────────
  v_ev_lat := NULL; v_ev_lng := NULL;
  IF v_reservation.quote_id IS NOT NULL THEN
    SELECT q.latitude, q.longitude INTO v_ev_lat, v_ev_lng
    FROM quotes q WHERE q.id = v_reservation.quote_id;
  END IF;
  IF (v_ev_lat IS NULL OR v_ev_lng IS NULL)
     AND v_reservation.event_request_id IS NOT NULL THEN
    SELECT COALESCE(er.latitude, er.event_lat), COALESCE(er.longitude, er.event_lng)
    INTO   v_ev_lat, v_ev_lng
    FROM   event_requests er WHERE er.id = v_reservation.event_request_id;
  END IF;

  IF v_ev_lat IS NOT NULL AND v_ev_lng IS NOT NULL THEN
    IF p_lat IS NULL OR p_lng IS NULL THEN
      RETURN jsonb_build_object('ok', false, 'error', 'gps_required');
    END IF;
    v_dist := haversine_m(p_lat, p_lng, v_ev_lat, v_ev_lng);
    IF v_dist > c_umbral_m THEN
      RETURN jsonb_build_object('ok', false, 'error', 'too_far',
                                'distance_m', ROUND(v_dist)::INT);
    END IF;
    v_verified := TRUE;
  ELSE
    -- Evento sin coords: se marca sin verificar + aviso al admin (abajo)
    v_verified := FALSE;
  END IF;

  -- ── Marcar llegada + auditoría (SIN mover dinero) ──────────────────
  UPDATE reservations SET
    group_arrived_at     = NOW(),
    arrival_lat          = p_lat,
    arrival_lng          = p_lng,
    arrival_distance_m   = CASE WHEN v_dist IS NOT NULL THEN ROUND(v_dist)::INT END,
    arrival_gps_verified = v_verified,
    updated_at           = NOW()
  WHERE id = p_reservation_id;

  INSERT INTO financial_audit_logs
    (entity_type, entity_id, action, actor_role, amount, notes)
  VALUES ('reservation', p_reservation_id, 'arrival_marked', 'system', 0,
    format('llegada gps_verified=%s dist_m=%s — dinero se libera al FINALIZAR (modelo 2026-07-11)',
           v_verified, COALESCE(ROUND(v_dist)::text, 'n/a')));

  -- Aviso al admin cuando la llegada NO pudo verificarse por GPS
  IF NOT v_verified THEN
    SELECT id INTO v_admin_id FROM profiles WHERE role = 'admin' LIMIT 1;
    SELECT name INTO v_group_name FROM groups WHERE id = v_reservation.group_id;
    IF v_admin_id IS NOT NULL THEN
      INSERT INTO notifications (user_id, type, title, body, data)
      VALUES (
        v_admin_id, 'admin',
        '📍 Llegada sin verificación GPS',
        COALESCE(v_group_name, 'Un grupo') ||
          ' marcó llegada en una reserva sin coordenadas del evento. Reserva: ' ||
          p_reservation_id::text,
        jsonb_build_object('reservation_id', p_reservation_id,
                           'group_id', v_reservation.group_id,
                           'reason', 'no_event_coords',
                           'screen', 'AdminVerifications'));
    END IF;
  END IF;

  -- Notificar al GRUPO que su llegada quedó verificada (sin dinero aún)
  INSERT INTO notifications (user_id, type, title, body, data)
  SELECT g.owner_id, 'reservation',
    '✅ Llegada registrada',
    'Tu llegada al evento quedó verificada. Tu pago completo se liberará al finalizar el evento.',
    jsonb_build_object('reservation_id', p_reservation_id)
  FROM groups g WHERE g.id = v_reservation.group_id;

  RETURN jsonb_build_object('ok', true, 'arrived', true, 'released', false,
                            'release_at', 'event_end',
                            'verified', v_verified,
                            'distance_m', CASE WHEN v_dist IS NOT NULL THEN ROUND(v_dist)::INT END);
END;
$$;

GRANT EXECUTE ON FUNCTION public.release_half_on_arrival(UUID, FLOAT8, FLOAT8)
  TO authenticated, service_role;

-- ═══════════════════════════════════════════════════════════════════
-- 4. Retiro con COMPROBANTE (espejo de reembolsos manuales)
-- ═══════════════════════════════════════════════════════════════════
ALTER TABLE payout_requests ADD COLUMN IF NOT EXISTS transfer_reference TEXT;
ALTER TABLE payout_requests ADD COLUMN IF NOT EXISTS receipt_path       TEXT;
ALTER TABLE payout_requests ADD COLUMN IF NOT EXISTS processed_by       UUID;

CREATE OR REPLACE FUNCTION public.admin_complete_payout(
  p_payout_id          UUID,
  p_transfer_reference TEXT,
  p_receipt_path       TEXT DEFAULT NULL
)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_pr RECORD;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM profiles WHERE id = auth.uid() AND role = 'admin') THEN
    RETURN jsonb_build_object('ok', false, 'error', 'Solo administradores');
  END IF;

  SELECT pr.*, g.owner_id, g.name AS group_name
  INTO v_pr
  FROM payout_requests pr JOIN groups g ON g.id = pr.group_id
  WHERE pr.id = p_payout_id FOR UPDATE OF pr;
  IF NOT FOUND THEN RETURN jsonb_build_object('ok', false, 'error', 'not_found'); END IF;
  IF v_pr.status = 'paid' THEN
    RETURN jsonb_build_object('ok', true, 'skipped', true, 'reason', 'already_paid');
  END IF;
  IF v_pr.status = 'rejected' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'Retiro rechazado, no se puede pagar');
  END IF;
  IF COALESCE(TRIM(p_transfer_reference), '') = '' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'La referencia de la transferencia es obligatoria');
  END IF;

  UPDATE payout_requests SET
    status             = 'paid',
    transfer_reference = p_transfer_reference,
    receipt_path       = COALESCE(p_receipt_path, receipt_path),
    processed_by       = auth.uid(),
    paid_at            = NOW(),
    updated_at         = NOW()
  WHERE id = p_payout_id;

  INSERT INTO financial_audit_logs (entity_type, entity_id, action, actor_id, actor_role, amount, notes)
  VALUES ('payout_request', p_payout_id, 'payout_completed', auth.uid(), 'admin', v_pr.amount,
    format('ref=%s receipt=%s', p_transfer_reference, COALESCE(p_receipt_path, 'n/a')));

  -- Notificar al grupo — con comprobante si lo hay (tap → lo abre)
  INSERT INTO notifications (user_id, type, title, body, data)
  VALUES (v_pr.owner_id, 'payment', '💸 Tu retiro fue transferido',
    format('Enviamos tu retiro de $%s MXN por transferencia%s.%s',
      to_char(v_pr.amount, 'FM999,999,990.00'),
      CASE WHEN v_pr.clabe IS NOT NULL
           THEN format(' a tu cuenta terminación %s', RIGHT(v_pr.clabe, 4)) ELSE '' END,
      CASE WHEN COALESCE(p_receipt_path, v_pr.receipt_path) IS NOT NULL
           THEN ' Toca esta notificación para ver tu comprobante.' ELSE '' END),
    jsonb_build_object('screen', 'Wallet',
                       'payout_id', p_payout_id,
                       'receipt_path', COALESCE(p_receipt_path, v_pr.receipt_path)));

  RETURN jsonb_build_object('ok', true, 'status', 'paid');
END;
$$;

GRANT EXECUTE ON FUNCTION public.admin_complete_payout(UUID, TEXT, TEXT) TO authenticated;

COMMIT;

-- ── VERIFICACIONES ────────────────────────────────────────────────────────────
-- V1: el wallet quedó reconciliado (pending debe ser 18,000 con 2 reservas vivas)
SELECT pending_balance, available_balance FROM group_wallets ORDER BY updated_at DESC LIMIT 1;

-- V2: release_half ya NO mueve dinero
SELECT prosrc LIKE '%SIN mover dinero%' AS arrival_solo_verifica
FROM pg_proc WHERE proname = 'release_half_on_arrival';
-- Esperado: true

-- V3: settle usa el modelo 20%
SELECT prosrc LIKE '%/ 1.20%' AS settle_modelo_20
FROM pg_proc WHERE proname = 'settle_cancellation';
-- Esperado: true

-- V4: retiro con comprobante listo
SELECT column_name FROM information_schema.columns
WHERE table_name = 'payout_requests' AND column_name IN ('receipt_path','transfer_reference');
-- Esperado: 2 filas

SELECT '467_full_release_at_event_end.sql ejecutado ✅' AS status;
