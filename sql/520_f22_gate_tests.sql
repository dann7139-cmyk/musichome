-- ============================================================
-- sql/520_f22_gate_tests.sql — F2.2 PRUEBAS DEL GATE (NO persiste NADA)
--
-- Mismo truco que sql/515: TODO corre en un DO-block que SIEMPRE
-- termina con RAISE EXCEPTION llevando el reporte completo →
-- Postgres revierte absolutamente todo (reservas, wallets, receipts,
-- notificaciones, auditoría, el constraint temporal de T15).
-- El "error" final ES el reporte. Cero rastro en la base.
--
-- Requiere sql/519 ejecutado. NO toca checkout, webhooks ni la RPC
-- vieja. NO ejecuta servicios externos.
--
-- ⚠️ T15 toma un lock exclusivo breve sobre wallet_transactions
-- (ALTER temporal que se revierte): correr en un momento de bajo
-- tráfico. Duración total esperada: ~1-2 segundos.
--
-- Pruebas de CONCURRENCIA REAL (dos sesiones) NO caben en una sola
-- transacción: ver el guion de 2 pestañas entregado junto a este
-- archivo (lock timeout real, mismo pago simultáneo, UNIQUE bajo
-- carrera). Aquí T16 verifica estáticamente que el mecanismo existe.
-- ============================================================

DO $$
DECLARE
  v_user     UUID;
  v_group    UUID;
  v_admin_id UUID;
  v_r1 UUID; v_r2 UUID; v_r3 UUID; v_r4 UUID; v_r5 UUID; v_r5b UUID;
  v_r6 UUID; v_r7 UUID; v_r8 UUID; v_r9 UUID;
  v_json     JSONB;
  v_bal      NUMERIC;
  v_adm0     NUMERIC := 0;
  v_adm      NUMERIC;
  v_res      RECORD;
  v_txt      TEXT;
  v_report   TEXT := E'\n══════ REPORTE DE PRUEBAS F2.2 (gate v2) ══════\n';
BEGIN
  -- ─────────────────── SETUP (patrón sql/515) ───────────────────
  SELECT id INTO v_user FROM profiles LIMIT 1;
  SELECT id INTO v_admin_id FROM profiles WHERE role = 'admin' ORDER BY created_at LIMIT 1;

  INSERT INTO groups (name, owner_id, state, country, is_active)
  VALUES ('__TEST_F22__', v_user, 'Jalisco', 'México', false)
  RETURNING id INTO v_group;

  PERFORM ensure_group_wallet(v_group);

  IF v_admin_id IS NOT NULL THEN
    SELECT COALESCE(available_balance, 0) INTO v_adm0
    FROM wallets WHERE user_id = v_admin_id;
    v_adm0 := COALESCE(v_adm0, 0);
  END IF;

  -- Reservas de prueba (fechas 2030-06-XX, una fecha por reserva ocupante).
  -- Todas: total 1200 / base 1000 → earnings 1000, comisión 200.
  INSERT INTO reservations (group_id, client_id, event_date, event_time, hours_count, status, payment_status, total_price, base_price, address)
  VALUES (v_group, v_user, DATE '2030-06-01', TIME '18:00', 3, 'pending_payment', 'unpaid', 1200, 1000, 'Av. Prueba 123')
  RETURNING id INTO v_r1;

  INSERT INTO reservations (group_id, client_id, event_date, event_time, hours_count, status, payment_status, total_price, base_price, address)
  VALUES (v_group, v_user, DATE '2030-06-02', TIME '18:00', 3, 'accepted', 'unpaid', 1200, 1000, 'Av. Prueba 123')
  RETURNING id INTO v_r2;
  UPDATE reservations SET status = 'cancelled' WHERE id = v_r2;

  INSERT INTO reservations (group_id, client_id, event_date, event_time, hours_count, status, payment_status, total_price, base_price, address)
  VALUES (v_group, v_user, DATE '2030-06-03', TIME '18:00', 3, 'accepted', 'unpaid', 1200, 1000, 'Av. Prueba 123')
  RETURNING id INTO v_r3;
  UPDATE reservations SET status = 'expired' WHERE id = v_r3;

  INSERT INTO reservations (group_id, client_id, event_date, event_time, hours_count, status, payment_status, total_price, base_price, address)
  VALUES (v_group, v_user, DATE '2030-06-04', TIME '18:00', 3, 'accepted', 'unpaid', 1200, 1000, 'Av. Prueba 123')
  RETURNING id INTO v_r4;
  UPDATE reservations SET status = 'expired' WHERE id = v_r4;

  -- R5: expirada en una fecha que LUEGO ocupa R5b confirmada
  INSERT INTO reservations (group_id, client_id, event_date, event_time, hours_count, status, payment_status, total_price, base_price, address)
  VALUES (v_group, v_user, DATE '2030-06-05', TIME '18:00', 3, 'accepted', 'unpaid', 1200, 1000, 'Av. Prueba 123')
  RETURNING id INTO v_r5;
  UPDATE reservations SET status = 'expired' WHERE id = v_r5;
  INSERT INTO reservations (group_id, client_id, event_date, event_time, hours_count, status, payment_status, total_price, base_price, address)
  VALUES (v_group, v_user, DATE '2030-06-05', TIME '10:00', 2, 'confirmed', 'unpaid', 800, 666, 'Av. Prueba 123')
  RETURNING id INTO v_r5b;

  INSERT INTO reservations (group_id, client_id, event_date, event_time, hours_count, status, payment_status, total_price, base_price, address)
  VALUES (v_group, v_user, DATE '2030-06-06', TIME '18:00', 3, 'pending_payment', 'unpaid', 1200, 1000, 'Av. Prueba 123')
  RETURNING id INTO v_r6;
  INSERT INTO reservations (group_id, client_id, event_date, event_time, hours_count, status, payment_status, total_price, base_price, address)
  VALUES (v_group, v_user, DATE '2030-06-07', TIME '18:00', 3, 'pending_payment', 'unpaid', 1200, 1000, 'Av. Prueba 123')
  RETURNING id INTO v_r7;
  INSERT INTO reservations (group_id, client_id, event_date, event_time, hours_count, status, payment_status, total_price, base_price, address)
  VALUES (v_group, v_user, DATE '2030-06-08', TIME '18:00', 3, 'pending_payment', 'unpaid', 1200, 1000, 'Av. Prueba 123')
  RETURNING id INTO v_r8;
  INSERT INTO reservations (group_id, client_id, event_date, event_time, hours_count, status, payment_status, total_price, base_price, address)
  VALUES (v_group, v_user, DATE '2030-06-09', TIME '18:00', 3, 'pending_payment', 'unpaid', 1200, 1000, 'Av. Prueba 123')
  RETURNING id INTO v_r9;

  -- Capturas de checkout (payment_attempts) — 120000 centavos = $1,200 MXN
  INSERT INTO payment_attempts (provider, client_key, provider_order_id, reservation_id, expected_amount_minor, currency, method, status) VALUES
    ('stripe',  'k_t1',  'ord_t1',  v_r1, 120000, 'MXN', 'card', 'created'),
    ('conekta', 'k_t2',  'ord_t2',  v_r2, 120000, 'MXN', 'card', 'created'),
    ('stripe',  'k_t3',  'ord_t3',  v_r3, 120000, 'MXN', 'card', 'created'),
    ('stripe',  'k_t4',  'ord_t4',  v_r4, 120000, 'MXN', 'card', 'created'),
    ('stripe',  'k_t5',  'ord_t5',  v_r5, 120000, 'MXN', 'card', 'created'),
    ('stripe',  'k_t6',  'ord_t6',  v_r6, 120000, 'MXN', 'card', 'created'),
    ('stripe',  'k_t7',  'ord_t7',  v_r7, 120000, 'MXN', 'card', 'created'),
    ('stripe',  'k_t8',  'ord_t8',  v_r8, 120000, 'MXN', 'card', 'created'),
    ('stripe',  'k_t9',  'ord_t9',  v_r9, 120000, 'MXN', 'card', 'created'),
    ('stripe',  'k_t11', 'ord_t11', v_r6, 120000, 'MXN', 'card', 'created'),
    ('stripe',  'k_t14', 'ord_t14', v_r6, 120000, 'MXN', 'card', 'created');

  -- T6 necesita un intento VIEJO (fuera de la ventana de 24h tarjeta)
  UPDATE payment_attempts SET created_at = NOW() - INTERVAL '48 hours'
  WHERE provider_order_id = 'ord_t4';

  ---------------------------------------------------------------
  -- T1: PAGO CORRECTO → confirmed + escribe todo EXACTAMENTE 1 vez
  ---------------------------------------------------------------
  v_json := public.confirm_reservation_payment_v2(
    'stripe','ord_t1','ch_t1', v_r1, 120000,'MXN','card', 4321,'stripe_balance_txn', NULL);
  SELECT * INTO v_res FROM reservations WHERE id = v_r1;
  SELECT pending_balance INTO v_bal FROM group_wallets WHERE group_id = v_group;
  IF v_json->>'result' = 'confirmed'
     AND v_res.status = 'confirmed' AND v_res.payment_status = 'paid'
     AND v_res.payout_status = 'held' AND v_res.mp_payment_id = 'ch_t1'
     AND v_bal = 1000
     AND (SELECT COUNT(*) FROM payment_receipts WHERE provider_payment_id='ch_t1'
            AND result='confirmed' AND money_state='credited'
            AND processor_fee_minor=4321 AND processor_fee_status='captured') = 1
     AND (SELECT COUNT(*) FROM wallet_transactions WHERE reservation_id=v_r1 AND type='credit_pending') = 1
     AND (SELECT COUNT(*) FROM financial_audit_logs WHERE entity_id=v_r1 AND action='hold') = 1
     AND (SELECT status FROM payment_attempts WHERE provider_order_id='ord_t1') = 'consumed' THEN
    v_report := v_report || 'T1  pago correcto → confirmed (1 receipt, 1 ledger, 1 audit, held) ... PASS' || E'\n';
  ELSE
    v_report := v_report || 'T1  pago correcto .................................. FAIL ' || v_json::text || E'\n';
  END IF;

  IF v_admin_id IS NOT NULL THEN
    SELECT COALESCE(available_balance,0) INTO v_adm FROM wallets WHERE user_id = v_admin_id;
    IF v_adm - v_adm0 = 200 THEN
      v_report := v_report || 'T1b admin acreditado con BRUTO contractual ($200, sin fee estimado) . PASS' || E'\n';
    ELSE
      v_report := v_report || 'T1b admin bruto ..................................... FAIL delta=' || (v_adm - v_adm0)::text || E'\n';
    END IF;
  ELSE
    v_report := v_report || 'T1b admin bruto — SKIP (no hay perfil admin)' || E'\n';
  END IF;

  ---------------------------------------------------------------
  -- T2: REENVÍO del mismo pago → already_processed, sin doble crédito
  ---------------------------------------------------------------
  v_json := public.confirm_reservation_payment_v2(
    'stripe','ord_t1','ch_t1', v_r1, 120000,'MXN','card', 4321,'stripe_balance_txn', NULL);
  SELECT pending_balance INTO v_bal FROM group_wallets WHERE group_id = v_group;
  IF v_json->>'result' = 'already_processed' AND v_bal = 1000
     AND (SELECT COUNT(*) FROM payment_receipts WHERE provider_payment_id='ch_t1') = 1
     AND (SELECT COUNT(*) FROM wallet_transactions WHERE reservation_id=v_r1 AND type='credit_pending') = 1 THEN
    v_report := v_report || 'T2  reenvío → already_processed, crédito NO duplicado ............... PASS' || E'\n';
  ELSE
    v_report := v_report || 'T2  reenvío ......................................... FAIL ' || v_json::text || E'\n';
  END IF;

  ---------------------------------------------------------------
  -- T3: RESERVA CANCELADA → terminal_reservation + paid_blocked + cola
  ---------------------------------------------------------------
  v_json := public.confirm_reservation_payment_v2(
    'conekta','ord_t2','ch_t2', v_r2, 120000,'MXN','card', NULL,NULL, NULL);
  SELECT * INTO v_res FROM reservations WHERE id = v_r2;
  SELECT pending_balance INTO v_bal FROM group_wallets WHERE group_id = v_group;
  IF v_json->>'result' = 'terminal_reservation'
     AND v_res.status = 'cancelled' AND v_res.payment_status = 'paid_blocked'
     AND v_bal = 1000
     AND (SELECT COUNT(*) FROM refund_intents WHERE provider_payment_id='ch_t2'
            AND refund_type='full' AND amount_minor=120000 AND status='pending') = 1
     AND (SELECT COUNT(*) FROM payment_receipts WHERE provider_payment_id='ch_t2'
            AND money_state='blocked_refund_pending' AND processor_fee_status='not_captured') = 1
     AND (SELECT COUNT(*) FROM wallet_transactions WHERE reservation_id=v_r2) = 0 THEN
    v_report := v_report || 'T3  cancelada → terminal + paid_blocked + reembolso en cola ........ PASS' || E'\n';
  ELSE
    v_report := v_report || 'T3  cancelada ....................................... FAIL ' || v_json::text || E'\n';
  END IF;

  ---------------------------------------------------------------
  -- T4: reenvío del bloqueado → already_processed, NUNCA 2 refund_intents
  ---------------------------------------------------------------
  v_json := public.confirm_reservation_payment_v2(
    'conekta','ord_t2','ch_t2', v_r2, 120000,'MXN','card', NULL,NULL, NULL);
  IF v_json->>'result' = 'already_processed'
     AND (SELECT COUNT(*) FROM refund_intents WHERE provider_payment_id='ch_t2') = 1 THEN
    v_report := v_report || 'T4  reenvío de bloqueado → jamás segundo refund_intent .............. PASS' || E'\n';
  ELSE
    v_report := v_report || 'T4  reenvío bloqueado ............................... FAIL ' || v_json::text || E'\n';
  END IF;

  ---------------------------------------------------------------
  -- T5: EXPIRADA dentro de ventana + slot libre → REVIVE y confirma
  ---------------------------------------------------------------
  v_json := public.confirm_reservation_payment_v2(
    'stripe','ord_t3','ch_t3', v_r3, 120000,'MXN','card', NULL,NULL, NULL);
  SELECT * INTO v_res FROM reservations WHERE id = v_r3;
  SELECT pending_balance INTO v_bal FROM group_wallets WHERE group_id = v_group;
  IF v_json->>'result' = 'confirmed' AND (v_json->>'revived')::boolean
     AND v_res.status = 'confirmed' AND v_res.payment_status = 'paid'
     AND v_bal = 2000 THEN
    v_report := v_report || 'T5  expirada EN ventana + slot libre → revive y confirma ............ PASS' || E'\n';
  ELSE
    v_report := v_report || 'T5  revive .......................................... FAIL ' || v_json::text || E'\n';
  END IF;

  ---------------------------------------------------------------
  -- T6: EXPIRADA fuera de ventana (intento de hace 48h, tarjeta=24h)
  ---------------------------------------------------------------
  v_json := public.confirm_reservation_payment_v2(
    'stripe','ord_t4','ch_t4', v_r4, 120000,'MXN','card', NULL,NULL, NULL);
  SELECT * INTO v_res FROM reservations WHERE id = v_r4;
  SELECT pending_balance INTO v_bal FROM group_wallets WHERE group_id = v_group;
  IF v_json->>'result' = 'late_payment_outside_window'
     AND v_res.status = 'expired' AND v_res.payment_status = 'paid_blocked'
     AND v_bal = 2000
     AND (SELECT COUNT(*) FROM refund_intents WHERE provider_payment_id='ch_t4') = 1 THEN
    v_report := v_report || 'T6  expirada FUERA de ventana → bloqueado + reembolso ............... PASS' || E'\n';
  ELSE
    v_report := v_report || 'T6  fuera de ventana ................................ FAIL ' || v_json::text || E'\n';
  END IF;

  ---------------------------------------------------------------
  -- T7: DISPONIBILIDAD PERDIDA al revivir (date_taken sigue activo)
  ---------------------------------------------------------------
  v_json := public.confirm_reservation_payment_v2(
    'stripe','ord_t5','ch_t5', v_r5, 120000,'MXN','card', NULL,NULL, NULL);
  SELECT * INTO v_res FROM reservations WHERE id = v_r5;
  SELECT pending_balance INTO v_bal FROM group_wallets WHERE group_id = v_group;
  IF v_json->>'result' = 'payment_blocked_refund_pending'
     AND v_json->>'reason' LIKE '%date_taken_legacy%'
     AND v_res.status = 'expired' AND v_res.payment_status = 'paid_blocked'
     AND v_bal = 2000
     AND (SELECT COUNT(*) FROM refund_intents WHERE provider_payment_id='ch_t5') = 1 THEN
    v_report := v_report || 'T7  disponibilidad perdida (date_taken ACTIVO bloquea revive) ....... PASS' || E'\n';
  ELSE
    v_report := v_report || 'T7  disponibilidad perdida .......................... FAIL ' || v_json::text || E'\n';
  END IF;

  ---------------------------------------------------------------
  -- T8/T9/T10: IMPORTE MENOR / MAYOR / MONEDA — tolerancia CERO
  ---------------------------------------------------------------
  v_json := public.confirm_reservation_payment_v2(
    'stripe','ord_t6','ch_t6', v_r6, 110000,'MXN','card', NULL,NULL, NULL);
  SELECT * INTO v_res FROM reservations WHERE id = v_r6;
  IF v_json->>'result' = 'amount_mismatch'
     AND v_res.status = 'pending_payment' AND v_res.payment_status = 'paid_blocked'
     AND (SELECT COUNT(*) FROM refund_intents WHERE provider_payment_id='ch_t6' AND amount_minor=110000) = 1 THEN
    v_report := v_report || 'T8  importe MENOR → amount_mismatch + reembolso íntegro ............. PASS' || E'\n';
  ELSE
    v_report := v_report || 'T8  importe menor ................................... FAIL ' || v_json::text || E'\n';
  END IF;

  v_json := public.confirm_reservation_payment_v2(
    'stripe','ord_t7','ch_t7', v_r7, 130000,'MXN','card', NULL,NULL, NULL);
  IF v_json->>'result' = 'overpayment_refund_pending'
     AND (SELECT payment_status FROM reservations WHERE id=v_r7) = 'paid_blocked'
     AND (SELECT status FROM reservations WHERE id=v_r7) = 'pending_payment'
     AND (SELECT COUNT(*) FROM refund_intents WHERE provider_payment_id='ch_t7' AND amount_minor=130000) = 1 THEN
    v_report := v_report || 'T9  importe MAYOR → bloqueo total + reembolso íntegro (política B) .. PASS' || E'\n';
  ELSE
    v_report := v_report || 'T9  importe mayor ................................... FAIL ' || v_json::text || E'\n';
  END IF;

  v_json := public.confirm_reservation_payment_v2(
    'stripe','ord_t8','ch_t8', v_r8, 120000,'USD','card', NULL,NULL, NULL);
  IF v_json->>'result' = 'currency_mismatch'
     AND (SELECT COUNT(*) FROM refund_intents WHERE provider_payment_id='ch_t8') = 1 THEN
    v_report := v_report || 'T10 moneda incorrecta → currency_mismatch + reembolso ............... PASS' || E'\n';
  ELSE
    v_report := v_report || 'T10 moneda .......................................... FAIL ' || v_json::text || E'\n';
  END IF;

  SELECT pending_balance INTO v_bal FROM group_wallets WHERE group_id = v_group;
  IF v_bal = 2000 THEN
    v_report := v_report || 'T10b tras 5 ramas bloqueadas la wallet sigue INTACTA ($2000) ........ PASS' || E'\n';
  ELSE
    v_report := v_report || 'T10b wallet tras bloqueos ........................... FAIL bal=' || v_bal::text || E'\n';
  END IF;

  ---------------------------------------------------------------
  -- T11: MISMO payment_id EN OTRA RESERVA → conflicto de identidad
  --      (precisión #1: solo auditoría, cero mutaciones, cero reembolso)
  ---------------------------------------------------------------
  v_json := public.confirm_reservation_payment_v2(
    'stripe','ord_t11','ch_t1', v_r6, 120000,'MXN','card', NULL,NULL, NULL);
  SELECT * INTO v_res FROM reservations WHERE id = v_r1;
  IF v_json->>'result' = 'payment_identity_conflict'
     AND v_res.status = 'confirmed' AND v_res.payment_status = 'paid'          -- R1 intacta
     AND (SELECT result FROM payment_receipts WHERE provider_payment_id='ch_t1') = 'confirmed'
     AND (SELECT money_state FROM payment_receipts WHERE provider_payment_id='ch_t1') = 'credited'
     AND (SELECT COUNT(*) FROM refund_intents WHERE provider_payment_id='ch_t1') = 0
     AND (SELECT COUNT(*) FROM financial_audit_logs WHERE action='payment_identity_conflict') >= 1
     AND (SELECT pending_balance FROM group_wallets WHERE group_id=v_group) = 2000 THEN
    v_report := v_report || 'T11 payment_id de otra reserva → conflicto, SIN tocar nada ......... PASS' || E'\n';
  ELSE
    v_report := v_report || 'T11 conflicto cruzado ............................... FAIL ' || v_json::text || E'\n';
  END IF;

  ---------------------------------------------------------------
  -- T12: mismo payment_id, MISMA reserva, importe distinto → conflicto
  ---------------------------------------------------------------
  v_json := public.confirm_reservation_payment_v2(
    'stripe','ord_t1','ch_t1', v_r1, 120005,'MXN','card', NULL,NULL, NULL);
  IF v_json->>'result' = 'payment_identity_conflict'
     AND (SELECT payment_status FROM reservations WHERE id=v_r1) = 'paid'
     AND (SELECT COUNT(*) FROM refund_intents WHERE provider_payment_id='ch_t1') = 0 THEN
    v_report := v_report || 'T12 mismo payment_id + importe distinto → conflicto, sin reembolso .. PASS' || E'\n';
  ELSE
    v_report := v_report || 'T12 conflicto importe ............................... FAIL ' || v_json::text || E'\n';
  END IF;

  ---------------------------------------------------------------
  -- T13: CAPTURE_MISSING — sin attempt ni snapshot legacy
  ---------------------------------------------------------------
  v_txt := (SELECT payment_status FROM reservations WHERE id = v_r8);  -- estado previo
  v_json := public.confirm_reservation_payment_v2(
    'conekta','ord_t13','ch_t13', v_r8, 120000,'MXN','card', NULL,NULL, NULL);
  IF v_json->>'result' = 'capture_missing'
     AND (SELECT COUNT(*) FROM payment_receipts WHERE provider_payment_id='ch_t13'
            AND result='capture_missing' AND money_state='recorded') = 1     -- dinero REPRESENTADO
     AND (SELECT payment_status FROM reservations WHERE id=v_r8) = v_txt     -- reserva intacta
     AND (SELECT COUNT(*) FROM refund_intents WHERE provider_payment_id='ch_t13') = 0
     AND (SELECT COUNT(*) FROM financial_audit_logs WHERE action='capture_missing') >= 1 THEN
    v_report := v_report || 'T13 capture_missing → receipt persistente, sin reembolso automático . PASS' || E'\n';
  ELSE
    v_report := v_report || 'T13 capture_missing ................................. FAIL ' || v_json::text || E'\n';
  END IF;

  ---------------------------------------------------------------
  -- T14: intento ↔ metadata inconsistentes → conflicto de identidad
  ---------------------------------------------------------------
  v_json := public.confirm_reservation_payment_v2(
    'stripe','ord_t14','ch_t14', v_r1, 120000,'MXN','card', NULL,NULL, NULL);
  IF v_json->>'result' = 'payment_identity_conflict'
     AND (SELECT COUNT(*) FROM payment_receipts WHERE provider_payment_id='ch_t14'
            AND result='payment_identity_conflict') = 1
     AND (SELECT COUNT(*) FROM refund_intents WHERE provider_payment_id='ch_t14') = 0 THEN
    v_report := v_report || 'T14 intento↔metadata inconsistentes → conflicto auditado ............ PASS' || E'\n';
  ELSE
    v_report := v_report || 'T14 intento vs metadata ............................. FAIL ' || v_json::text || E'\n';
  END IF;

  ---------------------------------------------------------------
  -- T15: EXCEPCIÓN TÉCNICA a mitad del flujo → aborta TODO, cero
  --      efectos parciales, cero reembolsos (constraint temporal
  --      que hace fallar el INSERT del ledger; se revierte al final)
  ---------------------------------------------------------------
  ALTER TABLE wallet_transactions ADD CONSTRAINT __t15_fail CHECK (amount < 0) NOT VALID;
  BEGIN
    v_json := public.confirm_reservation_payment_v2(
      'stripe','ord_t9','ch_t9', v_r9, 120000,'MXN','card', NULL,NULL, NULL);
    v_report := v_report || 'T15 excepción técnica ............................... FAIL (no abortó)' || E'\n';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM LIKE '%__t15_fail%'
       AND (SELECT COUNT(*) FROM payment_receipts WHERE provider_payment_id='ch_t9') = 0
       AND (SELECT status FROM reservations WHERE id=v_r9) = 'pending_payment'
       AND (SELECT payment_status FROM reservations WHERE id=v_r9) = 'unpaid'
       AND (SELECT COUNT(*) FROM refund_intents WHERE provider_payment_id='ch_t9') = 0
       AND (SELECT pending_balance FROM group_wallets WHERE group_id=v_group) = 2000 THEN
      v_report := v_report || 'T15 excepción técnica → aborta TODO, sin efectos parciales .......... PASS' || E'\n';
    ELSE
      v_report := v_report || 'T15 excepción técnica ............................... FAIL ' || SQLERRM || E'\n';
    END IF;
  END;
  ALTER TABLE wallet_transactions DROP CONSTRAINT __t15_fail;

  ---------------------------------------------------------------
  -- T16: LOCK TIMEOUT — verificación estática del mecanismo
  --      (la prueba REAL requiere 2 sesiones: ver guion de 2 pestañas)
  ---------------------------------------------------------------
  IF EXISTS (SELECT 1 FROM pg_proc
             WHERE proname = 'confirm_reservation_payment_v2'
               AND prosrc LIKE '%lock_timeout%'
               AND prosrc LIKE '%lock_not_available%'
               AND prosrc LIKE '%temporary_lock_timeout%') THEN
    v_report := v_report || 'T16 lock_timeout 5s + handler → temporary_lock_timeout presente ..... PASS (real: 2 pestañas)' || E'\n';
  ELSE
    v_report := v_report || 'T16 mecanismo lock timeout .......................... FAIL' || E'\n';
  END IF;

  ---------------------------------------------------------------
  -- T17: AGREGADOS FINALES — el ledger del grupo tiene EXACTAMENTE
  --      2 créditos (T1 y T5); ninguna rama bloqueada escribió nada
  ---------------------------------------------------------------
  IF (SELECT COUNT(*) FROM wallet_transactions wt
      WHERE wt.group_id = v_group AND wt.type = 'credit_pending') = 2
     AND (SELECT pending_balance FROM group_wallets WHERE group_id = v_group) = 2000
     AND (SELECT COUNT(*) FROM refund_intents ri
          WHERE ri.reservation_id IN (v_r1,v_r2,v_r3,v_r4,v_r5,v_r6,v_r7,v_r8,v_r9)) = 6 THEN
    v_report := v_report || 'T17 ledger exacto: 2 créditos, $2000, 6 refund_intents (uno por caso) PASS' || E'\n';
  ELSE
    v_report := v_report || 'T17 agregados ....................................... FAIL' || E'\n';
  END IF;

  IF v_admin_id IS NOT NULL THEN
    SELECT COALESCE(available_balance,0) INTO v_adm FROM wallets WHERE user_id = v_admin_id;
    IF v_adm - v_adm0 = 400 THEN
      v_report := v_report || 'T17b admin: +$400 bruto (2 confirmaciones × $200, cero estimaciones) PASS' || E'\n';
    ELSE
      v_report := v_report || 'T17b admin final .................................... FAIL delta=' || (v_adm - v_adm0)::text || E'\n';
    END IF;
  END IF;

  ---------------------------------------------------------------
  -- T18: date_taken sigue activo en AMBAS capas
  ---------------------------------------------------------------
  IF (SELECT prosrc LIKE '%date_taken%' FROM pg_proc WHERE proname='enforce_group_availability')
     AND (SELECT prosrc LIKE '%date_taken_legacy%' FROM pg_proc WHERE proname='can_schedule') THEN
    v_report := v_report || 'T18 date_taken activo en trigger F1 y en can_schedule ............... PASS' || E'\n';
  ELSE
    v_report := v_report || 'T18 date_taken ...................................... FAIL' || E'\n';
  END IF;

  v_report := v_report || E'══════ FIN — todo se revierte ahora (RAISE) ══════';
  RAISE EXCEPTION '%', v_report;
END $$;
