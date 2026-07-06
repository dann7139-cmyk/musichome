-- ============================================================
-- sql/439_c2a_cancellation_charge.sql
-- C2a — Cancelación del cliente CON CARGO por proximidad.
--
-- Decisiones de producto (usuario 2026-07-05):
--   PROGRAMADAS (por proximidad al evento):
--     >15 días  → 0% retenido, reembolso 100%
--     7-15 días → 10% retenido (7% grupo / 3% Daricefy), reembolso 90%
--     <7 días   → 25% retenido (17.5% grupo / 7.5% Daricefy), reembolso 75%
--   EXPRÉS (para hoy, siempre última hora):
--     fijo 25% retenido (17.5% grupo / 7.5% Daricefy), reembolso 75%
--   · El cargo se DESCUENTA del reembolso (refund parcial vía Stripe/C1).
--   · La compensación del grupo va a su wallet como DISPONIBLE de
--     inmediato (el evento ya no ocurrirá — no hay inicio que esperar).
--   · La parte de Daricefy se queda como platform income.
--
-- Conservación del dinero (independiente del % de comisión, porque se
-- lee base_price/service_fee_amount de la fila):
--   total = refund_al_cliente + group_compensation + platform_retained
--   Δgrupo(-base+comp) + Δadmin(retained-service_fee) = -refund  ✓
--
-- Dos funciones:
--   compute_cancellation_charge — read-only, para el diálogo y la Edge
--     Function (fuente autoritativa del monto a reembolsar).
--   settle_cancellation — service_role, reparte wallets + estado.
--     Idempotente (payout_status final 'refunded'; C0 no la re-bloquea).
-- ============================================================

BEGIN;

-- ── 1. compute_cancellation_charge (read-only, authoritative) ────────────────
CREATE OR REPLACE FUNCTION public.compute_cancellation_charge(p_reservation_id UUID)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_res        RECORD;
  v_is_express BOOLEAN;
  v_days       INT;
  v_total      NUMERIC;
  v_grp_pct    NUMERIC := 0;   -- % de total para el grupo (compensación)
  v_plat_pct   NUMERIC := 0;   -- % de total para Daricefy
  v_tier       TEXT;
  v_grp_comp   NUMERIC;
  v_plat_ret   NUMERIC;
  v_refund     NUMERIC;
BEGIN
  SELECT * INTO v_res FROM reservations WHERE id = p_reservation_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_found');
  END IF;

  v_total      := v_res.total_price;
  v_is_express := v_res.event_request_id IS NOT NULL;

  -- Sin pago confirmado → cancelación libre, sin reembolso ni cargo
  IF v_res.payment_status NOT IN ('paid','fully_paid','deposit_paid') THEN
    RETURN jsonb_build_object(
      'ok', true, 'tier', 'not_paid', 'is_express', v_is_express,
      'total_price', v_total, 'refund_amount', 0,
      'group_compensation', 0, 'platform_retained', 0, 'retain_amount', 0);
  END IF;

  -- Días hasta el evento (fecha local MX, granularidad de día)
  v_days := v_res.event_date - (NOW() AT TIME ZONE 'America/Mexico_City')::date;

  IF v_is_express THEN
    -- Exprés: cargo fijo 25%, sin tiers
    v_tier := 'express_25'; v_grp_pct := 0.175; v_plat_pct := 0.075;
  ELSIF v_days > 15 THEN
    v_tier := 'free';       v_grp_pct := 0;     v_plat_pct := 0;
  ELSIF v_days >= 7 THEN
    v_tier := 'partial_10'; v_grp_pct := 0.07;  v_plat_pct := 0.03;
  ELSE
    v_tier := 'partial_25'; v_grp_pct := 0.175; v_plat_pct := 0.075;
  END IF;

  v_grp_comp := ROUND(v_total * v_grp_pct,  2);
  v_plat_ret := ROUND(v_total * v_plat_pct, 2);
  v_refund   := ROUND(v_total - v_grp_comp - v_plat_ret, 2);

  RETURN jsonb_build_object(
    'ok', true,
    'tier', v_tier,
    'is_express', v_is_express,
    'days_until', v_days,
    'total_price', v_total,
    'refund_amount', v_refund,
    'retain_amount', v_grp_comp + v_plat_ret,
    'group_compensation', v_grp_comp,
    'platform_retained', v_plat_ret
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.compute_cancellation_charge(UUID) TO authenticated, service_role;

-- ── 2. settle_cancellation (service_role — reparte y cierra) ──────────────────
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
  v_base       NUMERIC;   -- lo que el grupo tenía retenido (pending)
  v_service    NUMERIC;   -- lo que Daricefy contabilizó al pagar
  v_admin_delta NUMERIC;  -- ajuste a la wallet del admin (retained - service)
  v_wallet     RECORD;
  v_admin_id   UUID;
  v_group_name TEXT;
BEGIN
  SELECT * INTO v_res FROM reservations WHERE id = p_reservation_id FOR UPDATE;
  IF NOT FOUND THEN RETURN jsonb_build_object('ok', false, 'error', 'not_found'); END IF;

  -- Idempotencia: ya liquidada
  IF v_res.status = 'cancelled' AND v_res.payout_status = 'refunded' THEN
    RETURN jsonb_build_object('ok', true, 'skipped', true, 'reason', 'already_settled');
  END IF;

  -- Solo se liquida dinero aún retenido (antes del evento). Si ya se
  -- liberó (llegada/post-evento) NO es cancelable por esta vía.
  IF v_res.payout_status NOT IN ('held', 'blocked') THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_cancellable',
      'payout_status', v_res.payout_status);
  END IF;

  v_charge   := public.compute_cancellation_charge(p_reservation_id);
  v_grp_comp := (v_charge->>'group_compensation')::NUMERIC;
  v_plat_ret := (v_charge->>'platform_retained')::NUMERIC;

  v_base    := COALESCE(v_res.base_price,          ROUND(v_res.total_price * 0.9,  2));
  v_service := COALESCE(v_res.service_fee_amount,  ROUND(v_res.total_price * 0.10, 2));

  -- ── Wallet del GRUPO: revierte lo retenido y acredita la compensación
  --    como DISPONIBLE (el evento no ocurrirá) ────────────────────────
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

  -- ── Wallet del ADMIN (platform income): ajusta a lo realmente retenido
  --    delta = platform_retained - service_fee (normalmente negativo) ──
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

  -- ── Reserva: cancelada + payout FINAL 'refunded' (C0 no re-bloquea,
  --    crons de liberación la excluyen) ───────────────────────────────
  UPDATE reservations SET
    status            = 'cancelled',
    cancelled_by      = v_res.client_id,
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

  -- ── Notificaciones ────────────────────────────────────────────────
  SELECT name INTO v_group_name FROM groups WHERE id = v_res.group_id;

  -- Grupo
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

  -- Admin (desglose)
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

COMMIT;

-- ── PRE-CHECKS (léelos antes; informativos) ───────────────────────────────────
-- P1: columnas de dinero que usa la lógica existen y están pobladas
SELECT
  COUNT(*)                                            AS reservas_pagadas,
  COUNT(*) FILTER (WHERE base_price IS NULL)          AS sin_base_price,
  COUNT(*) FILTER (WHERE service_fee_amount IS NULL)  AS sin_service_fee
FROM reservations
WHERE payment_status IN ('paid','fully_paid','deposit_paid');

-- ── VERIFICACIONES ────────────────────────────────────────────────────────────
-- V1: ambas funciones existen con los grants correctos
SELECT proname, pg_get_function_identity_arguments(oid) AS firma
FROM pg_proc
WHERE proname IN ('compute_cancellation_charge', 'settle_cancellation')
ORDER BY proname;
-- Esperado: compute_cancellation_charge(uuid) | settle_cancellation(uuid, text, text)

-- V2: tiers correctos (simulación pura, sin tocar datos) para una reserva real.
--     Cambia el UUID por una reserva PROGRAMADA pagada tuya para ver el desglose:
-- SELECT compute_cancellation_charge('<reservation_id>');
-- Debe devolver tier según días: >15 free, 7-15 partial_10, <7 partial_25;
-- exprés → express_25. refund + group_compensation + platform_retained = total_price.

-- V3: conservación del dinero — para CUALQUIER reserva, las tres partes suman el total
-- SELECT (c->>'refund_amount')::numeric + (c->>'group_compensation')::numeric
--        + (c->>'platform_retained')::numeric AS suma,
--        total_price
-- FROM reservations r,
--      LATERAL compute_cancellation_charge(r.id) c
-- WHERE r.payment_status IN ('paid','fully_paid','deposit_paid')
-- LIMIT 5;
-- Esperado: suma = total_price en cada fila

SELECT '439_c2a_cancellation_charge.sql ejecutado ✅' AS status;
