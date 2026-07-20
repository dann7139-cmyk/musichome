-- ============================================================
-- sql/521_admin_payment_resolution_ROLLBACK.sql — ROLLBACK DE 521
--
-- ⚠️⚠️ NO EJECUTAR en el orden normal. Solo emergencia deliberada.
-- Restaura confirm_reservation_payment_v2 EXACTAMENTE como en sql/519
-- y elimina todo lo creado por 521.
--
-- GUARD: aborta si existe evidencia registrada, resoluciones manuales
-- o intents reclamados — historial financiero/probatorio NO se borra:
-- resolver hacia adelante.
-- ============================================================

BEGIN;

-- ── 0. GUARD AMPLIADO ────────────────────────────────────────
-- Aborta ante CUALQUIER dato financiero/probatorio cuya pérdida o
-- desconexión sería irreversible. No es posible distinguir con certeza
-- qué filas nacieron "bajo 521", así que el guard es máximamente
-- conservador: si el gate o la resolución ya procesaron ALGO, este
-- rollback destructivo queda prohibido → resolver hacia adelante.
DO $$
DECLARE
  v_ev   INT;  -- evidencias registradas
  v_obj  INT;  -- archivos en el bucket de evidencia
  v_res  INT;  -- receipts resueltos manualmente
  v_rc   INT;  -- receipts existentes (cualquiera)
  v_cl   INT;  -- intents reclamados/completados
  v_pi   INT;  -- intents abiertos (pending/processing)
  v_snap INT;  -- attempts con snapshot contractual poblado
BEGIN
  SELECT COUNT(*) INTO v_ev   FROM admin_payment_evidence;
  SELECT COUNT(*) INTO v_obj  FROM storage.objects WHERE bucket_id = 'payment-evidence';
  SELECT COUNT(*) INTO v_res  FROM payment_receipts WHERE resolution IS NOT NULL;
  SELECT COUNT(*) INTO v_rc   FROM payment_receipts;
  SELECT COUNT(*) INTO v_cl   FROM refund_intents WHERE claimed_by IS NOT NULL OR status = 'done';
  SELECT COUNT(*) INTO v_pi   FROM refund_intents WHERE status IN ('pending','processing');
  SELECT COUNT(*) INTO v_snap FROM payment_attempts
    WHERE group_base_minor IS NOT NULL OR platform_fee_minor IS NOT NULL;

  IF v_ev > 0 OR v_obj > 0 OR v_res > 0 OR v_rc > 0
     OR v_cl > 0 OR v_pi > 0 OR v_snap > 0 THEN
    RAISE EXCEPTION USING MESSAGE = format(
      'ROLLBACK PROHIBIDO — datos cuya pérdida sería irreversible: '
      || 'evidencias=%s, archivos_evidencia=%s, receipts_resueltos=%s, '
      || 'receipts_totales=%s, intents_procesados=%s, intents_abiertos=%s, '
      || 'attempts_con_snapshot=%s. El historial financiero, los snapshots '
      || 'contractuales y las colas abiertas NO se borran: resolver hacia adelante.',
      v_ev, v_obj, v_res, v_rc, v_cl, v_pi, v_snap);
  END IF;
END $$;

-- ── 1. RPCs y funciones nuevas de 521 ────────────────────────
DROP FUNCTION IF EXISTS public.admin_pending_receipts();
DROP FUNCTION IF EXISTS public.admin_complete_refund_intent(UUID,TEXT,TEXT,TEXT,TEXT);
DROP FUNCTION IF EXISTS public.resolve_payment_receipt(
  UUID,TEXT,TEXT,TEXT,UUID,UUID,BIGINT,TEXT,TEXT,UUID);
DROP FUNCTION IF EXISTS public.register_payment_evidence(
  TEXT,TEXT,TEXT,UUID,BOOLEAN,BIGINT,TEXT,BIGINT,BIGINT,BIGINT,BIGINT,
  TIMESTAMPTZ,JSONB,JSONB,TEXT,TEXT,TEXT,UUID);

-- ── 2. Evidencia (guard ya verificó que está vacía) ──────────
DROP TRIGGER IF EXISTS trg_evidence_immutable ON admin_payment_evidence;
DROP FUNCTION IF EXISTS public.evidence_immutable_guard();
DROP TABLE IF EXISTS admin_payment_evidence;

-- Bucket de evidencia: políticas fuera y, como el guard ya verificó que
-- está vacío, el bucket también se elimina.
DROP POLICY IF EXISTS pe_admin_insert ON storage.objects;
DROP POLICY IF EXISTS pe_admin_select ON storage.objects;
DELETE FROM storage.buckets
WHERE id = 'payment-evidence'
  AND NOT EXISTS (SELECT 1 FROM storage.objects WHERE bucket_id = 'payment-evidence');

-- ── 3. RESTAURAR confirm_reservation_payment_v2 (cuerpo de sql/519) ─
CREATE OR REPLACE FUNCTION public.confirm_reservation_payment_v2(
  p_provider            TEXT,
  p_provider_order_id   TEXT,
  p_provider_payment_id TEXT,
  p_reservation_id      UUID,
  p_amount_minor        BIGINT,
  p_currency            TEXT,
  p_method              TEXT    DEFAULT NULL,
  p_fee_minor           BIGINT  DEFAULT NULL,
  p_fee_source          TEXT    DEFAULT NULL,
  p_legacy_expected     JSONB   DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_attempt        RECORD;
  v_res            RECORD;
  v_group_id       UUID;
  v_receipt_id     UUID;
  v_existing       RECORD;
  v_expected_minor BIGINT;
  v_expected_cur   TEXT;
  v_is_legacy      BOOLEAN := FALSE;
  v_currency       TEXT;
  v_result         TEXT;
  v_reason         TEXT;
  v_block_paysts   BOOLEAN := TRUE;
  v_window_h       INT;
  v_method_key     TEXT;
  v_range          TSTZRANGE;
  v_sched          TEXT;
  v_earnings       NUMERIC;
  v_service_fee    NUMERIC;
  v_msi_fee        NUMERIC;
  v_admin_bruto    NUMERIC;
  v_admin_id       UUID;
  v_wallet_id      UUID;
  v_fee_pesos      NUMERIC;
BEGIN
  PERFORM set_config('lock_timeout', '5000', TRUE);

  IF p_provider NOT IN ('stripe','conekta')
     OR COALESCE(TRIM(p_provider_payment_id), '') = ''
     OR p_amount_minor IS NULL OR p_amount_minor < 0
     OR UPPER(COALESCE(p_currency,'')) NOT IN ('MXN','USD','CAD') THEN
    RAISE EXCEPTION 'confirm_reservation_payment_v2: parámetros inválidos (provider=%, payment=%, amount=%, currency=%)',
      p_provider, p_provider_payment_id, p_amount_minor, p_currency;
  END IF;
  v_currency := UPPER(p_currency);

  SELECT * INTO v_attempt
  FROM payment_attempts
  WHERE provider = p_provider AND provider_order_id = p_provider_order_id;

  IF FOUND THEN
    v_expected_minor := v_attempt.expected_amount_minor;
    v_expected_cur   := UPPER(v_attempt.currency);
    v_method_key     := COALESCE(v_attempt.method, p_method, 'card');

    IF v_attempt.reservation_id IS DISTINCT FROM p_reservation_id THEN
      INSERT INTO payment_receipts
        (provider, provider_payment_id, provider_order_id, attempt_id,
         reservation_id, amount_minor, currency, method,
         result, money_state, raw_meta)
      VALUES
        (p_provider, p_provider_payment_id, p_provider_order_id, v_attempt.id,
         NULL, p_amount_minor, v_currency, p_method,
         'payment_identity_conflict', 'recorded',
         jsonb_build_object('metadata_reservation', p_reservation_id,
                            'attempt_reservation', v_attempt.reservation_id))
      ON CONFLICT (provider, provider_payment_id) DO NOTHING;

      INSERT INTO financial_audit_logs
        (entity_type, entity_id, action, actor_id, actor_role, amount, notes)
      VALUES ('payment', v_attempt.reservation_id, 'payment_identity_conflict',
        NULL, 'system', p_amount_minor / 100.0,
        format('SEVERIDAD ALTA: pago %s/%s con metadata reserva=%s pero intento reserva=%s. Sin mutaciones, sin reembolso automático. Requiere revisión humana.',
          p_provider, p_provider_payment_id, p_reservation_id, v_attempt.reservation_id));

      INSERT INTO notifications (user_id, type, title, body, data)
      SELECT p.id, 'reservation', '🚨 Conflicto de identidad de pago',
        format('El pago %s (%s) no coincide con su intento de checkout. NO se movió dinero. Revisa el panel financiero.',
          p_provider_payment_id, p_provider),
        jsonb_build_object('screen', 'AdminFinancial',
                           'provider_payment_id', p_provider_payment_id)
      FROM profiles p WHERE p.role = 'admin';

      RETURN jsonb_build_object('result', 'payment_identity_conflict');
    END IF;

  ELSE
    IF p_legacy_expected IS NOT NULL
       AND (p_legacy_expected->>'amount_minor') IS NOT NULL
       AND NOW() < COALESCE(
             (SELECT value::DATE FROM payment_config
              WHERE key = 'legacy_attempt_cutoff'), DATE '2026-08-31') THEN
      v_is_legacy      := TRUE;
      v_expected_minor := (p_legacy_expected->>'amount_minor')::BIGINT;
      v_expected_cur   := UPPER(COALESCE(p_legacy_expected->>'currency', v_currency));
      v_method_key     := COALESCE(p_method, 'card');

      IF (p_legacy_expected->>'reservation_id')::UUID IS DISTINCT FROM p_reservation_id THEN
        RAISE EXCEPTION 'legacy_expected inconsistente con p_reservation_id';
      END IF;

      INSERT INTO financial_audit_logs
        (entity_type, entity_id, action, actor_id, actor_role, amount, notes)
      VALUES ('payment', p_reservation_id, 'legacy_without_attempt',
        NULL, 'system', p_amount_minor / 100.0,
        format('Pago %s/%s procesado SIN captura local (creado pre-F2.2). Esperado tomado del objeto re-consultado al proveedor. Camino con fecha de retiro (payment_config.legacy_attempt_cutoff).',
          p_provider, p_provider_payment_id));
    ELSE
      INSERT INTO payment_receipts
        (provider, provider_payment_id, provider_order_id, reservation_id,
         amount_minor, currency, method, result, money_state, raw_meta)
      VALUES
        (p_provider, p_provider_payment_id, p_provider_order_id,
         (SELECT id FROM reservations WHERE id = p_reservation_id),
         p_amount_minor, v_currency, p_method,
         'capture_missing', 'recorded',
         jsonb_build_object('metadata_reservation', p_reservation_id))
      ON CONFLICT (provider, provider_payment_id) DO NOTHING;

      INSERT INTO financial_audit_logs
        (entity_type, entity_id, action, actor_id, actor_role, amount, notes)
      VALUES ('payment', p_reservation_id, 'capture_missing',
        NULL, 'system', p_amount_minor / 100.0,
        format('SEVERIDAD ALTA: pago %s/%s sin captura de checkout ni snapshot legacy verificable. Sin mutaciones, sin reembolso automático. Resolución manual.',
          p_provider, p_provider_payment_id));

      INSERT INTO notifications (user_id, type, title, body, data)
      SELECT p.id, 'reservation', '🚨 Pago sin captura de checkout',
        format('Llegó el pago %s (%s) y no existe registro del intento. NO se movió dinero. Revisa el panel financiero.',
          p_provider_payment_id, p_provider),
        jsonb_build_object('screen', 'AdminFinancial',
                           'provider_payment_id', p_provider_payment_id)
      FROM profiles p WHERE p.role = 'admin';

      RETURN jsonb_build_object('result', 'capture_missing');
    END IF;
  END IF;

  SELECT group_id INTO v_group_id FROM reservations WHERE id = p_reservation_id;
  IF NOT FOUND THEN
    INSERT INTO payment_receipts
      (provider, provider_payment_id, provider_order_id, attempt_id,
       amount_minor, currency, method, result, money_state,
       legacy_without_attempt, raw_meta)
    VALUES
      (p_provider, p_provider_payment_id, p_provider_order_id,
       CASE WHEN v_is_legacy THEN NULL ELSE v_attempt.id END,
       p_amount_minor, v_currency, p_method,
       'payment_identity_conflict', 'recorded', v_is_legacy,
       jsonb_build_object('metadata_reservation', p_reservation_id,
                          'motivo', 'reserva_inexistente'))
    ON CONFLICT (provider, provider_payment_id) DO NOTHING;

    INSERT INTO financial_audit_logs
      (entity_type, entity_id, action, actor_id, actor_role, amount, notes)
    VALUES ('payment', NULL, 'payment_identity_conflict', NULL, 'system',
      p_amount_minor / 100.0,
      format('SEVERIDAD ALTA: pago %s/%s con metadata de reserva inexistente %s. Sin reembolso automático.',
        p_provider, p_provider_payment_id, p_reservation_id));

    INSERT INTO notifications (user_id, type, title, body, data)
    SELECT p.id, 'reservation', '🚨 Conflicto de identidad de pago',
      format('El pago %s apunta a una reserva inexistente. Revisa el panel financiero.', p_provider_payment_id),
      jsonb_build_object('screen', 'AdminFinancial')
    FROM profiles p WHERE p.role = 'admin';

    RETURN jsonb_build_object('result', 'payment_identity_conflict');
  END IF;

  PERFORM pg_advisory_xact_lock(hashtext(v_group_id::text));

  SELECT * INTO v_res FROM reservations WHERE id = p_reservation_id FOR UPDATE;

  IF v_res.group_id IS DISTINCT FROM v_group_id THEN
    RETURN jsonb_build_object('result', 'temporary_retry');
  END IF;

  INSERT INTO payment_receipts
    (provider, provider_payment_id, provider_order_id, attempt_id,
     reservation_id, amount_minor, currency, method,
     result, money_state, legacy_without_attempt)
  VALUES
    (p_provider, p_provider_payment_id, p_provider_order_id,
     CASE WHEN v_is_legacy THEN NULL ELSE v_attempt.id END,
     p_reservation_id, p_amount_minor, v_currency, COALESCE(p_method, v_method_key),
     'processing', 'recorded', v_is_legacy)
  ON CONFLICT (provider, provider_payment_id) DO NOTHING
  RETURNING id INTO v_receipt_id;

  IF v_receipt_id IS NULL THEN
    SELECT * INTO v_existing
    FROM payment_receipts
    WHERE provider = p_provider AND provider_payment_id = p_provider_payment_id;

    IF v_existing.reservation_id IS NOT DISTINCT FROM p_reservation_id
       AND v_existing.amount_minor = p_amount_minor
       AND v_existing.currency = v_currency THEN
      RETURN jsonb_build_object('result', 'already_processed',
                                'receipt_id', v_existing.id,
                                'prior_result', v_existing.result);
    END IF;

    INSERT INTO financial_audit_logs
      (entity_type, entity_id, action, actor_id, actor_role, amount, notes)
    VALUES ('payment', v_existing.reservation_id, 'payment_identity_conflict',
      NULL, 'system', p_amount_minor / 100.0,
      format('SEVERIDAD ALTA: payment_id %s/%s ya registrado (reserva=%s, %s %s, resultado=%s); llegó de nuevo con reserva=%s, %s %s. Se conserva el resultado original. Sin reembolso automático.',
        p_provider, p_provider_payment_id,
        v_existing.reservation_id, v_existing.amount_minor, v_existing.currency,
        v_existing.result,
        p_reservation_id, p_amount_minor, v_currency));

    INSERT INTO notifications (user_id, type, title, body, data)
    SELECT p.id, 'reservation', '🚨 Conflicto de identidad de pago',
      format('El pago %s llegó asociado a otra reserva o con datos distintos. Se conservó el registro original; NO se movió dinero. Revisa el panel financiero.',
        p_provider_payment_id),
      jsonb_build_object('screen', 'AdminFinancial',
                         'provider_payment_id', p_provider_payment_id,
                         'receipt_id', v_existing.id)
    FROM profiles p WHERE p.role = 'admin';

    RETURN jsonb_build_object('result', 'payment_identity_conflict',
                              'receipt_id', v_existing.id);
  END IF;

  v_result := NULL;
  v_reason := NULL;

  IF v_currency <> v_expected_cur THEN
    v_result := 'currency_mismatch';
    v_reason := format('moneda recibida %s ≠ esperada %s', v_currency, v_expected_cur);
  ELSIF p_amount_minor < v_expected_minor THEN
    v_result := 'amount_mismatch';
    v_reason := format('recibido %s < esperado %s (unidades menores)', p_amount_minor, v_expected_minor);
  ELSIF p_amount_minor > v_expected_minor THEN
    v_result := 'overpayment_refund_pending';
    v_reason := format('recibido %s > esperado %s (unidades menores) — política: bloqueo total', p_amount_minor, v_expected_minor);
  ELSIF v_res.status IN ('cancelled', 'rejected') THEN
    v_result := 'terminal_reservation';
    v_reason := format('reserva en estado terminal %s al llegar el pago', v_res.status);
  ELSIF v_res.payment_status IN ('paid', 'fully_paid') THEN
    v_result := 'payment_blocked_refund_pending';
    v_reason := format('reserva ya pagada (pago original %s); este cobro %s es duplicado y se devuelve íntegro',
      COALESCE(v_res.mp_payment_id, 's/ref'), p_provider_payment_id);
    v_block_paysts := FALSE;
  ELSIF v_res.status = 'expired' THEN
    v_window_h := COALESCE(
      (SELECT value::INT FROM payment_config
       WHERE key = 'late_window_hours_' || COALESCE(v_method_key, 'card')), 24);

    IF v_is_legacy OR v_attempt.created_at < NOW() - make_interval(hours => v_window_h) THEN
      v_result := 'late_payment_outside_window';
      v_reason := format('pago tardío fuera de la ventana de %s h para método %s', v_window_h, v_method_key);
    ELSE
      v_range := COALESCE(v_res.busy_range,
        public.make_busy_range(v_res.event_date, v_res.event_time,
          COALESCE(v_res.event_tz, 'America/Mexico_City'),
          v_res.hours_count,
          COALESCE((SELECT SUM(eh.hours_added) FROM extra_hours eh
                    WHERE eh.reservation_id = v_res.id), 0)::INT));
      v_sched := public.can_schedule(v_group_id, v_res.event_date, v_range, v_res.id);
      IF v_sched IS NOT NULL THEN
        v_result := 'payment_blocked_refund_pending';
        v_reason := format('disponibilidad perdida al revivir (%s)', v_sched);
      END IF;
    END IF;
  ELSE
    v_range := COALESCE(v_res.busy_range,
      public.make_busy_range(v_res.event_date, v_res.event_time,
        COALESCE(v_res.event_tz, 'America/Mexico_City'),
        v_res.hours_count,
        COALESCE((SELECT SUM(eh.hours_added) FROM extra_hours eh
                  WHERE eh.reservation_id = v_res.id), 0)::INT));
    v_sched := public.can_schedule(v_group_id, v_res.event_date, v_range, v_res.id);
    IF v_sched IS NOT NULL THEN
      v_result := 'payment_blocked_refund_pending';
      v_reason := format('disponibilidad perdida (%s)', v_sched);
    END IF;
  END IF;

  IF v_result IS NOT NULL THEN
    IF v_block_paysts THEN
      UPDATE reservations SET
        payment_status = 'paid_blocked',
        mp_payment_id  = p_provider_payment_id,
        updated_at     = NOW()
      WHERE id = p_reservation_id;
    END IF;

    UPDATE payment_receipts SET
      result              = v_result,
      money_state         = 'blocked_refund_pending',
      processor_fee_minor = p_fee_minor,
      processor_fee_status = CASE WHEN p_fee_minor IS NULL THEN 'not_captured' ELSE 'captured' END,
      fee_source          = CASE WHEN p_fee_minor IS NULL THEN NULL ELSE p_fee_source END,
      raw_meta            = jsonb_build_object('reason', v_reason),
      updated_at          = NOW()
    WHERE id = v_receipt_id;

    INSERT INTO refund_intents
      (provider, provider_payment_id, receipt_id, reservation_id, client_id,
       amount_minor, currency, refund_type, reason)
    VALUES
      (p_provider, p_provider_payment_id, v_receipt_id, p_reservation_id,
       v_res.client_id, p_amount_minor, v_currency, 'full', v_result)
    ON CONFLICT (provider, provider_payment_id) DO NOTHING;

    INSERT INTO financial_audit_logs
      (entity_type, entity_id, action, actor_id, actor_role, amount, notes)
    VALUES ('reservation', p_reservation_id, 'payment_blocked', NULL, 'system',
      p_amount_minor / 100.0,
      format('[%s] %s — pago=%s/%s. Dinero NO acreditado; reembolso íntegro en cola (refund_intents).',
        v_result, v_reason, p_provider, p_provider_payment_id));

    INSERT INTO notifications (user_id, type, title, body, data)
    SELECT p.id, 'reservation', '🚨 Pago bloqueado — requiere reembolso',
      format('Reserva %s: %s. El dinero quedó BLOQUEADO (no se acreditó al grupo). Procesa el reembolso desde el panel financiero.',
        COALESCE(v_res.folio, p_reservation_id::TEXT), v_reason),
      jsonb_build_object('screen', 'AdminFinancial', 'reservation_id', p_reservation_id)
    FROM profiles p WHERE p.role = 'admin';

    INSERT INTO notifications (user_id, type, title, body, data)
    VALUES (v_res.client_id, 'payment', 'Recibimos tu pago — será reembolsado',
      format('Tu pago de la reserva %s no pudo aplicarse (%s). Te devolveremos el monto completo; te avisaremos cuando el reembolso esté en camino.',
        COALESCE(v_res.folio, ''),
        CASE WHEN v_result IN ('amount_mismatch','overpayment_refund_pending','currency_mismatch')
             THEN 'el importe no coincidió con tu orden'
             ELSE 'la reserva ya no estaba disponible' END),
      jsonb_build_object('screen', 'Reservations', 'reservation_id', p_reservation_id));

    RETURN jsonb_build_object('result', v_result, 'receipt_id', v_receipt_id,
                              'reason', v_reason);
  END IF;

  v_earnings    := COALESCE(v_res.base_price, ROUND(v_res.total_price / 1.20, 2));
  v_service_fee := COALESCE(v_res.service_fee_amount,
                     v_res.total_price - ROUND(v_res.total_price / 1.20, 2));
  v_msi_fee     := COALESCE(v_res.msi_fee_amount, 0);
  v_admin_bruto := v_service_fee + v_msi_fee;
  v_fee_pesos   := CASE WHEN p_fee_minor IS NULL THEN NULL ELSE p_fee_minor / 100.0 END;

  PERFORM ensure_group_wallet(v_group_id);
  SELECT id INTO v_wallet_id FROM group_wallets WHERE group_id = v_group_id;

  -- [Ajuste aprobado 2026-07-20]: aunque este rollback restaura el
  -- comportamiento de sql/519, NO restaura el ELSE-como-MXN. CASE
  -- explícito: una moneda sin wallet (CAD u otra) lanza excepción y
  -- aborta — jamás se mezcla en MXN. (En este estado de emergencia un
  -- pago CAD daría 500/reintento y requeriría intervención manual.)
  CASE v_currency
    WHEN 'MXN' THEN
      UPDATE group_wallets SET
        pending_balance = pending_balance + v_earnings,
        total_earned    = total_earned    + v_earnings,
        updated_at      = NOW()
      WHERE id = v_wallet_id;
    WHEN 'USD' THEN
      UPDATE group_wallets SET
        pending_balance_usd = pending_balance_usd + v_earnings,
        total_earned_usd    = total_earned_usd    + v_earnings,
        updated_at          = NOW()
      WHERE id = v_wallet_id;
    ELSE
      RAISE EXCEPTION 'moneda % sin wallet autorizada — crédito prohibido', v_currency;
  END CASE;

  UPDATE reservations SET
    status              = CASE WHEN status IN ('pending','pending_payment',
                                               'pending_group_confirmation',
                                               'accepted','expired')
                               THEN 'confirmed' ELSE status END,
    payment_status      = 'paid',
    payout_status       = 'held',
    held_at             = NOW(),
    mp_payment_id       = p_provider_payment_id,
    payment_provider    = p_provider,
    payment_method_type = COALESCE(p_method, v_method_key, payment_method_type),
    stripe_fee_amount   = COALESCE(v_fee_pesos, stripe_fee_amount),
    service_fee_amount  = v_service_fee,
    group_earnings      = v_earnings,
    updated_at          = NOW()
  WHERE id = p_reservation_id;

  INSERT INTO wallet_transactions (
    group_wallet_id, group_id, type, amount,
    reservation_id, description, balance_after, currency_code
  )
  SELECT gw.id, gw.group_id, 'credit_pending', v_earnings,
    p_reservation_id,
    format('Pago confirmado — reserva %s', p_reservation_id),
    CASE WHEN v_currency = 'USD' THEN gw.pending_balance_usd ELSE gw.pending_balance END,
    v_currency
  FROM group_wallets gw WHERE gw.id = v_wallet_id;

  SELECT id INTO v_admin_id FROM profiles WHERE role = 'admin' ORDER BY created_at LIMIT 1;
  IF v_admin_id IS NOT NULL THEN
    INSERT INTO wallets (user_id, available_balance, pending_balance, total_earned)
    VALUES (v_admin_id, 0, 0, 0)
    ON CONFLICT (user_id) DO NOTHING;

    CASE v_currency
      WHEN 'MXN' THEN
        UPDATE wallets SET
          available_balance = available_balance + v_admin_bruto,
          total_earned      = COALESCE(total_earned, 0) + v_admin_bruto,
          updated_at        = NOW()
        WHERE user_id = v_admin_id;
      WHEN 'USD' THEN
        UPDATE wallets SET
          available_balance_usd = available_balance_usd + v_admin_bruto,
          total_earned_usd      = COALESCE(total_earned_usd, 0) + v_admin_bruto,
          updated_at            = NOW()
        WHERE user_id = v_admin_id;
      ELSE
        RAISE EXCEPTION 'moneda % sin wallet admin autorizada — crédito prohibido', v_currency;
    END CASE;

    INSERT INTO wallet_transactions (user_id, type, amount, reservation_id, description, currency_code)
    VALUES (v_admin_id, 'platform_income', v_admin_bruto, p_reservation_id,
      format('Comisión $%s + MSI $%s = $%s bruto — fee procesador: %s — reserva %s',
        v_service_fee::TEXT, v_msi_fee::TEXT, v_admin_bruto::TEXT,
        COALESCE('$' || v_fee_pesos::TEXT, 'No capturado'),
        p_reservation_id),
      v_currency);
  END IF;

  INSERT INTO financial_audit_logs
    (entity_type, entity_id, action, actor_id, actor_role, amount, notes)
  VALUES ('reservation', p_reservation_id, 'hold', NULL, 'system', v_earnings,
    format('v2 currency=%s group=%s svc=%s msi=%s fee=%s pago=%s/%s%s',
      v_currency, v_earnings, v_service_fee, v_msi_fee,
      COALESCE(v_fee_pesos::TEXT, 'not_captured'),
      p_provider, p_provider_payment_id,
      CASE WHEN v_res.status = 'expired' THEN ' [REVIVIDA dentro de ventana]' ELSE '' END));

  INSERT INTO notifications (user_id, type, title, body, data)
  SELECT g.owner_id, 'payment',
    '💰 Pago confirmado — retenido hasta el evento',
    format('El cliente pagó tu evento del %s. $%s %s quedaron reservados y se liberan cuando el grupo llegue y al terminar el evento.',
      v_res.event_date::TEXT, to_char(v_earnings, 'FM999,999,990'), v_currency),
    jsonb_build_object('reservation_id', p_reservation_id, 'amount', v_earnings, 'screen', 'Wallet')
  FROM groups g
  WHERE g.id = v_group_id AND g.owner_id IS NOT NULL;

  UPDATE payment_receipts SET
    result               = 'confirmed',
    money_state          = 'credited',
    processor_fee_minor  = p_fee_minor,
    processor_fee_status = CASE WHEN p_fee_minor IS NULL THEN 'not_captured' ELSE 'captured' END,
    fee_source           = CASE WHEN p_fee_minor IS NULL THEN NULL ELSE p_fee_source END,
    updated_at           = NOW()
  WHERE id = v_receipt_id;

  IF NOT v_is_legacy THEN
    UPDATE payment_attempts SET status = 'consumed', updated_at = NOW()
    WHERE id = v_attempt.id;
  END IF;

  RETURN jsonb_build_object(
    'result',         'confirmed',
    'receipt_id',     v_receipt_id,
    'currency',       v_currency,
    'group_earnings', v_earnings,
    'admin_bruto',    v_admin_bruto,
    'processor_fee',  v_fee_pesos,
    'revived',        (v_res.status = 'expired')
  );

EXCEPTION
  WHEN lock_not_available THEN
    RETURN jsonb_build_object('result', 'temporary_lock_timeout');
END;
$$;

REVOKE ALL ON FUNCTION public.confirm_reservation_payment_v2(
  TEXT, TEXT, TEXT, UUID, BIGINT, TEXT, TEXT, BIGINT, TEXT, JSONB)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.confirm_reservation_payment_v2(
  TEXT, TEXT, TEXT, UUID, BIGINT, TEXT, TEXT, BIGINT, TEXT, JSONB)
  TO service_role;

-- ── 4. Helper compartido y fórmula ───────────────────────────
DROP FUNCTION IF EXISTS public._apply_confirmed_credit(
  UUID,UUID,TEXT,TEXT,TEXT,BIGINT,TEXT,UUID,BOOLEAN,UUID,UUID,TEXT);
DROP FUNCTION IF EXISTS public.markup20_base_minor(BIGINT);

-- ── 5. Columnas añadidas por 521 ─────────────────────────────
ALTER TABLE payment_receipts DROP CONSTRAINT IF EXISTS chk_receipt_settlement;
ALTER TABLE payment_receipts DROP COLUMN IF EXISTS settlement_status;
ALTER TABLE payment_receipts DROP COLUMN IF EXISTS canonical_receipt_id;
ALTER TABLE payment_receipts DROP COLUMN IF EXISTS dismiss_reason_code;
ALTER TABLE payment_receipts DROP COLUMN IF EXISTS resolution_note;
ALTER TABLE payment_receipts DROP COLUMN IF EXISTS resolved_at;
ALTER TABLE payment_receipts DROP COLUMN IF EXISTS resolved_by;
ALTER TABLE payment_receipts DROP COLUMN IF EXISTS resolution;
ALTER TABLE payment_attempts DROP COLUMN IF EXISTS platform_fee_minor;
ALTER TABLE payment_attempts DROP COLUMN IF EXISTS group_base_minor;
ALTER TABLE refund_intents   DROP COLUMN IF EXISTS receipt_path;
ALTER TABLE refund_intents   DROP COLUMN IF EXISTS transfer_reference;
ALTER TABLE refund_intents   DROP COLUMN IF EXISTS claimed_at;
ALTER TABLE refund_intents   DROP COLUMN IF EXISTS claimed_by;
DELETE FROM payment_config WHERE key = 'refund_claim_timeout_minutes';

COMMIT;

SELECT '521_ROLLBACK ejecutado — resolución admin eliminada; gate restaurado al cuerpo exacto de sql/519' AS status;
