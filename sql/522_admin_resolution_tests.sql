-- ============================================================
-- sql/522_admin_resolution_tests.sql — PRUEBAS DE sql/521 (NO persiste NADA)
--
-- ⚠️ EN REVISIÓN: NO PEGAR hasta autorización.
-- Requiere: sql/521 aplicado + sql/520 re-corrido con 21/21.
--
-- Patrón 515/520: un DO-block que SIEMPRE termina en RAISE EXCEPTION
-- con el reporte → rollback total garantizado (datos, wallets, evidencia,
-- constraint temporal de T19, y el JWT simulado).
--
-- Truco de sesión: las RPCs de 521 exigen auth.uid()=admin; el editor no
-- tiene JWT → se simula con set_config('request.jwt.claims', ...) LOCAL
-- usando el id del admin REAL (se revierte con todo lo demás).
--
-- ⚠️ T19 toma un lock breve sobre wallet_transactions — correr en
-- momento de bajo tráfico (~1-2 s total).
-- ============================================================

DO $$
DECLARE
  v_admin    UUID;
  v_user     UUID;
  v_group    UUID;
  v_r1 UUID; v_r2 UUID; v_r3 UUID; v_rusd UUID; v_rcad UUID; v_r19 UUID;
  v_rc1 UUID; v_rc2 UUID; v_rc3 UUID; v_rc4 UUID; v_rcu UUID; v_rc19 UUID;
  v_ev1 UUID; v_evd UUID; v_evnc UUID;
  v_int UUID;
  v_json JSONB;
  v_bal_mxn NUMERIC; v_bal_usd NUMERIC;
  v_adm_mxn NUMERIC; v_adm_usd NUMERIC;
  v_n INT;
  v_txt TEXT;
  v_report TEXT := E'\n══════ REPORTE DE PRUEBAS 522 (resolución admin) ══════\n';
BEGIN
  -- ─────────────────── SETUP ───────────────────
  SELECT id INTO v_admin FROM profiles WHERE role = 'admin' ORDER BY created_at LIMIT 1;
  IF v_admin IS NULL THEN
    RAISE EXCEPTION 'ABORTADO: no hay perfil admin — imposible probar RPCs admin';
  END IF;
  -- Simular JWT del admin (LOCAL: muere con el rollback)
  PERFORM set_config('request.jwt.claims',
    json_build_object('sub', v_admin, 'role', 'authenticated')::text, TRUE);

  SELECT id INTO v_user FROM profiles LIMIT 1;
  INSERT INTO groups (name, owner_id, state, country, is_active)
  VALUES ('__TEST_521__', v_user, 'Jalisco', 'México', false)
  RETURNING id INTO v_group;
  PERFORM ensure_group_wallet(v_group);

  SELECT COALESCE(available_balance,0), COALESCE(available_balance_usd,0)
    INTO v_adm_mxn, v_adm_usd FROM wallets WHERE user_id = v_admin;
  v_adm_mxn := COALESCE(v_adm_mxn,0); v_adm_usd := COALESCE(v_adm_usd,0);

  -- Reservas (fechas 2032-01-XX, una por reserva ocupante; 1200/1000)
  INSERT INTO reservations (group_id, client_id, event_date, event_time, hours_count, status, payment_status, total_price, base_price, address)
  VALUES (v_group, v_user, DATE '2032-01-01', TIME '18:00', 3, 'pending_payment', 'unpaid', 1200, 1000, 'Av. Prueba 521')
  RETURNING id INTO v_r1;
  INSERT INTO reservations (group_id, client_id, event_date, event_time, hours_count, status, payment_status, total_price, base_price, address)
  VALUES (v_group, v_user, DATE '2032-01-02', TIME '18:00', 3, 'pending_payment', 'unpaid', 1200, 1000, 'Av. Prueba 521')
  RETURNING id INTO v_r2;
  INSERT INTO reservations (group_id, client_id, event_date, event_time, hours_count, status, payment_status, total_price, base_price, address)
  VALUES (v_group, v_user, DATE '2032-01-03', TIME '18:00', 3, 'pending_payment', 'unpaid', 1200, 1000, 'Av. Prueba 521')
  RETURNING id INTO v_r3;
  INSERT INTO reservations (group_id, client_id, event_date, event_time, hours_count, status, payment_status, total_price, base_price, address)
  VALUES (v_group, v_user, DATE '2032-01-04', TIME '18:00', 3, 'pending_payment', 'unpaid', 1200, 1000, 'Av. Prueba 521')
  RETURNING id INTO v_rusd;
  UPDATE reservations SET currency_code = 'USD' WHERE id = v_rusd;
  INSERT INTO reservations (group_id, client_id, event_date, event_time, hours_count, status, payment_status, total_price, base_price, address)
  VALUES (v_group, v_user, DATE '2032-01-05', TIME '18:00', 3, 'pending_payment', 'unpaid', 1200, 1000, 'Av. Prueba 521')
  RETURNING id INTO v_rcad;
  UPDATE reservations SET currency_code = 'CAD' WHERE id = v_rcad;
  INSERT INTO reservations (group_id, client_id, event_date, event_time, hours_count, status, payment_status, total_price, base_price, address)
  VALUES (v_group, v_user, DATE '2032-01-06', TIME '18:00', 3, 'pending_payment', 'unpaid', 1200, 1000, 'Av. Prueba 521')
  RETURNING id INTO v_r19;

  -- Receipts en estado ambiguo (dinero registrado sin destino)
  INSERT INTO payment_receipts (provider, provider_payment_id, provider_order_id, reservation_id, amount_minor, currency, method, result, money_state)
  VALUES ('stripe','ch_521_a','ord_521_a', v_r1, 120000,'MXN','card','capture_missing','recorded')
  RETURNING id INTO v_rc1;
  INSERT INTO payment_receipts (provider, provider_payment_id, provider_order_id, reservation_id, amount_minor, currency, method, result, money_state)
  VALUES ('stripe','ch_521_b','ord_521_b', v_r2, 120000,'MXN','card','payment_identity_conflict','recorded')
  RETURNING id INTO v_rc2;
  INSERT INTO payment_receipts (provider, provider_payment_id, provider_order_id, reservation_id, amount_minor, currency, method, result, money_state)
  VALUES ('conekta','ch_521_c','ord_521_c', v_r3, 120000,'MXN','card','capture_missing','recorded')
  RETURNING id INTO v_rc3;
  INSERT INTO payment_receipts (provider, provider_payment_id, provider_order_id, reservation_id, amount_minor, currency, method, result, money_state)
  VALUES ('conekta','ch_521_d','ord_521_d', NULL, 50000,'MXN','card','capture_missing','recorded')
  RETURNING id INTO v_rc4;
  INSERT INTO payment_receipts (provider, provider_payment_id, provider_order_id, reservation_id, amount_minor, currency, method, result, money_state)
  VALUES ('stripe','ch_521_usd','ord_521_usd', v_rusd, 120000,'USD','card','capture_missing','recorded')
  RETURNING id INTO v_rcu;
  INSERT INTO payment_receipts (provider, provider_payment_id, provider_order_id, reservation_id, amount_minor, currency, method, result, money_state)
  VALUES ('stripe','ch_521_t19','ord_521_t19', v_r19, 120000,'MXN','card','capture_missing','recorded')
  RETURNING id INTO v_rc19;

  ---------------------------------------------------------------
  -- T1: evidencia con desglose FABRICADO (base fuera de fórmula)
  ---------------------------------------------------------------
  v_json := public.register_payment_evidence(
    'stripe','ch_521_a','ord_521_a', v_r1, TRUE, 120000,'MXN',0,0,
    99999, 20001,  -- base inventada (correcta: 100000)
    NOW(), '{"src":"test"}'::jsonb, '{"total":"stripe.pi.amount"}'::jsonb,
    NULL, NULL, 'prueba fabricación', NULL);
  IF v_json->>'error' = 'composition_not_contractual'
     AND (v_json->>'expected_base_minor')::BIGINT = 100000 THEN
    v_report := v_report || 'T1  desglose fabricado → composition_not_contractual ........ PASS' || E'\n';
  ELSE
    v_report := v_report || 'T1  desglose fabricado .............................. FAIL ' || v_json::text || E'\n';
  END IF;

  ---------------------------------------------------------------
  -- T2: componentes que NO suman el total
  ---------------------------------------------------------------
  v_json := public.register_payment_evidence(
    'stripe','ch_521_a','ord_521_a', v_r1, TRUE, 120000,'MXN',0,0,
    100000, 19000,  -- suma 119000 ≠ 120000
    NOW(), '{"src":"test"}'::jsonb, '{"total":"stripe.pi.amount"}'::jsonb,
    NULL, NULL, 'prueba suma', NULL);
  IF v_json->>'error' = 'composition_sum_mismatch' THEN
    v_report := v_report || 'T2  componentes no suman → composition_sum_mismatch ......... PASS' || E'\n';
  ELSE
    v_report := v_report || 'T2  suma .................................................... FAIL ' || v_json::text || E'\n';
  END IF;

  ---------------------------------------------------------------
  -- T3: evidencia VÁLIDA + hash server-side verificable
  ---------------------------------------------------------------
  v_json := public.register_payment_evidence(
    'stripe','ch_521_a','ord_521_a', v_r1, TRUE, 120000,'MXN',0,0,
    100000, 20000, NOW(),
    jsonb_build_object('amount',120000,'currency','mxn','status','succeeded'),
    jsonb_build_object('total','stripe.pi.amount','currency','stripe.pi.currency'),
    NULL, NULL, 'evidencia válida ch_521_a', NULL);
  v_ev1 := (v_json->>'evidence_id')::UUID;
  IF (v_json->>'ok')::BOOLEAN AND length(v_json->>'snapshot_sha256') = 64 THEN
    v_report := v_report || 'T3  evidencia válida registrada + sha256 server-side ......... PASS' || E'\n';
  ELSE
    v_report := v_report || 'T3  evidencia válida ................................ FAIL ' || v_json::text || E'\n';
  END IF;

  ---------------------------------------------------------------
  -- T4/T5: UPDATE y DELETE de evidencia → trigger inmutable
  ---------------------------------------------------------------
  BEGIN
    UPDATE admin_payment_evidence SET note = 'hackeo' WHERE id = v_ev1;
    v_report := v_report || 'T4  UPDATE evidencia ................................ FAIL (dejó pasar)' || E'\n';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM LIKE '%evidence_immutable%' THEN
      v_report := v_report || 'T4  UPDATE evidencia → evidence_immutable .................... PASS' || E'\n';
    ELSE
      v_report := v_report || 'T4  UPDATE evidencia: error inesperado .............. FAIL ' || SQLERRM || E'\n';
    END IF;
  END;
  BEGIN
    DELETE FROM admin_payment_evidence WHERE id = v_ev1;
    v_report := v_report || 'T5  DELETE evidencia ................................ FAIL (dejó pasar)' || E'\n';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM LIKE '%evidence_immutable%' THEN
      v_report := v_report || 'T5  DELETE evidencia → evidence_immutable .................... PASS' || E'\n';
    ELSE
      v_report := v_report || 'T5  DELETE evidencia: error inesperado .............. FAIL ' || SQLERRM || E'\n';
    END IF;
  END;

  ---------------------------------------------------------------
  -- T6: credit SIN evidencia → evidence_required
  ---------------------------------------------------------------
  v_json := public.resolve_payment_receipt(
    v_rc3, 'credit', 'sin evidencia', 'ch_521_c',
    v_r3, v_r3, 120000, 'MXN', NULL, NULL);
  IF v_json->>'result' = 'evidence_required' THEN
    v_report := v_report || 'T6  credit sin evidencia → evidence_required ................. PASS' || E'\n';
  ELSE
    v_report := v_report || 'T6  credit sin evidencia ............................ FAIL ' || v_json::text || E'\n';
  END IF;

  ---------------------------------------------------------------
  -- T7: doble confirmación fallida → confirm_mismatch (sin efectos)
  ---------------------------------------------------------------
  v_json := public.resolve_payment_receipt(
    v_rc1, 'credit', 'confirm malo', 'ch_521_a',
    v_r1, v_r1, 119999, 'MXN', NULL, NULL);   -- monto confirmado incorrecto
  IF v_json->>'result' = 'confirm_mismatch'
     AND (SELECT payment_status FROM reservations WHERE id = v_r1) = 'unpaid' THEN
    v_report := v_report || 'T7  monto confirmado erróneo → confirm_mismatch, 0 efectos ... PASS' || E'\n';
  ELSE
    v_report := v_report || 'T7  confirm mismatch ................................ FAIL ' || v_json::text || E'\n';
  END IF;

  ---------------------------------------------------------------
  -- T8: CREDIT feliz (MXN) — evidencia + cuádruple confirmación
  ---------------------------------------------------------------
  SELECT pending_balance, COALESCE(pending_balance_usd,0) INTO v_bal_mxn, v_bal_usd
  FROM group_wallets WHERE group_id = v_group;
  v_json := public.resolve_payment_receipt(
    v_rc1, 'credit', 'verificado en dashboard Stripe', 'ch_521_a',
    v_r1, v_r1, 120000, 'MXN', NULL, NULL);
  IF v_json->>'result' = 'credited'
     AND (SELECT status||'/'||payment_status||'/'||payout_status
          FROM reservations WHERE id=v_r1) = 'confirmed/paid/held'
     AND (SELECT settlement_status||'/'||resolution FROM payment_receipts WHERE id=v_rc1)
         = 'credited/credited_manual'
     AND (SELECT pending_balance FROM group_wallets WHERE group_id=v_group) = v_bal_mxn + 1000
     AND (SELECT COALESCE(pending_balance_usd,0) FROM group_wallets WHERE group_id=v_group) = v_bal_usd
     AND (SELECT COUNT(*) FROM financial_audit_logs
          WHERE action='manual_credit' AND entity_id=v_r1) = 1 THEN
    v_report := v_report || 'T8  CREDIT manual MXN → +1000 grupo, USD intacto, auditado ... PASS' || E'\n';
  ELSE
    v_report := v_report || 'T8  credit MXN ...................................... FAIL ' || v_json::text || E'\n';
  END IF;
  SELECT COALESCE(available_balance,0) INTO v_txt FROM wallets WHERE user_id = v_admin;
  IF v_txt::NUMERIC - v_adm_mxn = 200 THEN
    v_report := v_report || 'T8b admin +200 bruto contractual (sin fee estimado) .......... PASS' || E'\n';
  ELSE
    v_report := v_report || 'T8b admin bruto ..................................... FAIL delta=' || (v_txt::NUMERIC - v_adm_mxn)::text || E'\n';
  END IF;

  ---------------------------------------------------------------
  -- T9: repetir credit → already_resolved (anti-doble crédito)
  ---------------------------------------------------------------
  v_json := public.resolve_payment_receipt(
    v_rc1, 'credit', 'repite', 'ch_521_a', v_r1, v_r1, 120000, 'MXN', NULL, NULL);
  IF v_json->>'result' IN ('already_resolved','not_resolvable_state')
     AND (SELECT pending_balance FROM group_wallets WHERE group_id=v_group) = v_bal_mxn + 1000
     AND (SELECT COUNT(*) FROM wallet_transactions WHERE reservation_id=v_r1 AND type='credit_pending') = 1 THEN
    v_report := v_report || 'T9  credit repetido → sin doble crédito (1 solo ledger) ...... PASS' || E'\n';
  ELSE
    v_report := v_report || 'T9  anti-doble crédito .............................. FAIL ' || v_json::text || E'\n';
  END IF;

  ---------------------------------------------------------------
  -- T10: already_credited_elsewhere (conflicto de identidad)
  ---------------------------------------------------------------
  -- Evidencia para ch_521_b apuntando a v_r2, pero ch_521_b "ya acreditado"
  -- en otra reserva (simulado con mp_payment_id en v_r3 pagada)
  UPDATE reservations SET mp_payment_id='ch_521_b', payment_status='paid' WHERE id=v_r3;
  v_json := public.register_payment_evidence(
    'stripe','ch_521_b','ord_521_b', v_r2, TRUE, 120000,'MXN',0,0,
    100000, 20000, NOW(), '{"src":"test"}'::jsonb, '{"total":"t"}'::jsonb,
    NULL, NULL, 'evidencia conflicto', NULL);
  v_json := public.resolve_payment_receipt(
    v_rc2, 'credit', 'intento', 'ch_521_b', v_r2, v_r2, 120000, 'MXN', NULL, NULL);
  IF v_json->>'result' = 'already_credited_elsewhere'
     AND (SELECT payment_status FROM reservations WHERE id=v_r2) = 'unpaid' THEN
    v_report := v_report || 'T10 payment ya acreditado en otra → rechazo auditado ......... PASS' || E'\n';
  ELSE
    v_report := v_report || 'T10 already_credited_elsewhere ...................... FAIL ' || v_json::text || E'\n';
  END IF;
  UPDATE reservations SET mp_payment_id=NULL, payment_status='unpaid' WHERE id=v_r3;

  ---------------------------------------------------------------
  -- T11: REFUND desde recorded → cola + settlement refund_pending
  ---------------------------------------------------------------
  v_json := public.resolve_payment_receipt(
    v_rc2, 'refund', 'no conservable', 'ch_521_b',
    NULL, NULL, NULL, NULL, NULL, NULL);
  IF v_json->>'result' = 'refund_queued'
     AND (SELECT settlement_status FROM payment_receipts WHERE id=v_rc2) = 'refund_pending'
     AND (SELECT COUNT(*) FROM refund_intents WHERE provider_payment_id='ch_521_b'
            AND status='pending' AND amount_minor=120000) = 1 THEN
    v_report := v_report || 'T11 REFUND manual → intent en cola + refund_pending .......... PASS' || E'\n';
  ELSE
    v_report := v_report || 'T11 refund .......................................... FAIL ' || v_json::text || E'\n';
  END IF;
  SELECT id INTO v_int FROM refund_intents WHERE provider_payment_id='ch_521_b';

  ---------------------------------------------------------------
  -- T12: ciclo del intent — done sin claim / claim / claimed_by_other /
  --       done sin referencia / done OK / done repetido
  ---------------------------------------------------------------
  v_json := public.admin_complete_refund_intent(v_int, 'done', 'REF-1', NULL, NULL);
  v_txt  := v_json->>'result';   -- esperado: not_resolvable_state (sin claim)
  v_json := public.admin_complete_refund_intent(v_int, 'claim', NULL, NULL, NULL);
  IF v_txt = 'not_resolvable_state' AND v_json->>'result' = 'intent_processing' THEN
    v_report := v_report || 'T12a done-sin-claim rechazado; claim OK ...................... PASS' || E'\n';
  ELSE
    v_report := v_report || 'T12a claim .......................................... FAIL ' || v_txt || '/' || v_json::text || E'\n';
  END IF;

  -- claimed_by_other: simular reclamo vigente de OTRO admin
  UPDATE refund_intents SET claimed_by = gen_random_uuid(), claimed_at = NOW() WHERE id = v_int;
  v_json := public.admin_complete_refund_intent(v_int, 'done', 'REF-X', NULL, NULL);
  IF v_json->>'result' = 'claimed_by_other' THEN
    v_report := v_report || 'T12b reclamo vigente de otro admin → claimed_by_other ........ PASS' || E'\n';
  ELSE
    v_report := v_report || 'T12b claimed_by_other ............................... FAIL ' || v_json::text || E'\n';
  END IF;

  -- takeover: reclamo ATORADO (más viejo que el timeout)
  UPDATE refund_intents SET claimed_at = NOW() - INTERVAL '2 hours' WHERE id = v_int;
  v_json := public.admin_complete_refund_intent(v_int, 'claim', NULL, NULL, NULL);
  IF v_json->>'result' = 'intent_processing' AND (v_json->>'takeover')::BOOLEAN
     AND (SELECT COUNT(*) FROM financial_audit_logs
          WHERE action='refund_claim_takeover' AND entity_id=v_int) = 1 THEN
    v_report := v_report || 'T12c intent atorado → takeover auditado ...................... PASS' || E'\n';
  ELSE
    v_report := v_report || 'T12c takeover ....................................... FAIL ' || v_json::text || E'\n';
  END IF;

  v_json := public.admin_complete_refund_intent(v_int, 'done', '', NULL, NULL);
  v_txt  := v_json->>'result';   -- esperado: reference_required
  v_json := public.admin_complete_refund_intent(v_int, 'done', 'SPEI-REF-12345', 'ruta/comprobante.pdf', NULL);
  IF v_txt = 'reference_required' AND v_json->>'result' = 'intent_sent'
     AND (SELECT settlement_status FROM payment_receipts WHERE id=v_rc2) = 'refund_completed'
     AND (SELECT transfer_reference FROM refund_intents WHERE id=v_int) = 'SPEI-REF-12345' THEN
    v_report := v_report || 'T12d done exige referencia; done OK → refund_completed ....... PASS' || E'\n';
  ELSE
    v_report := v_report || 'T12d done ........................................... FAIL ' || v_txt || '/' || v_json::text || E'\n';
  END IF;

  v_json := public.admin_complete_refund_intent(v_int, 'done', 'OTRA-REF', NULL, NULL);
  IF v_json->>'result' = 'already_sent' THEN
    v_report := v_report || 'T12e done repetido → already_sent (idempotente) .............. PASS' || E'\n';
  ELSE
    v_report := v_report || 'T12e already_sent ................................... FAIL ' || v_json::text || E'\n';
  END IF;

  ---------------------------------------------------------------
  -- T13: DISMISS de dinero capturado → PROHIBIDO
  ---------------------------------------------------------------
  v_json := public.register_payment_evidence(
    'conekta','ch_521_c','ord_521_c', v_r3, TRUE, 120000,'MXN',0,0,
    100000, 20000, NOW(), '{"captured":true}'::jsonb, '{"total":"t"}'::jsonb,
    NULL, NULL, 'capturado real', NULL);
  v_json := public.resolve_payment_receipt(
    v_rc3, 'dismiss', 'intento dismiss', 'ch_521_c',
    NULL, NULL, NULL, NULL, 'garbage_no_money', NULL);
  IF v_json->>'result' = 'captured_money_cannot_be_dismissed'
     AND (SELECT settlement_status FROM payment_receipts WHERE id=v_rc3) = 'unsettled' THEN
    v_report := v_report || 'T13 dismiss de dinero capturado → PROHIBIDO .................. PASS' || E'\n';
  ELSE
    v_report := v_report || 'T13 captured no dismissible ......................... FAIL ' || v_json::text || E'\n';
  END IF;

  ---------------------------------------------------------------
  -- T14: dismiss duplicado → canónico DEBE estar conciliado
  ---------------------------------------------------------------
  v_json := public.register_payment_evidence(
    'conekta','ch_521_d','ord_521_d', NULL, FALSE, 50000,'MXN',0,0,
    NULL, NULL, NOW(), '{"voided":true}'::jsonb, '{"status":"conekta.order.status"}'::jsonb,
    NULL, NULL, 'sin captura según proveedor', NULL);
  -- canónico NO conciliado (v_rc3 sigue unsettled) → rechazo
  v_json := public.resolve_payment_receipt(
    v_rc4, 'dismiss', 'duplicado', 'ch_521_d',
    NULL, NULL, NULL, NULL, 'duplicate_of_canonical', v_rc3);
  v_txt := v_json->>'result';
  -- canónico conciliado (v_rc1 credited) → OK
  v_json := public.resolve_payment_receipt(
    v_rc4, 'dismiss', 'duplicado del acreditado', 'ch_521_d',
    NULL, NULL, NULL, NULL, 'duplicate_of_canonical', v_rc1);
  IF v_txt = 'invalid_action' AND v_json->>'result' = 'dismissed'
     AND (SELECT settlement_status FROM payment_receipts WHERE id=v_rc4) = 'duplicate_linked'
     AND (SELECT canonical_receipt_id FROM payment_receipts WHERE id=v_rc4) = v_rc1 THEN
    v_report := v_report || 'T14 duplicado: canónico no-final rechazado; final vincula .... PASS' || E'\n';
  ELSE
    v_report := v_report || 'T14 duplicado ....................................... FAIL ' || v_txt || '/' || v_json::text || E'\n';
  END IF;

  ---------------------------------------------------------------
  -- T15: dismiss provider_no_capture → cero movimiento de wallets
  ---------------------------------------------------------------
  SELECT pending_balance, COALESCE(pending_balance_usd,0) INTO v_bal_mxn, v_bal_usd
  FROM group_wallets WHERE group_id = v_group;
  -- Nueva versión de evidencia para ch_521_c: el proveedor confirma VOID
  v_json := public.register_payment_evidence(
    'conekta','ch_521_c','ord_521_c', v_r3, FALSE, 120000,'MXN',0,0,
    NULL, NULL, NOW(), '{"voided":true}'::jsonb, '{"status":"conekta.order.status"}'::jsonb,
    NULL, NULL, 'corrección: cargo voided',
    (SELECT id FROM admin_payment_evidence
     WHERE provider='conekta' AND provider_payment_id='ch_521_c' AND version=1));
  v_json := public.resolve_payment_receipt(
    v_rc3, 'dismiss', 'void confirmado', 'ch_521_c',
    NULL, NULL, NULL, NULL, 'provider_no_capture', NULL);
  IF v_json->>'result' = 'dismissed'
     AND (SELECT settlement_status FROM payment_receipts WHERE id=v_rc3) = 'no_capture_verified'
     AND (SELECT pending_balance FROM group_wallets WHERE group_id=v_group) = v_bal_mxn
     AND (SELECT COALESCE(pending_balance_usd,0) FROM group_wallets WHERE group_id=v_group) = v_bal_usd THEN
    v_report := v_report || 'T15 no_capture (evidencia v2) → cierre sin tocar wallets ..... PASS' || E'\n';
  ELSE
    v_report := v_report || 'T15 no_capture ...................................... FAIL ' || v_json::text || E'\n';
  END IF;

  ---------------------------------------------------------------
  -- T16: CREDIT USD → solo columnas USD (cero mezcla de monedas)
  ---------------------------------------------------------------
  SELECT pending_balance, COALESCE(pending_balance_usd,0) INTO v_bal_mxn, v_bal_usd
  FROM group_wallets WHERE group_id = v_group;
  v_json := public.register_payment_evidence(
    'stripe','ch_521_usd','ord_521_usd', v_rusd, TRUE, 120000,'USD',0,0,
    100000, 20000, NOW(), '{"amount":120000,"currency":"usd"}'::jsonb,
    '{"total":"stripe.pi.amount"}'::jsonb, NULL, NULL, 'evidencia USD', NULL);
  v_json := public.resolve_payment_receipt(
    v_rcu, 'credit', 'crédito USD', 'ch_521_usd',
    v_rusd, v_rusd, 120000, 'USD', NULL, NULL);
  IF v_json->>'result' = 'credited'
     AND (SELECT COALESCE(pending_balance_usd,0) FROM group_wallets WHERE group_id=v_group) = v_bal_usd + 1000
     AND (SELECT pending_balance FROM group_wallets WHERE group_id=v_group) = v_bal_mxn
     AND (SELECT COALESCE(available_balance_usd,0) - v_adm_usd FROM wallets WHERE user_id=v_admin) = 200 THEN
    v_report := v_report || 'T16 CREDIT USD → +1000 usd / MXN intacto / admin +200 usd .... PASS' || E'\n';
  ELSE
    v_report := v_report || 'T16 USD sin mezcla .................................. FAIL ' || v_json::text || E'\n';
  END IF;

  ---------------------------------------------------------------
  -- T17: GATE con CAD → currency_unsupported_wallet (bloqueo íntegro)
  ---------------------------------------------------------------
  INSERT INTO payment_attempts (provider, client_key, provider_order_id, reservation_id, expected_amount_minor, currency, method, status)
  VALUES ('stripe','k_521_cad','ord_521_cad', v_rcad, 120000,'CAD','card','created');
  SELECT pending_balance, COALESCE(pending_balance_usd,0) INTO v_bal_mxn, v_bal_usd
  FROM group_wallets WHERE group_id = v_group;
  v_json := public.confirm_reservation_payment_v2(
    'stripe','ord_521_cad','ch_521_cad', v_rcad, 120000,'CAD','card', NULL,NULL, NULL);
  IF v_json->>'result' = 'currency_unsupported_wallet'
     AND (SELECT payment_status FROM reservations WHERE id=v_rcad) = 'paid_blocked'
     AND (SELECT COUNT(*) FROM refund_intents WHERE provider_payment_id='ch_521_cad') = 1
     AND (SELECT settlement_status FROM payment_receipts WHERE provider_payment_id='ch_521_cad') = 'refund_pending'
     AND (SELECT pending_balance FROM group_wallets WHERE group_id=v_group) = v_bal_mxn
     AND (SELECT COALESCE(pending_balance_usd,0) FROM group_wallets WHERE group_id=v_group) = v_bal_usd THEN
    v_report := v_report || 'T17 GATE CAD → bloqueo íntegro, ni un centavo en MXN/USD ..... PASS' || E'\n';
  ELSE
    v_report := v_report || 'T17 gate CAD ........................................ FAIL ' || v_json::text || E'\n';
  END IF;

  ---------------------------------------------------------------
  -- T18: fórmula markup20 — 10001/10002/10003 sin crear/perder centavos
  ---------------------------------------------------------------
  IF public.markup20_base_minor(10001) = 8334
     AND public.markup20_base_minor(10002) = 8335
     AND public.markup20_base_minor(10003) = 8336
     AND (8334 + (10001-8334)) = 10001
     AND (8335 + (10002-8335)) = 10002
     AND (8336 + (10003-8336)) = 10003 THEN
    v_report := v_report || 'T18 markup20: 8334/8335/8336 — invariante exacto ............. PASS' || E'\n';
  ELSE
    v_report := v_report || 'T18 markup20 ........................................ FAIL' || E'\n';
  END IF;

  ---------------------------------------------------------------
  -- T19: EXCEPCIÓN a mitad del credit → rollback total, sin parciales
  ---------------------------------------------------------------
  v_json := public.register_payment_evidence(
    'stripe','ch_521_t19','ord_521_t19', v_r19, TRUE, 120000,'MXN',0,0,
    100000, 20000, NOW(), '{"src":"t19"}'::jsonb, '{"total":"t"}'::jsonb,
    NULL, NULL, 'evidencia t19', NULL);
  ALTER TABLE wallet_transactions ADD CONSTRAINT __t522_fail CHECK (amount < 0) NOT VALID;
  BEGIN
    v_json := public.resolve_payment_receipt(
      v_rc19, 'credit', 'debería abortar', 'ch_521_t19',
      v_r19, v_r19, 120000, 'MXN', NULL, NULL);
    v_report := v_report || 'T19 excepción inducida .............................. FAIL (no abortó)' || E'\n';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM LIKE '%__t522_fail%'
       AND (SELECT payment_status FROM reservations WHERE id=v_r19) = 'unpaid'
       AND (SELECT resolution FROM payment_receipts WHERE id=v_rc19) IS NULL
       AND (SELECT settlement_status FROM payment_receipts WHERE id=v_rc19) = 'unsettled' THEN
      v_report := v_report || 'T19 excepción a mitad del credit → CERO efectos parciales .... PASS' || E'\n';
    ELSE
      v_report := v_report || 'T19 rollback parcial ................................ FAIL ' || SQLERRM || E'\n';
    END IF;
  END;
  ALTER TABLE wallet_transactions DROP CONSTRAINT __t522_fail;

  ---------------------------------------------------------------
  -- T20: coherencia settlement (CHECK) + conciliación total
  ---------------------------------------------------------------
  BEGIN
    UPDATE payment_receipts SET settlement_status='credited' WHERE id=v_rc19;  -- recorded → incoherente
    v_report := v_report || 'T20a CHECK coherencia ............................... FAIL (dejó pasar)' || E'\n';
  EXCEPTION WHEN check_violation THEN
    v_report := v_report || 'T20a settlement incoherente → CHECK lo rechaza ............... PASS' || E'\n';
  END;

  SELECT COUNT(*) INTO v_n FROM payment_receipts
  WHERE provider_payment_id LIKE 'ch_521%';
  IF v_n = 7
     AND (SELECT COUNT(*) FROM payment_receipts
          WHERE provider_payment_id LIKE 'ch_521%'
            AND settlement_status IN ('credited','refund_pending','refund_completed',
                                      'no_capture_verified','duplicate_linked','unsettled')) = 7 THEN
    v_report := v_report || 'T20b conciliación: los 7 receipts visibles, ninguno perdido .. PASS' || E'\n';
  ELSE
    v_report := v_report || 'T20b conciliación ................................... FAIL n=' || v_n::text || E'\n';
  END IF;

  v_report := v_report || E'══════ FIN — todo se revierte ahora (RAISE) ══════';
  RAISE EXCEPTION '%', v_report;
END $$;
