-- ============================================================
-- sql/521c_fix_audit_entity_id.sql — PARCHE de sql/521
--
-- BUG (reportado por el usuario en T14 de sql/522): resolve_payment_receipt
-- (rama dismiss) intentaba INSERT INTO financial_audit_logs con
-- entity_id = v_r.reservation_id, pero un receipt puede tener
-- reservation_id NULL (capture_missing sin metadata resoluble). Como
-- financial_audit_logs.entity_id es NOT NULL, la auditoría fallaba.
--
-- Investigando el mismo patrón se encontraron DOS instancias más del
-- MISMO bug, no reportadas pero de idéntica causa raíz:
--   1. resolve_payment_receipt, rama REFUND (línea ~1198 de sql/521):
--      mismo problema, mismo entity_id=reservation_id potencialmente NULL.
--   2. confirm_reservation_payment_v2 (el GATE), rama "reserva
--      inexistente": entity_id=NULL EXPLÍCITO — bug heredado sin cambios
--      desde sql/519, nunca ejercitado por ningún caso de sql/520 (ningún
--      test simulaba metadata apuntando a una reserva que no existe).
--
-- CORRECCIÓN (misma en los 3 puntos): entity_id NUNCA nulo — se ancla al
-- RECEIPT (payment_receipts.id, que siempre existe en estas ramas) cuando
-- no hay reserva disponible, con entity_type='payment_receipt'. Cuando sí
-- hay reserva, se conserva el comportamiento original (entity_type
-- 'payment'/'reservation', entity_id=reservation_id).
--
-- QUÉ HACE: CREATE OR REPLACE de las DOS funciones afectadas —
-- confirm_reservation_payment_v2 y resolve_payment_receipt. Firmas
-- IDÉNTICAS a sql/521; ningún otro objeto se toca. No requiere re-correr
-- sql/521 completo. Tras aplicar: re-correr sql/520 (21/21) y sql/522.
-- ============================================================

BEGIN;

-- ────────────────────────────────────────────────────────────
-- 1/2: confirm_reservation_payment_v2 — fix en rama "reserva inexistente"
-- ────────────────────────────────────────────────────────────
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
  v_apply          JSONB;
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

  -- ── A. Resolver el importe esperado (captura inmutable) ──────────
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

      -- v_attempt.reservation_id es NOT NULL por esquema (payment_attempts) —
      -- esta rama nunca necesitó el fix.
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

  -- ── B. ORDEN DE LOCKS ────────────────────────────────────────────
  SELECT group_id INTO v_group_id FROM reservations WHERE id = p_reservation_id;
  IF NOT FOUND THEN
    -- [FIX] entity_id=NULL (bug heredado de sql/519) → ancla al RECEIPT.
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
    ON CONFLICT (provider, provider_payment_id) DO NOTHING
    RETURNING id INTO v_receipt_id;

    IF v_receipt_id IS NULL THEN
      SELECT id INTO v_receipt_id FROM payment_receipts
      WHERE provider = p_provider AND provider_payment_id = p_provider_payment_id;
    END IF;

    INSERT INTO financial_audit_logs
      (entity_type, entity_id, action, actor_id, actor_role, amount, notes)
    VALUES ('payment_receipt', v_receipt_id, 'payment_identity_conflict', NULL, 'system',
      p_amount_minor / 100.0,
      format('SEVERIDAD ALTA: pago %s/%s con metadata de reserva inexistente %s (receipt=%s). Sin reembolso automático.',
        p_provider, p_provider_payment_id, p_reservation_id, v_receipt_id));

    INSERT INTO notifications (user_id, type, title, body, data)
    SELECT p.id, 'reservation', '🚨 Conflicto de identidad de pago',
      format('El pago %s apunta a una reserva inexistente. Revisa el panel financiero.', p_provider_payment_id),
      jsonb_build_object('screen', 'AdminFinancial')
    FROM profiles p WHERE p.role = 'admin';

    RETURN jsonb_build_object('result', 'payment_identity_conflict', 'receipt_id', v_receipt_id);
  END IF;

  PERFORM pg_advisory_xact_lock(hashtext(v_group_id::text));

  SELECT * INTO v_res FROM reservations WHERE id = p_reservation_id FOR UPDATE;

  IF v_res.group_id IS DISTINCT FROM v_group_id THEN
    RETURN jsonb_build_object('result', 'temporary_retry');
  END IF;

  -- ── C. Idempotencia: reclamar el pago ────────────────────────────
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

  -- ── D. Cascada de decisión ───────────────────────────────────────
  v_result := NULL;
  v_reason := NULL;

  -- D0. [521] Moneda sin wallet autorizada: CAD se bloquea ÍNTEGRO.
  --     Prohibido el ELSE-como-MXN: sin ledger CAD no hay crédito.
  IF v_currency = 'CAD' THEN
    v_result := 'currency_unsupported_wallet';
    v_reason := 'moneda CAD sin wallet/ledger autorizado — bloqueo íntegro y reembolso';

  -- D1. Moneda vs esperada
  ELSIF v_currency <> v_expected_cur THEN
    v_result := 'currency_mismatch';
    v_reason := format('moneda recibida %s ≠ esperada %s', v_currency, v_expected_cur);

  -- D2. Importe exacto en unidades menores, tolerancia CERO
  ELSIF p_amount_minor < v_expected_minor THEN
    v_result := 'amount_mismatch';
    v_reason := format('recibido %s < esperado %s (unidades menores)', p_amount_minor, v_expected_minor);
  ELSIF p_amount_minor > v_expected_minor THEN
    v_result := 'overpayment_refund_pending';
    v_reason := format('recibido %s > esperado %s (unidades menores) — política: bloqueo total', p_amount_minor, v_expected_minor);

  -- D3. Reserva terminal
  ELSIF v_res.status IN ('cancelled', 'rejected') THEN
    v_result := 'terminal_reservation';
    v_reason := format('reserva en estado terminal %s al llegar el pago', v_res.status);

  -- D4. Reserva ya pagada con OTRO payment_id (cobro duplicado)
  ELSIF v_res.payment_status IN ('paid', 'fully_paid') THEN
    v_result := 'payment_blocked_refund_pending';
    v_reason := format('reserva ya pagada (pago original %s); este cobro %s es duplicado y se devuelve íntegro',
      COALESCE(v_res.mp_payment_id, 's/ref'), p_provider_payment_id);
    v_block_paysts := FALSE;

  -- D5. Expirada: ¿revive?
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

  -- D6. Estados vivos no pagados → validación preventiva
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

  -- ── E. RAMA BLOQUEADA: paid_blocked + reembolso íntegro en cola ──
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
      settlement_status   = 'refund_pending',
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
        CASE WHEN v_result IN ('amount_mismatch','overpayment_refund_pending',
                               'currency_mismatch','currency_unsupported_wallet')
             THEN 'el importe o la moneda no coincidieron con tu orden'
             ELSE 'la reserva ya no estaba disponible' END),
      jsonb_build_object('screen', 'Reservations', 'reservation_id', p_reservation_id));

    RETURN jsonb_build_object('result', v_result, 'receipt_id', v_receipt_id,
                              'reason', v_reason);
  END IF;

  -- ── F. CONFIRMAR + ACREDITAR — delegado al helper compartido [521] ─
  v_apply := public._apply_confirmed_credit(
    v_receipt_id, p_reservation_id, p_provider, p_provider_payment_id,
    COALESCE(p_method, v_method_key), p_fee_minor, p_fee_source,
    CASE WHEN v_is_legacy THEN NULL ELSE v_attempt.id END,
    FALSE, NULL, NULL, NULL);

  RETURN jsonb_build_object('result', 'confirmed', 'receipt_id', v_receipt_id)
         || v_apply;

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

-- ────────────────────────────────────────────────────────────
-- 2/2: resolve_payment_receipt — fix en ramas refund y dismiss
-- ────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.resolve_payment_receipt(
  p_receipt_id          UUID,
  p_action              TEXT,
  p_note                TEXT,
  p_confirm             TEXT,
  p_reservation_id      UUID    DEFAULT NULL,
  p_reservation_confirm UUID    DEFAULT NULL,
  p_amount_confirm      BIGINT  DEFAULT NULL,
  p_currency_confirm    TEXT    DEFAULT NULL,
  p_dismiss_reason      TEXT    DEFAULT NULL,
  p_canonical_receipt_id UUID   DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_r        RECORD;
  v_ev       RECORD;
  v_res      RECORD;
  v_group_id UUID;
  v_range    TSTZRANGE;
  v_sched    TEXT;
  v_apply    JSONB;
  v_canon    RECORD;
BEGIN
  PERFORM set_config('lock_timeout', '5000', TRUE);

  IF NOT EXISTS (SELECT 1 FROM profiles WHERE id = auth.uid() AND role = 'admin') THEN
    RETURN jsonb_build_object('ok', false, 'result', 'not_admin');
  END IF;
  IF p_action NOT IN ('credit','refund','dismiss') THEN
    RETURN jsonb_build_object('ok', false, 'result', 'invalid_action');
  END IF;
  IF COALESCE(TRIM(p_note), '') = '' THEN
    RETURN jsonb_build_object('ok', false, 'result', 'note_required');
  END IF;

  SELECT * INTO v_r FROM payment_receipts WHERE id = p_receipt_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'result', 'receipt_not_found');
  END IF;

  IF p_confirm IS DISTINCT FROM v_r.provider_payment_id THEN
    RETURN jsonb_build_object('ok', false, 'result', 'confirm_mismatch');
  END IF;

  IF v_r.money_state <> 'recorded'
     OR v_r.result NOT IN ('capture_missing','payment_identity_conflict') THEN
    RETURN jsonb_build_object('ok', false, 'result', 'not_resolvable_state',
      'money_state', v_r.money_state, 'receipt_result', v_r.result);
  END IF;

  -- ══ CREDIT ═══════════════════════════════════════════════════════
  IF p_action = 'credit' THEN
    SELECT * INTO v_ev FROM admin_payment_evidence
    WHERE provider = v_r.provider AND provider_payment_id = v_r.provider_payment_id
    ORDER BY version DESC LIMIT 1;
    IF NOT FOUND THEN
      RETURN jsonb_build_object('ok', false, 'result', 'evidence_required');
    END IF;
    IF NOT v_ev.captured OR v_ev.group_base_minor IS NULL THEN
      RETURN jsonb_build_object('ok', false, 'result', 'evidence_required',
        'detail', 'evidencia sin captura confirmada o sin desglose contractual verificable — solo refund/dismiss');
    END IF;

    IF p_reservation_id IS NULL
       OR v_ev.reservation_id IS DISTINCT FROM p_reservation_id
       OR p_reservation_confirm IS DISTINCT FROM p_reservation_id THEN
      RETURN jsonb_build_object('ok', false, 'result', 'confirm_mismatch',
        'detail', 'reservation_id explícito debe igualar la evidencia y su confirmación');
    END IF;
    IF p_amount_confirm IS DISTINCT FROM v_r.amount_minor
       OR UPPER(COALESCE(p_currency_confirm,'')) IS DISTINCT FROM v_r.currency THEN
      RETURN jsonb_build_object('ok', false, 'result', 'confirm_mismatch',
        'detail', 'monto/moneda confirmados no coinciden con el receipt');
    END IF;

    IF v_r.amount_minor <> v_ev.amount_minor OR v_r.currency <> v_ev.currency THEN
      RETURN jsonb_build_object('ok', false, 'result', 'amount_mismatch_manual',
        'receipt_minor', v_r.amount_minor, 'evidence_minor', v_ev.amount_minor);
    END IF;
    IF v_r.currency = 'CAD' THEN
      RETURN jsonb_build_object('ok', false, 'result', 'currency_unsupported_wallet');
    END IF;

    IF EXISTS (SELECT 1 FROM reservations r2
               WHERE r2.mp_payment_id = v_r.provider_payment_id
                 AND r2.payment_status IN ('paid','fully_paid')
                 AND r2.id <> p_reservation_id) THEN
      INSERT INTO financial_audit_logs
        (entity_type, entity_id, action, actor_id, actor_role, amount, notes)
      VALUES ('payment', p_reservation_id, 'already_credited_elsewhere',
        auth.uid(), 'admin', v_r.amount_minor / 100.0,
        format('SEVERIDAD ALTA: intento de crédito manual de %s/%s pero ya está acreditado en otra reserva.',
          v_r.provider, v_r.provider_payment_id));
      RETURN jsonb_build_object('ok', false, 'result', 'already_credited_elsewhere');
    END IF;

    SELECT group_id INTO v_group_id FROM reservations WHERE id = p_reservation_id;
    IF v_group_id IS NULL THEN
      RETURN jsonb_build_object('ok', false, 'result', 'reservation_missing');
    END IF;
    PERFORM pg_advisory_xact_lock(hashtext(v_group_id::text));
    SELECT * INTO v_res FROM reservations WHERE id = p_reservation_id FOR UPDATE;
    IF v_res.status IN ('cancelled','rejected') THEN
      RETURN jsonb_build_object('ok', false, 'result', 'reservation_terminal');
    END IF;
    IF v_res.payment_status IN ('paid','fully_paid') THEN
      RETURN jsonb_build_object('ok', false, 'result', 'reservation_already_paid');
    END IF;

    SELECT * INTO v_r FROM payment_receipts WHERE id = p_receipt_id FOR UPDATE;
    IF v_r.resolution IS NOT NULL OR v_r.money_state <> 'recorded' THEN
      RETURN jsonb_build_object('ok', false, 'result', 'already_resolved',
        'resolution', v_r.resolution, 'settlement', v_r.settlement_status);
    END IF;

    v_range := COALESCE(v_res.busy_range,
      public.make_busy_range(v_res.event_date, v_res.event_time,
        COALESCE(v_res.event_tz, 'America/Mexico_City'),
        v_res.hours_count,
        COALESCE((SELECT SUM(eh.hours_added) FROM extra_hours eh
                  WHERE eh.reservation_id = v_res.id), 0)::INT));
    v_sched := public.can_schedule(v_group_id, v_res.event_date, v_range, v_res.id);
    IF v_sched IS NOT NULL THEN
      RETURN jsonb_build_object('ok', false, 'result', 'availability_lost',
        'reason', v_sched);
    END IF;

    v_apply := public._apply_confirmed_credit(
      p_receipt_id, p_reservation_id, v_r.provider, v_r.provider_payment_id,
      v_r.method, v_r.processor_fee_minor, v_r.fee_source,
      NULL, TRUE, auth.uid(), v_ev.id, p_note);

    -- p_reservation_id es NOT NULL aquí por validación previa — no
    -- necesitaba el fix, pero se conserva idéntico por consistencia.
    INSERT INTO financial_audit_logs
      (entity_type, entity_id, action, actor_id, actor_role, amount, notes)
    VALUES ('payment', p_reservation_id, 'manual_credit', auth.uid(), 'admin',
      v_r.amount_minor / 100.0,
      format('Crédito manual %s/%s → reserva %s con evidencia %s (v%s, sha=%s). Vínculo previo del receipt: %s. Nota: %s',
        v_r.provider, v_r.provider_payment_id, p_reservation_id,
        v_ev.id, v_ev.version, v_ev.snapshot_sha256,
        COALESCE(v_r.reservation_id::text, 'NULL'), p_note));

    RETURN jsonb_build_object('ok', true, 'result', 'credited') || v_apply;
  END IF;

  -- ══ REFUND ═══════════════════════════════════════════════════════
  IF p_action = 'refund' THEN
    SELECT * INTO v_r FROM payment_receipts WHERE id = p_receipt_id FOR UPDATE;
    IF v_r.resolution IS NOT NULL OR v_r.money_state <> 'recorded' THEN
      RETURN jsonb_build_object('ok', false, 'result', 'already_resolved',
        'resolution', v_r.resolution);
    END IF;

    INSERT INTO refund_intents
      (provider, provider_payment_id, receipt_id, reservation_id, client_id,
       amount_minor, currency, refund_type, reason)
    VALUES
      (v_r.provider, v_r.provider_payment_id, v_r.id, v_r.reservation_id,
       (SELECT client_id FROM reservations WHERE id = v_r.reservation_id),
       v_r.amount_minor, v_r.currency, 'full', 'manual_resolution')
    ON CONFLICT (provider, provider_payment_id) DO NOTHING;
    IF NOT FOUND THEN
      RETURN jsonb_build_object('ok', false, 'result', 'already_refund_queued');
    END IF;

    UPDATE payment_receipts SET
      money_state       = 'blocked_refund_pending',
      settlement_status = 'refund_pending',
      resolution        = 'refund_queued',
      resolved_by       = auth.uid(),
      resolved_at       = NOW(),
      resolution_note   = p_note,
      updated_at        = NOW()
    WHERE id = p_receipt_id;

    -- [FIX] entity_id nunca nulo: ancla al RECEIPT si no hay reserva.
    INSERT INTO financial_audit_logs
      (entity_type, entity_id, action, actor_id, actor_role, amount, notes)
    VALUES (
      CASE WHEN v_r.reservation_id IS NOT NULL THEN 'payment' ELSE 'payment_receipt' END,
      COALESCE(v_r.reservation_id, v_r.id),
      'manual_refund_queued', auth.uid(), 'admin',
      v_r.amount_minor / 100.0,
      format('Reembolso manual en cola: %s/%s (receipt=%s, reserva=%s). Nota: %s',
        v_r.provider, v_r.provider_payment_id, v_r.id,
        COALESCE(v_r.reservation_id::text, 'sin reserva'), p_note));

    RETURN jsonb_build_object('ok', true, 'result', 'refund_queued');
  END IF;

  -- ══ DISMISS (estrictamente restringido) ══════════════════════════
  IF p_dismiss_reason NOT IN
     ('test_event','duplicate_of_canonical','provider_no_capture','garbage_no_money') THEN
    RETURN jsonb_build_object('ok', false, 'result', 'invalid_action',
      'detail', 'dismiss_reason_code inválido');
  END IF;

  SELECT * INTO v_ev FROM admin_payment_evidence
  WHERE provider = v_r.provider AND provider_payment_id = v_r.provider_payment_id
  ORDER BY version DESC LIMIT 1;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'result', 'evidence_required');
  END IF;

  IF p_dismiss_reason = 'duplicate_of_canonical' THEN
    IF p_canonical_receipt_id IS NULL THEN
      RETURN jsonb_build_object('ok', false, 'result', 'invalid_action',
        'detail', 'canonical_receipt_id obligatorio para duplicados');
    END IF;
    SELECT * INTO v_canon FROM payment_receipts WHERE id = p_canonical_receipt_id;
    IF NOT FOUND OR v_canon.settlement_status NOT IN ('credited','refund_completed') THEN
      RETURN jsonb_build_object('ok', false, 'result', 'invalid_action',
        'detail', 'el receipt canónico debe existir y estar conciliado (credited/refund_completed)');
    END IF;
  ELSE
    IF v_ev.captured THEN
      RETURN jsonb_build_object('ok', false, 'result', 'captured_money_cannot_be_dismissed');
    END IF;
  END IF;

  SELECT * INTO v_r FROM payment_receipts WHERE id = p_receipt_id FOR UPDATE;
  IF v_r.resolution IS NOT NULL OR v_r.money_state <> 'recorded' THEN
    RETURN jsonb_build_object('ok', false, 'result', 'already_resolved',
      'resolution', v_r.resolution);
  END IF;

  UPDATE payment_receipts SET
    resolution           = 'dismissed',
    dismiss_reason_code  = p_dismiss_reason,
    canonical_receipt_id = p_canonical_receipt_id,
    settlement_status    = CASE WHEN p_dismiss_reason = 'duplicate_of_canonical'
                                THEN 'duplicate_linked' ELSE 'no_capture_verified' END,
    resolved_by          = auth.uid(),
    resolved_at          = NOW(),
    resolution_note      = p_note,
    updated_at           = NOW()
  WHERE id = p_receipt_id;

  -- [FIX] entity_id nunca nulo (bug reportado en T14): ancla al RECEIPT
  -- si no hay reserva.
  INSERT INTO financial_audit_logs
    (entity_type, entity_id, action, actor_id, actor_role, amount, notes)
  VALUES (
    CASE WHEN v_r.reservation_id IS NOT NULL THEN 'payment' ELSE 'payment_receipt' END,
    COALESCE(v_r.reservation_id, v_r.id),
    'receipt_dismissed', auth.uid(), 'admin',
    v_r.amount_minor / 100.0,
    format('Dismiss %s/%s (receipt=%s, reserva=%s) motivo=%s canonico=%s evidencia=%s(v%s). Nota: %s',
      v_r.provider, v_r.provider_payment_id, v_r.id,
      COALESCE(v_r.reservation_id::text, 'sin reserva'), p_dismiss_reason,
      COALESCE(p_canonical_receipt_id::text,'—'), v_ev.id, v_ev.version, p_note));

  RETURN jsonb_build_object('ok', true, 'result', 'dismissed',
    'settlement', CASE WHEN p_dismiss_reason = 'duplicate_of_canonical'
                       THEN 'duplicate_linked' ELSE 'no_capture_verified' END);

EXCEPTION
  WHEN lock_not_available THEN
    RETURN jsonb_build_object('ok', false, 'result', 'lock_timeout_retry');
END;
$$;

REVOKE ALL ON FUNCTION public.resolve_payment_receipt(
  UUID,TEXT,TEXT,TEXT,UUID,UUID,BIGINT,TEXT,TEXT,UUID) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.resolve_payment_receipt(
  UUID,TEXT,TEXT,TEXT,UUID,UUID,BIGINT,TEXT,TEXT,UUID) TO authenticated, service_role;

COMMIT;

-- ── VERIFICACIÓN ──────────────────────────────────────────────
SELECT
  (SELECT COUNT(*) FROM pg_proc WHERE proname IN
    ('confirm_reservation_payment_v2','resolve_payment_receipt'))       AS funcs_2,
  (SELECT prosrc LIKE '%entity_type''payment_receipt''%'
          OR prosrc LIKE '%''payment_receipt''%'
   FROM pg_proc WHERE proname = 'resolve_payment_receipt')              AS fix_presente_resolve,
  (SELECT prosrc LIKE '%''payment_receipt''%'
   FROM pg_proc WHERE proname = 'confirm_reservation_payment_v2')       AS fix_presente_gate;
-- Esperado: 2 · true · true

SELECT '521c_fix_audit_entity_id.sql ejecutado ✅ — re-correr sql/520 (21/21) y luego sql/522' AS status;
