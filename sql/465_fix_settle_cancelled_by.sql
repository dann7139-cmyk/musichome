-- ============================================================
-- sql/465_fix_settle_cancelled_by.sql
-- FIX: settle_cancellation violaba reservations_cancelled_by_check.
--
-- Causa (encontrada en prueba real 2026-07-11): sql/439 escribía
--   cancelled_by = v_res.client_id (UUID)
-- pero la columna es TEXT con CHECK IN ('group','client','admin','system')
-- (sql/107). La colisión de esquema ya estaba diagnosticada el 2026-07-05.
--
-- Cambio ÚNICO: cancelled_by = 'client'. Quién fue exactamente ya queda
-- en financial_audit_logs.actor_id y en la propia reserva (client_id).
-- Todo lo demás es idéntico a sql/439.
-- ============================================================

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

  v_base    := COALESCE(v_res.base_price,          ROUND(v_res.total_price * 0.9,  2));
  v_service := COALESCE(v_res.service_fee_amount,  ROUND(v_res.total_price * 0.10, 2));

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

  -- 🔧 FIX: cancelled_by es TEXT con CHECK ('group','client','admin','system')
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

-- ── VERIFICACIÓN ──────────────────────────────────────────────────────────────
-- V1: el cuerpo ya no escribe el UUID en cancelled_by
SELECT prosrc LIKE '%cancelled_by      = ''client''%' AS fix_aplicado
FROM pg_proc WHERE proname = 'settle_cancellation';
-- Esperado: true

SELECT '465_fix_settle_cancelled_by.sql ejecutado ✅' AS status;
