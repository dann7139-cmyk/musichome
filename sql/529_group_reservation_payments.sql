-- ============================================================
-- sql/529_group_reservation_payments.sql
-- Fase P1C — Anticipos por reservation_id, admin-only, solo payout_status='held'
--
-- REGLAS DEFINITIVAS (aprobadas tras auditoría de invariantes + delta de
-- correcciones):
--   1. Anticipos únicamente con payout_status='held'.
--   2. Solo descuenta pending_balance — NUNCA available_balance en esta fase
--      (mientras request_withdrawal siga vivo hasta P1D).
--   3. released/half_released/blocked/refunded → rechazo explícito, cero
--      mutaciones. half_released se excluye deliberadamente: confirmado
--      inactivo hoy (0 filas en producción, release_half_on_arrival() no
--      libera dinero), y su manejo correcto requeriría matemática
--      proporcional que no aporta valor real ahora mismo.
--   4. group_id SIEMPRE derivado de reservations.group_id — jamás parámetro.
--   5. Ninguna escritura directa desde cliente — solo vía
--      admin_register_group_payment (RLS sin policy de INSERT/UPDATE/DELETE).
--   6. Orden de locks (verificado contra el código real de
--      confirm_reservation_payment_v2/_apply_confirmed_credit, el más
--      seguro de los patrones existentes):
--        leer group_id sin lock → pg_advisory_xact_lock(group_id) →
--        reservation FOR UPDATE (relectura bajo el candado) → wallet FOR UPDATE.
--
-- Rollback: sql/529_group_reservation_payments_ROLLBACK.sql
-- ============================================================

BEGIN;

-- ── 1. Tabla ──────────────────────────────────────────────────────────────
CREATE TABLE public.group_reservation_payments (
  id                    UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  reservation_id        UUID NOT NULL REFERENCES reservations(id) ON DELETE CASCADE,
  group_id              UUID NOT NULL REFERENCES groups(id) ON DELETE CASCADE,
  amount                NUMERIC NOT NULL,
  kind                  TEXT NOT NULL,
  wallet_bucket_debited TEXT NOT NULL,
  receipt_path          TEXT,
  note                  TEXT,
  registered_by         UUID NOT NULL REFERENCES profiles(id),
  created_at            TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

ALTER TABLE public.group_reservation_payments
  ADD CONSTRAINT chk_grp_pay_amount_positive CHECK (amount > 0),
  ADD CONSTRAINT chk_grp_pay_kind CHECK (kind IN ('advance','final_settlement')),
  ADD CONSTRAINT chk_grp_pay_bucket CHECK (wallet_bucket_debited IN ('pending','available'));

CREATE INDEX idx_grp_payments_reservation ON public.group_reservation_payments(reservation_id);
CREATE INDEX idx_grp_payments_group       ON public.group_reservation_payments(group_id);

-- ── 2. RLS — solo lectura desde cliente, cero escritura directa ───────────
ALTER TABLE public.group_reservation_payments ENABLE ROW LEVEL SECURITY;

REVOKE INSERT, UPDATE, DELETE ON public.group_reservation_payments FROM authenticated, anon;
GRANT SELECT ON public.group_reservation_payments TO authenticated;

CREATE POLICY grp_pay_admin_read ON public.group_reservation_payments FOR SELECT
  USING (EXISTS (SELECT 1 FROM profiles WHERE id = auth.uid() AND role = 'admin'));

CREATE POLICY grp_pay_owner_read ON public.group_reservation_payments FOR SELECT
  USING (EXISTS (SELECT 1 FROM groups g WHERE g.id = group_id AND g.owner_id = auth.uid()));

-- Deliberadamente NINGUNA policy de INSERT/UPDATE/DELETE.

-- ── 3. Nuevo tipo en wallet_transactions ───────────────────────────────────
ALTER TABLE public.wallet_transactions DROP CONSTRAINT chk_wt_type;
ALTER TABLE public.wallet_transactions ADD CONSTRAINT chk_wt_type
  CHECK (type = ANY (ARRAY[
    'credit_pending','credit_available','release_to_available','debit_payout',
    'refund_dispute','adjustment','event_earning','extra_hour','withdrawal',
    'commission','refund','platform_income','debit_refund','ad_income',
    'bid_income','recommendation_income','commission_correction',
    'manual_advance'
  ]));

-- ── 4. RPC de escritura — único punto de entrada ───────────────────────────
CREATE OR REPLACE FUNCTION public.admin_register_group_payment(
  p_reservation_id UUID, p_amount NUMERIC, p_kind TEXT,
  p_receipt_path TEXT DEFAULT NULL, p_note TEXT DEFAULT NULL
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $function$
DECLARE
  v_group_id    UUID;
  v_res         RECORD;
  v_wallet      RECORD;
  v_ya_pagado   NUMERIC;
  v_disponible  NUMERIC;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM profiles WHERE id = auth.uid() AND role = 'admin') THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_admin');
  END IF;

  IF p_kind <> 'advance' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'kind_not_available_yet');
  END IF;
  IF p_amount IS NULL OR p_amount <= 0 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_amount');
  END IF;

  -- Orden de locks: leer group_id sin lock → advisory lock → reservation FOR UPDATE
  SELECT group_id INTO v_group_id FROM reservations WHERE id = p_reservation_id;
  IF v_group_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_found');
  END IF;

  PERFORM pg_advisory_xact_lock(hashtext(v_group_id::text));

  SELECT * INTO v_res FROM reservations WHERE id = p_reservation_id FOR UPDATE;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_found');
  END IF;
  IF v_res.group_id IS DISTINCT FROM v_group_id THEN
    RETURN jsonb_build_object('ok', false, 'error', 'temporary_retry');
  END IF;

  IF v_res.payment_status NOT IN ('paid','fully_paid','deposit_paid') THEN
    RETURN jsonb_build_object('ok', false, 'error', 'payment_not_confirmed');
  END IF;

  -- [P1C] ÚNICO estado elegible: held. released/half_released/blocked/refunded → rechazo.
  IF v_res.payout_status <> 'held' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'payout_status_not_eligible',
      'payout_status', v_res.payout_status);
  END IF;

  PERFORM ensure_group_wallet(v_res.group_id);
  SELECT * INTO v_wallet FROM group_wallets WHERE group_id = v_res.group_id FOR UPDATE;

  SELECT COALESCE(SUM(amount),0) INTO v_ya_pagado
  FROM group_reservation_payments WHERE reservation_id = p_reservation_id;
  IF v_ya_pagado + p_amount > COALESCE(v_res.group_earnings,0) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'exceeds_group_earnings',
      'ya_pagado', v_ya_pagado, 'group_earnings', v_res.group_earnings);
  END IF;

  -- [P1C] Bucket siempre 'pending' — nunca 'available' mientras request_withdrawal siga vivo.
  v_disponible := v_wallet.pending_balance;
  IF v_disponible < p_amount THEN
    RETURN jsonb_build_object('ok', false, 'error', 'insufficient_wallet_bucket',
      'bucket', 'pending', 'disponible', v_disponible,
      'hint', 'Este grupo ya recibió este dinero por otra vía — revisa su historial antes de continuar');
  END IF;

  UPDATE group_wallets SET pending_balance = pending_balance - p_amount, updated_at = NOW()
  WHERE id = v_wallet.id;

  INSERT INTO group_reservation_payments
    (reservation_id, group_id, amount, kind, wallet_bucket_debited, receipt_path, note, registered_by)
  VALUES (p_reservation_id, v_res.group_id, p_amount, p_kind, 'pending', p_receipt_path, p_note, auth.uid());

  INSERT INTO wallet_transactions (group_wallet_id, group_id, type, amount, reservation_id, description, balance_after, currency_code)
  SELECT gw.id, gw.group_id, 'manual_advance', p_amount, p_reservation_id,
    format('Anticipo manual registrado — reserva %s', p_reservation_id),
    gw.pending_balance,
    COALESCE(v_res.currency_code, 'MXN')
  FROM group_wallets gw WHERE gw.id = v_wallet.id;

  INSERT INTO financial_audit_logs (entity_type, entity_id, action, actor_id, actor_role, amount, notes)
  VALUES ('reservation', p_reservation_id, 'manual_advance', auth.uid(), 'admin', p_amount,
    format('bucket=pending receipt=%s', COALESCE(p_receipt_path,'n/a')));

  INSERT INTO notifications (user_id, type, title, body, data)
  SELECT g.owner_id, 'payment', '💵 Anticipo recibido',
    format('Recibiste un anticipo de $%s para tu evento del %s.', p_amount, v_res.event_date),
    jsonb_build_object('reservation_id', p_reservation_id, 'screen', 'Wallet')
  FROM groups g WHERE g.id = v_res.group_id;

  RETURN jsonb_build_object('ok', true, 'bucket_debitado', 'pending', 'total_anticipado', v_ya_pagado + p_amount);
END;
$function$;

GRANT EXECUTE ON FUNCTION public.admin_register_group_payment(UUID, NUMERIC, TEXT, TEXT, TEXT) TO authenticated;

-- ── 5. Corrección quirúrgica a release_group_earnings_atomic ───────────────
-- Único cambio: restar anticipos ya tomados de 'pending' antes de liberar,
-- y omitir el INSERT en wallet_transactions si el resultado es $0 (el CHECK
-- amount > 0 lo rechazaría).
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
  v_ya_anticipado_pending NUMERIC; -- [P1C]
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

  -- [P1C] Restar anticipos ya tomados de pending antes de liberar
  SELECT COALESCE(SUM(amount),0) INTO v_ya_anticipado_pending
  FROM group_reservation_payments
  WHERE reservation_id = p_reservation_id AND wallet_bucket_debited = 'pending';

  v_to_release := GREATEST(0, v_to_release - v_ya_anticipado_pending);

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

  -- [P1C] Omitir el INSERT si no hay nada que liberar (CHECK amount > 0)
  IF v_to_release > 0 THEN
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
  END IF;

  INSERT INTO financial_audit_logs
    (entity_type, entity_id, action, actor_id, actor_role, amount, notes)
  VALUES ('reservation', p_reservation_id, 'release', p_released_by, v_actor_role, v_to_release,
    format('currency=%s payout_status_was=%s anticipado_pending=%s', v_currency, v_reservation.payout_status, v_ya_anticipado_pending));

  IF v_to_release > 0 THEN
    INSERT INTO notifications (user_id, type, title, body, data)
    SELECT g.owner_id, 'payout', '🎉 Ganancias liberadas',
      format('$%s %s disponibles en tu billetera.',
        to_char(v_to_release, 'FM999,999,990'), v_currency),
      jsonb_build_object('screen','Wallet','reservation_id',p_reservation_id)
    FROM groups g WHERE g.id = v_reservation.group_id;
  END IF;

  RETURN jsonb_build_object(
    'ok',            true,
    'released',      v_to_release,
    'currency',      v_currency,
    'payout_status', 'released'
  );
END;
$function$;

-- ── 6. Actualizar P1B para reflejar anticipos reales ───────────────────────
CREATE OR REPLACE FUNCTION public.admin_get_pending_group_payments(p_limit integer DEFAULT 50)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE
  v_result jsonb;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM profiles WHERE id = auth.uid() AND role = 'admin') THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_admin');
  END IF;

  SELECT jsonb_build_object(
    'ok', true,
    'items', COALESCE(jsonb_agg(x.item ORDER BY x.event_date DESC NULLS LAST), '[]'::jsonb)
  )
  INTO v_result
  FROM (
    SELECT
      r.event_date,
      jsonb_build_object(
        'reservation_id',   r.id,
        'folio',            r.folio,
        'event_date',       r.event_date,
        'event_time',       r.event_time,
        'group_id',         r.group_id,
        'group_name',       g.name,
        'client_name',      p.full_name,
        'group_earnings',   r.group_earnings,
        'total_anticipado', COALESCE(gp.total_anticipado, 0),
        'saldo_pendiente',  r.group_earnings - COALESCE(gp.total_anticipado, 0),
        'bank_clabe',       w.bank_clabe,
        'bank_name',        w.bank_name,
        'account_holder',   w.account_holder,
        'bank_linked_at',   w.bank_linked_at
      ) AS item
    FROM reservations r
    JOIN      groups   g ON g.id = r.group_id
    LEFT JOIN profiles p ON p.id = r.client_id
    LEFT JOIN wallets   w ON w.user_id = g.owner_id
    LEFT JOIN LATERAL (
      SELECT SUM(amount) AS total_anticipado
      FROM group_reservation_payments
      WHERE reservation_id = r.id
    ) gp ON true
    WHERE r.payout_status  = 'released'
      AND r.payment_status IN ('paid','fully_paid','deposit_paid')
      AND COALESCE(r.group_earnings, 0) > 0
      AND (r.group_earnings - COALESCE(gp.total_anticipado, 0)) > 0
    ORDER BY r.event_date DESC NULLS LAST
    LIMIT p_limit
  ) x;

  RETURN v_result;
END;
$function$;

COMMIT;

-- ── Verificación ──────────────────────────────────────────────────
SELECT proname, prosecdef FROM pg_proc
WHERE pronamespace = 'public'::regnamespace
  AND proname IN ('admin_register_group_payment','release_group_earnings_atomic','admin_get_pending_group_payments');

SELECT '529_group_reservation_payments ✅' AS status;
