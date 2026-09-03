-- ============================================================
-- sql/537_p1f_financial_regression_tests.sql
-- Regresión financiera completa P1F — transaccional/autorevertible
-- (mismo patrón que 520/536: DO-block que SIEMPRE termina en
-- RAISE EXCEPTION con el reporte completo → Postgres revierte TODO).
--
-- Usa un grupo temporal aislado (__TEST_P1F_537__) con wallet propia
-- que arranca en 0/0/0/0/0/0, para que las cifras esperadas sean
-- exactas y no dependan del estado de ningún grupo real.
--
-- Cubre: admin_register_group_payment, release_group_earnings_atomic,
-- confirm_full_payment_and_credit_wallet, process_refund_reversal,
-- settle_cancellation, settle_group_cancellation, resolve_dispute,
-- claims/concurrencia, group_payment_requests, withdrawals.
--
-- NO modifica ninguna función productiva. Si algo falla, el reporte
-- indica el test — la triage (defecto de test vs bug real) se hace
-- fuera de este archivo, leyendo el código fuente ya auditado.
-- ============================================================

DO $test537$
DECLARE
  -- actores
  v_admin_id UUID; v_client_id UUID; v_owner_id UUID;
  v_group_id UUID; v_wallet_id UUID;
  v_result   JSONB;
  v_report   TEXT := E'\n══════ REPORTE P1F — REGRESIÓN FINANCIERA (537) ══════\n';

  -- acumuladores de expectativa (wallet arranca en 0 en las 6 columnas)
  v_exp_pending_mxn NUMERIC := 0; v_exp_available_mxn NUMERIC := 0; v_exp_total_earned_mxn NUMERIC := 0;
  v_exp_pending_usd NUMERIC := 0; v_exp_available_usd NUMERIC := 0; v_exp_total_earned_usd NUMERIC := 0;

  -- snapshot puntual para checks aislados (guards que no deben mutar nada)
  v_snap_pending NUMERIC; v_snap_available NUMERIC; v_snap_pending_usd NUMERIC; v_snap_available_usd NUMERIC;
  v_snap_te NUMERIC; v_snap_te_usd NUMERIC;

  -- reservas — sección A
  ra5 UUID; ra6 UUID; ra_val UUID; ra15 UUID; ra1 UUID; ra2 UUID; ra3 UUID; ra4 UUID; ra7 UUID; ra8 UUID; ra9 UUID;
  da8 UUID; da9 UUID; c_a7 UUID;
  -- sección B
  rb1 UUID; rb2 UUID; rb3 UUID; rb4 UUID; rb5 UUID; rb6 UUID; rb8 UUID; rb9 UUID;
  db5 UUID; db6 UUID;
  -- sección C
  rc1 UUID; rc2 UUID; rc3 UUID; rc5 UUID;
  -- sección D
  rd1 UUID; rd2 UUID; rd3 UUID; rd4 UUID; rd5 UUID; rd6 UUID;
  c_d1 UUID; c_d2 UUID; c_d6 UUID;
  -- sección E
  re1 UUID; re2 UUID; re3 UUID; re4 UUID;
  -- sección F
  rf1 UUID; rf2 UUID; rf3 UUID; rf4 UUID; rf6 UUID; rf7 UUID;
  v_strikes_before INT; v_strikes_after INT;
  -- sección G
  rg1 UUID; rg2 UUID; rg3 UUID; rg4 UUID; rg5 UUID; rg7 UUID;
  dg1 UUID; dg2 UUID; dg3 UUID; dg4 UUID; dg5 UUID; dg7 UUID;
  -- sección H
  rh1 UUID; rh3 UUID; rh4 UUID; c_h1 UUID; c_h3 UUID;
  -- sección I
  ri1 UUID; ri3 UUID; v_req_id UUID;
  -- misc
  v_saldo NUMERIC;
BEGIN
  ------------------------------------------------------------------
  -- SETUP
  ------------------------------------------------------------------
  SELECT id INTO v_admin_id FROM profiles WHERE role = 'admin' ORDER BY created_at LIMIT 1;
  SELECT id INTO v_client_id FROM profiles WHERE role = 'client' ORDER BY created_at LIMIT 1;
  SELECT owner_id INTO v_owner_id FROM groups WHERE owner_id IS NOT NULL LIMIT 1;

  INSERT INTO groups (name, owner_id, state, country, is_active)
  VALUES ('__TEST_P1F_537__', v_owner_id, 'Jalisco', 'México', false)
  RETURNING id INTO v_group_id;

  PERFORM ensure_group_wallet(v_group_id);
  SELECT id INTO v_wallet_id FROM group_wallets WHERE group_id = v_group_id;

  -- owner SIN datos bancarios al inicio (necesario para A15)
  UPDATE wallets SET bank_clabe = NULL, bank_name = NULL, account_holder = NULL, bank_linked_at = NULL
  WHERE user_id = v_owner_id;

  -- contexto de admin para auth.uid() dentro de admin_register_group_payment,
  -- claim_reservation_refund, etc. (faltaba en la corrida anterior — causó
  -- fallos en cascada 'not_admin' en toda la sección A; NO es un bug real).
  PERFORM set_config('request.jwt.claim.sub', v_admin_id::text, true);

  ------------------------------------------------------------------
  -- SECCIÓN A: admin_register_group_payment
  ------------------------------------------------------------------

  -- A5: moneda inválida
  INSERT INTO reservations (group_id, client_id, event_date, address, total_price, base_price, payment_status, payout_status, status, group_earnings, currency_code)
  VALUES (v_group_id, v_client_id, CURRENT_DATE+1, 'T', 1200, 1000, 'paid', 'held', 'confirmed', 1000, NULL) RETURNING id INTO ra5;
  v_result := admin_register_group_payment(ra5, 100, 'advance', 'r.jpg', NULL, NULL, NOW());
  v_report := v_report || format('A5_moneda_invalida: %s (error=%s)\n', (v_result->>'error')='unsupported_currency', v_result->>'error');

  -- A6: status inválido (advance sobre reserva en 'pending')
  INSERT INTO reservations (group_id, client_id, event_date, address, total_price, base_price, payment_status, payout_status, status, group_earnings, currency_code)
  VALUES (v_group_id, v_client_id, CURRENT_DATE+2, 'T', 1200, 1000, 'paid', 'held', 'pending', 1000, 'MXN') RETURNING id INTO ra6;
  v_result := admin_register_group_payment(ra6, 100, 'advance', 'r.jpg', NULL, NULL, NOW());
  v_report := v_report || format('A6_status_invalido: %s (error=%s)\n', (v_result->>'error')='reservation_status_not_eligible', v_result->>'error');

  -- A12/A13/A14: validaciones de forma (short-circuit antes del lookup de reserva)
  INSERT INTO reservations (group_id, client_id, event_date, address, total_price, base_price, payment_status, payout_status, status, group_earnings, currency_code)
  VALUES (v_group_id, v_client_id, CURRENT_DATE+3, 'T', 1200, 1000, 'paid', 'held', 'confirmed', 1000, 'MXN') RETURNING id INTO ra_val;

  v_result := admin_register_group_payment(ra_val, 100, 'advance', 'r.jpg', NULL, NULL, NULL);
  v_report := v_report || format('A12_transferred_at_requerido: %s (error=%s)\n', (v_result->>'error')='transferred_at_required', v_result->>'error');

  v_result := admin_register_group_payment(ra_val, 100, 'advance', NULL, NULL, NULL, NOW());
  v_report := v_report || format('A13_comprobante_requerido: %s (error=%s)\n', (v_result->>'error')='receipt_required', v_result->>'error');

  v_result := admin_register_group_payment(ra_val, 100, 'final_settlement', 'r.jpg', NULL, NULL, NOW());
  v_report := v_report || format('A14_transfer_reference_requerido: %s (error=%s)\n', (v_result->>'error')='transfer_reference_required', v_result->>'error');

  -- A15: missing_bank_data (owner sin datos bancarios, final_settlement exacto)
  INSERT INTO reservations (group_id, client_id, event_date, address, total_price, base_price, payment_status, payout_status, status, group_earnings, currency_code)
  VALUES (v_group_id, v_client_id, CURRENT_DATE+4, 'T', 1200, 1000, 'paid', 'released', 'completed', 1000, 'MXN') RETURNING id INTO ra15;
  v_result := admin_register_group_payment(ra15, 1000, 'final_settlement', 'r.jpg', NULL, 'REF-A15', NOW());
  v_report := v_report || format('A15_missing_bank_data: %s (error=%s)\n', (v_result->>'error')='missing_bank_data', v_result->>'error');

  -- ahora sí, datos bancarios del owner (necesarios para A3/A4/I1-3/J3-4)
  UPDATE wallets SET bank_clabe='123456789012345678', bank_name='BBVA', account_holder='Grupo Test 537', bank_linked_at=NOW()
  WHERE user_id = v_owner_id;

  -- A1: advance MXN — ruteado por confirm_full_payment_and_credit_wallet
  -- para que el wallet REALMENTE tenga saldo (admin_register_group_payment
  -- valida el saldo del bucket, no solo group_earnings — un insert crudo
  -- con group_earnings=10000 pero pending_balance=0 falla insufficient_wallet_bucket).
  INSERT INTO reservations (group_id, client_id, event_date, address, total_price, base_price, payment_status, payout_status, status, currency_code)
  VALUES (v_group_id, v_client_id, CURRENT_DATE+5, 'T', 12000, 10000, 'pending_payment', 'pending', 'confirmed', 'MXN') RETURNING id INTO ra1;
  v_result := confirm_full_payment_and_credit_wallet(ra1, 'test-a1', NULL, NULL);
  v_exp_pending_mxn := v_exp_pending_mxn + 10000; v_exp_total_earned_mxn := v_exp_total_earned_mxn + 10000;
  v_result := admin_register_group_payment(ra1, 4000, 'advance', 'r.jpg', NULL, NULL, NOW());
  v_exp_pending_mxn := v_exp_pending_mxn - 4000;
  v_report := v_report || format('A1_advance_mxn: %s (bucket=%s currency=%s)\n', (v_result->>'ok')::boolean, v_result->>'bucket_debitado', v_result->>'currency');

  -- A11: exceso rechazado (4000 ya pagado + 7000 > 10000 de group_earnings)
  v_result := admin_register_group_payment(ra1, 7000, 'advance', 'r.jpg', NULL, NULL, NOW());
  v_report := v_report || format('A11_exceso_rechazado: %s (error=%s)\n', (v_result->>'error')='exceeds_group_earnings', v_result->>'error');

  -- A7: refund_in_progress (claim activo bloquea nuevo advance) — reserva
  -- PROPIA, sin anticipo previo: si reusara ra1 (que A1 ya le registró un
  -- anticipo), claim_reservation_refund vería v_ya_transferido>0 y
  -- rechazaría con manual_payment_already_transferred en vez de crear el
  -- claim (mismo guard, otra rama) — nunca llegaríamos a probar esta.
  INSERT INTO reservations (group_id, client_id, event_date, address, total_price, base_price, payment_status, payout_status, status, currency_code)
  VALUES (v_group_id, v_client_id, CURRENT_DATE+53, 'T', 2400, 2000, 'pending_payment', 'pending', 'confirmed', 'MXN') RETURNING id INTO ra7;
  v_result := confirm_full_payment_and_credit_wallet(ra7, 'test-a7', NULL, NULL);
  v_exp_pending_mxn := v_exp_pending_mxn + 2000; v_exp_total_earned_mxn := v_exp_total_earned_mxn + 2000;
  v_result := claim_reservation_refund(ra7, 'full', 2400, 'stripe', 'pi_a7');
  c_a7 := (v_result->>'claim_id')::uuid;
  v_result := admin_register_group_payment(ra7, 1000, 'advance', 'r.jpg', NULL, NULL, NOW());
  v_report := v_report || format('A7_refund_in_progress: %s (error=%s)\n', (v_result->>'error')='refund_in_progress', v_result->>'error');

  -- A8: disputa OPEN bloquea advance
  INSERT INTO reservations (group_id, client_id, event_date, address, total_price, base_price, payment_status, payout_status, status, group_earnings, currency_code)
  VALUES (v_group_id, v_client_id, CURRENT_DATE+6, 'T', 6000, 5000, 'paid', 'held', 'confirmed', 5000, 'MXN') RETURNING id INTO ra8;
  INSERT INTO disputes (reservation_id, opened_by, status, reason) VALUES (ra8, v_client_id, 'open', 'test A8') RETURNING id INTO da8;
  v_result := admin_register_group_payment(ra8, 1000, 'advance', 'r.jpg', NULL, NULL, NOW());
  v_report := v_report || format('A8_disputa_open_bloquea: %s (error=%s)\n', (v_result->>'error')='open_dispute_blocks_payment', v_result->>'error');

  -- A9: disputa UNDER_REVIEW bloquea advance
  INSERT INTO reservations (group_id, client_id, event_date, address, total_price, base_price, payment_status, payout_status, status, group_earnings, currency_code)
  VALUES (v_group_id, v_client_id, CURRENT_DATE+7, 'T', 6000, 5000, 'paid', 'held', 'confirmed', 5000, 'MXN') RETURNING id INTO ra9;
  INSERT INTO disputes (reservation_id, opened_by, status, reason) VALUES (ra9, v_client_id, 'under_review', 'test A9') RETURNING id INTO da9;
  v_result := admin_register_group_payment(ra9, 1000, 'advance', 'r.jpg', NULL, NULL, NOW());
  v_report := v_report || format('A9_disputa_under_review_bloquea: %s (error=%s)\n', (v_result->>'error')='open_dispute_blocks_payment', v_result->>'error');

  -- A2: advance USD — mismo fix que A1
  INSERT INTO reservations (group_id, client_id, event_date, address, total_price, base_price, payment_status, payout_status, status, currency_code)
  VALUES (v_group_id, v_client_id, CURRENT_DATE+8, 'T', 600, 500, 'pending_payment', 'pending', 'confirmed', 'USD') RETURNING id INTO ra2;
  v_result := confirm_full_payment_and_credit_wallet(ra2, 'test-a2', NULL, NULL);
  v_exp_pending_usd := v_exp_pending_usd + 500; v_exp_total_earned_usd := v_exp_total_earned_usd + 500;
  v_result := admin_register_group_payment(ra2, 200, 'advance', 'r.jpg', NULL, NULL, NOW());
  v_exp_pending_usd := v_exp_pending_usd - 200;
  v_report := v_report || format('A2_advance_usd: %s (bucket=%s currency=%s)\n', (v_result->>'ok')::boolean, v_result->>'bucket_debitado', v_result->>'currency');

  -- A3: camino REAL completo MXN — pagó → pending → llegada → release → available → final exacto
  INSERT INTO reservations (group_id, client_id, event_date, address, total_price, base_price, payment_status, payout_status, status, currency_code)
  VALUES (v_group_id, v_client_id, CURRENT_DATE+9, 'T', 10800, 9000, 'pending_payment', 'pending', 'confirmed', 'MXN') RETURNING id INTO ra3;
  v_result := confirm_full_payment_and_credit_wallet(ra3, 'test-a3', NULL, NULL);
  v_exp_pending_mxn := v_exp_pending_mxn + 9000; v_exp_total_earned_mxn := v_exp_total_earned_mxn + 9000;
  v_result := admin_register_group_payment(ra3, 3000, 'advance', 'r.jpg', NULL, NULL, NOW());
  v_exp_pending_mxn := v_exp_pending_mxn - 3000;
  UPDATE reservations SET status='completed', group_arrived_at = NOW() WHERE id = ra3;
  v_result := release_group_earnings_atomic(ra3, v_admin_id);  -- to_release = 9000-3000 = 6000
  v_exp_pending_mxn := v_exp_pending_mxn - 6000; v_exp_available_mxn := v_exp_available_mxn + 6000;
  SELECT group_earnings - COALESCE((SELECT SUM(amount) FROM group_reservation_payments WHERE reservation_id=ra3),0) INTO v_saldo FROM reservations WHERE id=ra3;
  -- A10b: monto MENOR al saldo restante (6000) rechazado
  v_result := admin_register_group_payment(ra3, 5000, 'final_settlement', 'r.jpg', NULL, 'REF-A10B', NOW());
  v_report := v_report || format('A10b_monto_final_menor_rechazado: %s (error=%s saldo=%s)\n', (v_result->>'error')='final_amount_must_match_balance', v_result->>'error', v_saldo::text);
  -- A3: monto exacto pasa
  v_result := admin_register_group_payment(ra3, v_saldo, 'final_settlement', 'r.jpg', NULL, 'REF-A3', NOW());
  v_exp_available_mxn := v_exp_available_mxn - v_saldo;
  v_report := v_report || format('A3_final_mxn_camino_real: %s (bucket=%s currency=%s saldo_final=%s)\n', (v_result->>'ok')::boolean, v_result->>'bucket_debitado', v_result->>'currency', v_result->>'saldo_restante');

  -- A4: camino REAL completo USD
  INSERT INTO reservations (group_id, client_id, event_date, address, total_price, base_price, payment_status, payout_status, status, currency_code)
  VALUES (v_group_id, v_client_id, CURRENT_DATE+10, 'T', 1080, 900, 'pending_payment', 'pending', 'confirmed', 'USD') RETURNING id INTO ra4;
  v_result := confirm_full_payment_and_credit_wallet(ra4, 'test-a4', NULL, NULL);
  v_exp_pending_usd := v_exp_pending_usd + 900; v_exp_total_earned_usd := v_exp_total_earned_usd + 900;
  v_result := admin_register_group_payment(ra4, 300, 'advance', 'r.jpg', NULL, NULL, NOW());
  v_exp_pending_usd := v_exp_pending_usd - 300;
  UPDATE reservations SET status='completed', group_arrived_at = NOW() WHERE id = ra4;
  v_result := release_group_earnings_atomic(ra4, v_admin_id);  -- to_release = 900-300 = 600
  v_exp_pending_usd := v_exp_pending_usd - 600; v_exp_available_usd := v_exp_available_usd + 600;
  v_result := admin_register_group_payment(ra4, 600, 'final_settlement', 'r.jpg', NULL, 'REF-A4', NOW());
  v_exp_available_usd := v_exp_available_usd - 600;
  v_report := v_report || format('A4_final_usd_camino_real: %s (bucket=%s currency=%s)\n', (v_result->>'ok')::boolean, v_result->>'bucket_debitado', v_result->>'currency');

  ------------------------------------------------------------------
  -- SECCIÓN B: release_group_earnings_atomic
  ------------------------------------------------------------------

  -- B1: MXN, 0 anticipos
  INSERT INTO reservations (group_id, client_id, event_date, address, total_price, base_price, payment_status, payout_status, status, currency_code)
  VALUES (v_group_id, v_client_id, CURRENT_DATE+12, 'T', 4800, 4000, 'pending_payment', 'pending', 'confirmed', 'MXN') RETURNING id INTO rb1;
  v_result := confirm_full_payment_and_credit_wallet(rb1, 'test-b1', NULL, NULL);
  v_exp_pending_mxn := v_exp_pending_mxn + 4000; v_exp_total_earned_mxn := v_exp_total_earned_mxn + 4000;
  UPDATE reservations SET status='completed', group_arrived_at = NOW() WHERE id = rb1;
  v_result := release_group_earnings_atomic(rb1, v_admin_id);
  v_exp_pending_mxn := v_exp_pending_mxn - 4000; v_exp_available_mxn := v_exp_available_mxn + 4000;
  v_report := v_report || format('B1_release_mxn_0_anticipos: %s (released=%s) wt_rows=%s\n',
    (v_result->>'ok')::boolean AND (v_result->>'released')::numeric = 4000, v_result->>'released',
    (SELECT COUNT(*) FROM wallet_transactions WHERE reservation_id=rb1 AND type='credit_available'));

  -- B2: USD, 0 anticipos
  INSERT INTO reservations (group_id, client_id, event_date, address, total_price, base_price, payment_status, payout_status, status, currency_code)
  VALUES (v_group_id, v_client_id, CURRENT_DATE+13, 'T', 480, 400, 'pending_payment', 'pending', 'confirmed', 'USD') RETURNING id INTO rb2;
  v_result := confirm_full_payment_and_credit_wallet(rb2, 'test-b2', NULL, NULL);
  v_exp_pending_usd := v_exp_pending_usd + 400; v_exp_total_earned_usd := v_exp_total_earned_usd + 400;
  UPDATE reservations SET status='completed', group_arrived_at = NOW() WHERE id = rb2;
  v_result := release_group_earnings_atomic(rb2, v_admin_id);
  v_exp_pending_usd := v_exp_pending_usd - 400; v_exp_available_usd := v_exp_available_usd + 400;
  v_report := v_report || format('B2_release_usd_0_anticipos: %s (released=%s)\n', (v_result->>'ok')::boolean AND (v_result->>'released')::numeric = 400, v_result->>'released');

  -- B3: moneda inválida — CON llegada válida, para llegar realmente al guard de moneda
  INSERT INTO reservations (group_id, client_id, event_date, address, total_price, payment_status, payout_status, status, group_earnings, currency_code, group_arrived_at)
  VALUES (v_group_id, v_client_id, CURRENT_DATE+50, 'T', 1200, 'paid', 'held', 'completed', 1000, NULL, NOW()) RETURNING id INTO rb3;
  SELECT pending_balance, available_balance, pending_balance_usd, available_balance_usd, total_earned, total_earned_usd
  INTO v_snap_pending, v_snap_available, v_snap_pending_usd, v_snap_available_usd, v_snap_te, v_snap_te_usd
  FROM group_wallets WHERE id = v_wallet_id;
  v_result := release_group_earnings_atomic(rb3, v_admin_id);
  v_report := v_report || format('B3_moneda_invalida_con_llegada: %s (error=%s) wallet_sin_cambio=%s\n',
    (v_result->>'error')='unsupported_currency', v_result->>'error',
    (SELECT pending_balance=v_snap_pending AND available_balance=v_snap_available AND pending_balance_usd=v_snap_pending_usd
            AND available_balance_usd=v_snap_available_usd AND total_earned=v_snap_te AND total_earned_usd=v_snap_te_usd
     FROM group_wallets WHERE id=v_wallet_id));

  -- B4: llegada NO verificada → skip, sin mover wallet
  INSERT INTO reservations (group_id, client_id, event_date, address, total_price, payment_status, payout_status, status, group_earnings, currency_code)
  VALUES (v_group_id, v_client_id, CURRENT_DATE+51, 'T', 1200, 'paid', 'held', 'completed', 1000, 'MXN') RETURNING id INTO rb4;
  v_result := release_group_earnings_atomic(rb4, v_admin_id);
  v_report := v_report || format('B4_llegada_no_verificada: %s (skipped=%s reason=%s)\n', (v_result->>'skipped')='true', v_result->>'skipped', v_result->>'reason');

  -- B5: disputa OPEN bloquea release (aun con llegada válida)
  INSERT INTO reservations (group_id, client_id, event_date, address, total_price, payment_status, payout_status, status, group_earnings, currency_code, group_arrived_at)
  VALUES (v_group_id, v_client_id, CURRENT_DATE+16, 'T', 1200, 'paid', 'held', 'completed', 1000, 'MXN', NOW()) RETURNING id INTO rb5;
  INSERT INTO disputes (reservation_id, opened_by, status, reason) VALUES (rb5, v_client_id, 'open', 'test B5') RETURNING id INTO db5;
  v_result := release_group_earnings_atomic(rb5, v_admin_id);
  v_report := v_report || format('B5_disputa_open_bloquea_release: %s (error=%s)\n', (v_result->>'error')='open_dispute_blocks_release', v_result->>'error');

  -- B6: disputa UNDER_REVIEW bloquea release
  INSERT INTO reservations (group_id, client_id, event_date, address, total_price, payment_status, payout_status, status, group_earnings, currency_code, group_arrived_at)
  VALUES (v_group_id, v_client_id, CURRENT_DATE+17, 'T', 1200, 'paid', 'held', 'completed', 1000, 'MXN', NOW()) RETURNING id INTO rb6;
  INSERT INTO disputes (reservation_id, opened_by, status, reason) VALUES (rb6, v_client_id, 'under_review', 'test B6') RETURNING id INTO db6;
  v_result := release_group_earnings_atomic(rb6, v_admin_id);
  v_report := v_report || format('B6_disputa_under_review_bloquea_release: %s (error=%s)\n', (v_result->>'error')='open_dispute_blocks_release', v_result->>'error');

  -- B8: anticipo PARCIAL reduce el monto liberado
  INSERT INTO reservations (group_id, client_id, event_date, address, total_price, base_price, payment_status, payout_status, status, currency_code)
  VALUES (v_group_id, v_client_id, CURRENT_DATE+18, 'T', 7200, 6000, 'pending_payment', 'pending', 'confirmed', 'MXN') RETURNING id INTO rb8;
  v_result := confirm_full_payment_and_credit_wallet(rb8, 'test-b8', NULL, NULL);
  v_exp_pending_mxn := v_exp_pending_mxn + 6000; v_exp_total_earned_mxn := v_exp_total_earned_mxn + 6000;
  v_result := admin_register_group_payment(rb8, 2500, 'advance', 'r.jpg', NULL, NULL, NOW());
  v_exp_pending_mxn := v_exp_pending_mxn - 2500;
  UPDATE reservations SET status='completed', group_arrived_at = NOW() WHERE id = rb8;
  v_result := release_group_earnings_atomic(rb8, v_admin_id);  -- to_release = 6000-2500 = 3500
  v_exp_pending_mxn := v_exp_pending_mxn - 3500; v_exp_available_mxn := v_exp_available_mxn + 3500;
  v_report := v_report || format('B8_anticipo_parcial: %s (released=%s esperado=3500)\n', (v_result->>'released')::numeric = 3500, v_result->>'released');

  -- B9: 100% anticipado → to_release=0, SIN wallet_transaction de monto 0
  INSERT INTO reservations (group_id, client_id, event_date, address, total_price, base_price, payment_status, payout_status, status, currency_code)
  VALUES (v_group_id, v_client_id, CURRENT_DATE+19, 'T', 1800, 1500, 'pending_payment', 'pending', 'confirmed', 'MXN') RETURNING id INTO rb9;
  v_result := confirm_full_payment_and_credit_wallet(rb9, 'test-b9', NULL, NULL);
  v_exp_pending_mxn := v_exp_pending_mxn + 1500; v_exp_total_earned_mxn := v_exp_total_earned_mxn + 1500;
  v_result := admin_register_group_payment(rb9, 1500, 'advance', 'r.jpg', NULL, NULL, NOW());
  v_exp_pending_mxn := v_exp_pending_mxn - 1500;
  UPDATE reservations SET status='completed', group_arrived_at = NOW() WHERE id = rb9;
  v_result := release_group_earnings_atomic(rb9, v_admin_id);
  v_report := v_report || format('B9_100pct_anticipado_release_0_sin_wt: %s (ok=%s released=%s payout_status=%s wt_credit_available_rows=%s)\n',
    (v_result->>'ok')::boolean AND COALESCE((v_result->>'released')::numeric,0)=0
      AND (SELECT payout_status FROM reservations WHERE id=rb9)='released'
      AND (SELECT COUNT(*) FROM wallet_transactions WHERE reservation_id=rb9 AND type='credit_available')=0,
    v_result->>'ok', v_result->>'released',
    (SELECT payout_status FROM reservations WHERE id=rb9),
    (SELECT COUNT(*) FROM wallet_transactions WHERE reservation_id=rb9 AND type='credit_available'));

  ------------------------------------------------------------------
  -- SECCIÓN C: confirm_full_payment_and_credit_wallet
  ------------------------------------------------------------------

  -- C1: MXN acredita EXCLUSIVAMENTE buckets MXN
  INSERT INTO reservations (group_id, client_id, event_date, address, total_price, base_price, payment_status, payout_status, status, currency_code)
  VALUES (v_group_id, v_client_id, CURRENT_DATE+20, 'T', 2640, 2200, 'pending_payment', 'pending', 'confirmed', 'MXN') RETURNING id INTO rc1;
  SELECT pending_balance, available_balance, pending_balance_usd, available_balance_usd, total_earned, total_earned_usd
  INTO v_snap_pending, v_snap_available, v_snap_pending_usd, v_snap_available_usd, v_snap_te, v_snap_te_usd
  FROM group_wallets WHERE id=v_wallet_id;
  v_result := confirm_full_payment_and_credit_wallet(rc1, 'test-c1', NULL, NULL);
  v_exp_pending_mxn := v_exp_pending_mxn + 2200; v_exp_total_earned_mxn := v_exp_total_earned_mxn + 2200;
  v_report := v_report || format('C1_mxn_solo_buckets_mxn: %s (earnings=%s pending_delta=%s usd_intacto=%s)\n',
    (v_result->>'ok')::boolean AND (v_result->>'group_earnings')::numeric=2200,
    v_result->>'group_earnings',
    (SELECT pending_balance FROM group_wallets WHERE id=v_wallet_id) - v_snap_pending,
    (SELECT pending_balance_usd=v_snap_pending_usd AND available_balance_usd=v_snap_available_usd AND total_earned_usd=v_snap_te_usd FROM group_wallets WHERE id=v_wallet_id));

  -- C2: USD acredita EXCLUSIVAMENTE buckets USD
  INSERT INTO reservations (group_id, client_id, event_date, address, total_price, base_price, payment_status, payout_status, status, currency_code)
  VALUES (v_group_id, v_client_id, CURRENT_DATE+21, 'T', 300, 250, 'pending_payment', 'pending', 'confirmed', 'USD') RETURNING id INTO rc2;
  SELECT pending_balance, available_balance, pending_balance_usd, available_balance_usd, total_earned, total_earned_usd
  INTO v_snap_pending, v_snap_available, v_snap_pending_usd, v_snap_available_usd, v_snap_te, v_snap_te_usd
  FROM group_wallets WHERE id=v_wallet_id;
  v_result := confirm_full_payment_and_credit_wallet(rc2, 'test-c2', NULL, NULL);
  v_exp_pending_usd := v_exp_pending_usd + 250; v_exp_total_earned_usd := v_exp_total_earned_usd + 250;
  v_report := v_report || format('C2_usd_solo_buckets_usd: %s (earnings=%s pending_usd_delta=%s mxn_intacto=%s)\n',
    (v_result->>'ok')::boolean AND (v_result->>'group_earnings')::numeric=250,
    v_result->>'group_earnings',
    (SELECT pending_balance_usd FROM group_wallets WHERE id=v_wallet_id) - v_snap_pending_usd,
    (SELECT pending_balance=v_snap_pending AND available_balance=v_snap_available AND total_earned=v_snap_te FROM group_wallets WHERE id=v_wallet_id));

  -- C3: moneda no soportada → RAISE EXCEPTION (no jsonb ok:false), sin mutación
  INSERT INTO reservations (group_id, client_id, event_date, address, total_price, base_price, payment_status, payout_status, status, currency_code)
  VALUES (v_group_id, v_client_id, CURRENT_DATE+22, 'T', 1200, 1000, 'pending_payment', 'pending', 'confirmed', NULL) RETURNING id INTO rc3;
  SELECT pending_balance, available_balance, pending_balance_usd, available_balance_usd, total_earned, total_earned_usd
  INTO v_snap_pending, v_snap_available, v_snap_pending_usd, v_snap_available_usd, v_snap_te, v_snap_te_usd
  FROM group_wallets WHERE id=v_wallet_id;
  BEGIN
    v_result := confirm_full_payment_and_credit_wallet(rc3, 'test-c3', NULL, NULL);
    v_report := v_report || 'C3_moneda_no_soportada: FAIL (no lanzó excepción)' || E'\n';
  EXCEPTION WHEN OTHERS THEN
    v_report := v_report || format('C3_moneda_no_soportada: %s (mensaje=%s) wallet_sin_cambio=%s\n',
      SQLERRM LIKE '%moneda%sin wallet autorizada%', SQLERRM,
      (SELECT pending_balance=v_snap_pending AND available_balance=v_snap_available AND pending_balance_usd=v_snap_pending_usd
              AND available_balance_usd=v_snap_available_usd AND total_earned=v_snap_te AND total_earned_usd=v_snap_te_usd
       FROM group_wallets WHERE id=v_wallet_id));
  END;

  -- C5 (bonus): pago tardío de reserva cancelada → bloqueado, sin acreditar wallet
  INSERT INTO reservations (group_id, client_id, event_date, address, total_price, base_price, payment_status, payout_status, status, currency_code)
  VALUES (v_group_id, v_client_id, CURRENT_DATE+23, 'T', 960, 800, 'pending_payment', 'pending', 'cancelled', 'MXN') RETURNING id INTO rc5;
  SELECT pending_balance INTO v_saldo FROM group_wallets WHERE id=v_wallet_id;
  v_result := confirm_full_payment_and_credit_wallet(rc5, 'test-c5', NULL, NULL);
  v_report := v_report || format('C5_pago_tardio_reserva_cancelada_bloqueado: %s (ok=%s blocked=%s payout_status=%s pending_sin_cambio=%s)\n',
    (v_result->>'ok')='false' AND (v_result->>'blocked')='true' AND (SELECT payout_status FROM reservations WHERE id=rc5)='blocked'
      AND (SELECT pending_balance FROM group_wallets WHERE id=v_wallet_id) = v_saldo,
    v_result->>'ok', v_result->>'blocked', (SELECT payout_status FROM reservations WHERE id=rc5),
    (SELECT pending_balance FROM group_wallets WHERE id=v_wallet_id) = v_saldo);

  ------------------------------------------------------------------
  -- SECCIÓN D: process_refund_reversal
  ------------------------------------------------------------------

  -- D1: refund completo MXN, con claim válido
  INSERT INTO reservations (group_id, client_id, event_date, address, total_price, base_price, payment_status, payout_status, status, currency_code)
  VALUES (v_group_id, v_client_id, CURRENT_DATE+24, 'T', 2160, 1800, 'pending_payment', 'pending', 'confirmed', 'MXN') RETURNING id INTO rd1;
  v_result := confirm_full_payment_and_credit_wallet(rd1, 'test-d1', NULL, NULL);
  v_exp_pending_mxn := v_exp_pending_mxn + 1800; v_exp_total_earned_mxn := v_exp_total_earned_mxn + 1800;
  v_result := claim_reservation_refund(rd1, 'full', 2160, 'stripe', 'pi_d1');
  c_d1 := (v_result->>'claim_id')::uuid;
  v_result := process_refund_reversal(rd1, 'rf_d1', 2160, c_d1);
  v_exp_pending_mxn := v_exp_pending_mxn - 1800; v_exp_total_earned_mxn := v_exp_total_earned_mxn - 1800;
  v_report := v_report || format('D1_refund_completo_mxn: %s (reversed=%s currency=%s claim_done=%s)\n',
    (v_result->>'ok')::boolean AND (v_result->>'reversed')::numeric=1800,
    v_result->>'reversed', v_result->>'currency',
    (SELECT status='done' FROM provider_refund_claims WHERE id=c_d1));

  -- D2: refund completo USD
  INSERT INTO reservations (group_id, client_id, event_date, address, total_price, base_price, payment_status, payout_status, status, currency_code)
  VALUES (v_group_id, v_client_id, CURRENT_DATE+25, 'T', 264, 220, 'pending_payment', 'pending', 'confirmed', 'USD') RETURNING id INTO rd2;
  v_result := confirm_full_payment_and_credit_wallet(rd2, 'test-d2', NULL, NULL);
  v_exp_pending_usd := v_exp_pending_usd + 220; v_exp_total_earned_usd := v_exp_total_earned_usd + 220;
  v_result := claim_reservation_refund(rd2, 'full', 264, 'stripe', 'pi_d2');
  c_d2 := (v_result->>'claim_id')::uuid;
  v_result := process_refund_reversal(rd2, 'rf_d2', 264, c_d2);
  v_exp_pending_usd := v_exp_pending_usd - 220; v_exp_total_earned_usd := v_exp_total_earned_usd - 220;
  v_report := v_report || format('D2_refund_completo_usd: %s (reversed=%s currency=%s claim_done=%s)\n',
    (v_result->>'ok')::boolean AND (v_result->>'reversed')::numeric=220,
    v_result->>'reversed', v_result->>'currency',
    (SELECT status='done' FROM provider_refund_claims WHERE id=c_d2));

  -- D3: partial_refund_not_supported
  INSERT INTO reservations (group_id, client_id, event_date, address, total_price, base_price, payment_status, payout_status, status, currency_code)
  VALUES (v_group_id, v_client_id, CURRENT_DATE+26, 'T', 600, 500, 'pending_payment', 'pending', 'confirmed', 'MXN') RETURNING id INTO rd3;
  v_result := confirm_full_payment_and_credit_wallet(rd3, 'test-d3', NULL, NULL);
  v_exp_pending_mxn := v_exp_pending_mxn + 500; v_exp_total_earned_mxn := v_exp_total_earned_mxn + 500;
  v_result := process_refund_reversal(rd3, 'rf_d3', 300, NULL);
  v_report := v_report || format('D3_partial_refund_not_supported: %s (error=%s)\n', (v_result->>'error')='partial_refund_not_supported', v_result->>'error');
  -- rd3 queda con 500 acreditados y sin revertir — lo dejamos así (no forma parte del cierre de invariantes de otra sección)
  -- para no contaminar cifras: lo revertimos limpio con el monto correcto
  v_result := process_refund_reversal(rd3, 'rf_d3', 600, NULL);
  v_exp_pending_mxn := v_exp_pending_mxn - 500; v_exp_total_earned_mxn := v_exp_total_earned_mxn - 500;

  -- D4: manual_payment_already_transferred
  INSERT INTO reservations (group_id, client_id, event_date, address, total_price, base_price, payment_status, payout_status, status, currency_code)
  VALUES (v_group_id, v_client_id, CURRENT_DATE+27, 'T', 840, 700, 'pending_payment', 'pending', 'confirmed', 'MXN') RETURNING id INTO rd4;
  v_result := confirm_full_payment_and_credit_wallet(rd4, 'test-d4', NULL, NULL);
  v_exp_pending_mxn := v_exp_pending_mxn + 700; v_exp_total_earned_mxn := v_exp_total_earned_mxn + 700;
  v_result := admin_register_group_payment(rd4, 300, 'advance', 'r.jpg', NULL, NULL, NOW());
  v_exp_pending_mxn := v_exp_pending_mxn - 300;
  v_result := process_refund_reversal(rd4, 'rf_d4', 840, NULL);
  v_report := v_report || format('D4_manual_payment_already_transferred: %s (error=%s amount=%s)\n',
    (v_result->>'error')='manual_payment_already_transferred', v_result->>'error', v_result->>'amount_already_paid');

  -- D5: disputa abierta — OBSERVACIÓN de comportamiento real (no hay guard de disputa
  -- en el código fuente de process_refund_reversal, verificado leyendo 535c). Se reporta
  -- el resultado real, sin asumir que "debería" bloquear.
  INSERT INTO reservations (group_id, client_id, event_date, address, total_price, base_price, payment_status, payout_status, status, currency_code)
  VALUES (v_group_id, v_client_id, CURRENT_DATE+28, 'T', 480, 400, 'pending_payment', 'pending', 'confirmed', 'MXN') RETURNING id INTO rd5;
  v_result := confirm_full_payment_and_credit_wallet(rd5, 'test-d5', NULL, NULL);
  v_exp_pending_mxn := v_exp_pending_mxn + 400; v_exp_total_earned_mxn := v_exp_total_earned_mxn + 400;
  INSERT INTO disputes (reservation_id, opened_by, status, reason) VALUES (rd5, v_client_id, 'open', 'test D5') RETURNING id INTO dg1; -- id reutilizado solo como var temporal
  v_result := process_refund_reversal(rd5, 'rf_d5', 480, NULL);
  IF (v_result->>'ok')::boolean THEN
    v_exp_pending_mxn := v_exp_pending_mxn - 400; v_exp_total_earned_mxn := v_exp_total_earned_mxn - 400;
  END IF;
  v_report := v_report || format('D5_OBSERVACION_disputa_abierta_no_bloquea_refund_reversal: ok=%s error=%s (sin guard de disputa en el código — revisar si es intencional)\n', v_result->>'ok', v_result->>'error');

  -- D6: p_claim_id con estado provider_succeeded (simula el paso que hará el Edge Function)
  INSERT INTO reservations (group_id, client_id, event_date, address, total_price, base_price, payment_status, payout_status, status, currency_code)
  VALUES (v_group_id, v_client_id, CURRENT_DATE+29, 'T', 360, 300, 'pending_payment', 'pending', 'confirmed', 'MXN') RETURNING id INTO rd6;
  v_result := confirm_full_payment_and_credit_wallet(rd6, 'test-d6', NULL, NULL);
  v_exp_pending_mxn := v_exp_pending_mxn + 300; v_exp_total_earned_mxn := v_exp_total_earned_mxn + 300;
  v_result := claim_reservation_refund(rd6, 'full', 360, 'stripe', 'pi_d6');
  c_d6 := (v_result->>'claim_id')::uuid;
  UPDATE provider_refund_claims SET status='provider_succeeded', updated_at=NOW() WHERE id=c_d6;
  v_result := process_refund_reversal(rd6, 'rf_d6', 360, c_d6);
  v_exp_pending_mxn := v_exp_pending_mxn - 300; v_exp_total_earned_mxn := v_exp_total_earned_mxn - 300;
  v_report := v_report || format('D6_claim_provider_succeeded_a_done: %s (ok=%s claim_status_final=%s)\n',
    (v_result->>'ok')::boolean AND (SELECT status FROM provider_refund_claims WHERE id=c_d6)='done',
    v_result->>'ok', (SELECT status FROM provider_refund_claims WHERE id=c_d6));

  ------------------------------------------------------------------
  -- SECCIÓN E: settle_cancellation (tier partial_10: días=10 → grp 7%, plat 3%)
  ------------------------------------------------------------------

  -- E1: MXN
  INSERT INTO reservations (group_id, client_id, event_date, address, total_price, base_price, payment_status, payout_status, status, currency_code)
  VALUES (v_group_id, v_client_id, CURRENT_DATE+11, 'T', 3600, 3000, 'pending_payment', 'pending', 'confirmed', 'MXN') RETURNING id INTO re1;
  v_result := confirm_full_payment_and_credit_wallet(re1, 'test-e1', NULL, NULL);
  v_exp_pending_mxn := v_exp_pending_mxn + 3000; v_exp_total_earned_mxn := v_exp_total_earned_mxn + 3000;
  v_result := settle_cancellation(re1, NULL, 'client_cancelled', NULL);
  -- charge sobre total_price=3600, tier partial_10: grp=252.00 plat=108.00; credited=3000
  v_exp_pending_mxn := v_exp_pending_mxn - 3000; v_exp_available_mxn := v_exp_available_mxn + 252; v_exp_total_earned_mxn := v_exp_total_earned_mxn - (3000-252);
  v_report := v_report || format('E1_settle_cancellation_mxn: %s (tier=%s grp_comp=%s status=%s payout=%s)\n',
    (v_result->>'ok')::boolean AND (v_result->>'group_compensation')::numeric=252,
    v_result->>'tier', v_result->>'group_compensation',
    (SELECT status FROM reservations WHERE id=re1), (SELECT payout_status FROM reservations WHERE id=re1));

  -- E2: USD
  INSERT INTO reservations (group_id, client_id, event_date, address, total_price, base_price, payment_status, payout_status, status, currency_code)
  VALUES (v_group_id, v_client_id, CURRENT_DATE+14, 'T2', 360, 300, 'pending_payment', 'pending', 'confirmed', 'USD') RETURNING id INTO re2;
  v_result := confirm_full_payment_and_credit_wallet(re2, 'test-e2', NULL, NULL);
  v_exp_pending_usd := v_exp_pending_usd + 300; v_exp_total_earned_usd := v_exp_total_earned_usd + 300;
  v_result := settle_cancellation(re2, NULL, 'client_cancelled', NULL);
  -- charge sobre total_price=360: grp=25.20 plat=10.80; credited=300
  v_exp_pending_usd := v_exp_pending_usd - 300; v_exp_available_usd := v_exp_available_usd + 25.2; v_exp_total_earned_usd := v_exp_total_earned_usd - (300-25.2);
  v_report := v_report || format('E2_settle_cancellation_usd: %s (tier=%s grp_comp=%s)\n',
    (v_result->>'ok')::boolean AND (v_result->>'group_compensation')::numeric=25.2, v_result->>'tier', v_result->>'group_compensation');

  -- E3: manual_payment_already_transferred
  INSERT INTO reservations (group_id, client_id, event_date, address, total_price, base_price, payment_status, payout_status, status, currency_code)
  VALUES (v_group_id, v_client_id, CURRENT_DATE+15, 'T3', 1200, 1000, 'pending_payment', 'pending', 'confirmed', 'MXN') RETURNING id INTO re3;
  v_result := confirm_full_payment_and_credit_wallet(re3, 'test-e3', NULL, NULL);
  v_exp_pending_mxn := v_exp_pending_mxn + 1000; v_exp_total_earned_mxn := v_exp_total_earned_mxn + 1000;
  v_result := admin_register_group_payment(re3, 400, 'advance', 'r.jpg', NULL, NULL, NOW());
  v_exp_pending_mxn := v_exp_pending_mxn - 400;
  v_result := settle_cancellation(re3, NULL, 'client_cancelled', NULL);
  v_report := v_report || format('E3_manual_payment_already_transferred: %s (error=%s amount=%s)\n',
    (v_result->>'error')='manual_payment_already_transferred', v_result->>'error', v_result->>'amount_already_paid');

  -- E4: moneda inválida
  INSERT INTO reservations (group_id, client_id, event_date, address, total_price, payment_status, payout_status, status, group_earnings, currency_code)
  VALUES (v_group_id, v_client_id, CURRENT_DATE+30, 'T', 1000, 'paid', 'held', 'confirmed', 1000, NULL) RETURNING id INTO re4;
  v_result := settle_cancellation(re4, NULL, 'client_cancelled', NULL);
  v_report := v_report || format('E4_moneda_invalida: %s (error=%s)\n', (v_result->>'error')='unsupported_currency', v_result->>'error');

  ------------------------------------------------------------------
  -- SECCIÓN F: settle_group_cancellation
  ------------------------------------------------------------------

  SELECT strike_count INTO v_strikes_before FROM groups WHERE id=v_group_id;

  -- F1: MXN (strike 1)
  INSERT INTO reservations (group_id, client_id, event_date, address, total_price, base_price, payment_status, payout_status, status, currency_code)
  VALUES (v_group_id, v_client_id, CURRENT_DATE+31, 'T', 2400, 2000, 'pending_payment', 'pending', 'confirmed', 'MXN') RETURNING id INTO rf1;
  v_result := confirm_full_payment_and_credit_wallet(rf1, 'test-f1', NULL, NULL);
  v_exp_pending_mxn := v_exp_pending_mxn + 2000; v_exp_total_earned_mxn := v_exp_total_earned_mxn + 2000;
  SELECT pending_balance_usd, available_balance_usd, total_earned_usd
  INTO v_snap_pending_usd, v_snap_available_usd, v_snap_te_usd FROM group_wallets WHERE id=v_wallet_id;
  v_result := settle_group_cancellation(rf1, NULL, 'group_cancelled', NULL);
  v_exp_pending_mxn := v_exp_pending_mxn - 2000; v_exp_total_earned_mxn := v_exp_total_earned_mxn - 2000;
  v_report := v_report || format('F1_settle_group_cancellation_mxn: %s (refund_amount=%s strikes=%s)\n',
    (v_result->>'ok')::boolean AND (v_result->>'refund_amount')::numeric=2400, v_result->>'refund_amount', v_result->>'strikes');
  v_report := v_report || format('F1b_wallet_transaction_debit_refund_positivo: %s (amount=%s)\n',
    EXISTS (SELECT 1 FROM wallet_transactions WHERE reservation_id=rf1 AND type='debit_refund' AND amount=2000),
    (SELECT amount FROM wallet_transactions WHERE reservation_id=rf1 AND type='debit_refund'));
  v_report := v_report || format('F1c_usd_sin_cambio: %s\n',
    (SELECT pending_balance_usd=v_snap_pending_usd AND available_balance_usd=v_snap_available_usd AND total_earned_usd=v_snap_te_usd
     FROM group_wallets WHERE id=v_wallet_id));

  -- F2: USD (strike 2)
  INSERT INTO reservations (group_id, client_id, event_date, address, total_price, base_price, payment_status, payout_status, status, currency_code)
  VALUES (v_group_id, v_client_id, CURRENT_DATE+32, 'T', 180, 150, 'pending_payment', 'pending', 'confirmed', 'USD') RETURNING id INTO rf2;
  v_result := confirm_full_payment_and_credit_wallet(rf2, 'test-f2', NULL, NULL);
  v_exp_pending_usd := v_exp_pending_usd + 150; v_exp_total_earned_usd := v_exp_total_earned_usd + 150;
  SELECT pending_balance, available_balance, total_earned
  INTO v_snap_pending, v_snap_available, v_snap_te FROM group_wallets WHERE id=v_wallet_id;
  v_result := settle_group_cancellation(rf2, NULL, 'group_cancelled', NULL);
  v_exp_pending_usd := v_exp_pending_usd - 150; v_exp_total_earned_usd := v_exp_total_earned_usd - 150;
  v_report := v_report || format('F2_settle_group_cancellation_usd: %s (refund_amount=%s strikes=%s)\n',
    (v_result->>'ok')::boolean AND (v_result->>'refund_amount')::numeric=180, v_result->>'refund_amount', v_result->>'strikes');
  v_report := v_report || format('F2b_wallet_transaction_debit_refund_positivo: %s (amount=%s)\n',
    EXISTS (SELECT 1 FROM wallet_transactions WHERE reservation_id=rf2 AND type='debit_refund' AND amount=150),
    (SELECT amount FROM wallet_transactions WHERE reservation_id=rf2 AND type='debit_refund'));
  v_report := v_report || format('F2c_mxn_sin_cambio: %s\n',
    (SELECT pending_balance=v_snap_pending AND available_balance=v_snap_available AND total_earned=v_snap_te
     FROM group_wallets WHERE id=v_wallet_id));

  -- F3: manual_payment_already_transferred (no debe sumar strike)
  INSERT INTO reservations (group_id, client_id, event_date, address, total_price, base_price, payment_status, payout_status, status, currency_code)
  VALUES (v_group_id, v_client_id, CURRENT_DATE+33, 'T', 1080, 900, 'pending_payment', 'pending', 'confirmed', 'MXN') RETURNING id INTO rf3;
  v_result := confirm_full_payment_and_credit_wallet(rf3, 'test-f3', NULL, NULL);
  v_exp_pending_mxn := v_exp_pending_mxn + 900; v_exp_total_earned_mxn := v_exp_total_earned_mxn + 900;
  v_result := admin_register_group_payment(rf3, 300, 'advance', 'r.jpg', NULL, NULL, NOW());
  v_exp_pending_mxn := v_exp_pending_mxn - 300;
  v_result := settle_group_cancellation(rf3, NULL, 'group_cancelled', NULL);
  v_report := v_report || format('F3_manual_payment_already_transferred: %s (error=%s)\n', (v_result->>'error')='manual_payment_already_transferred', v_result->>'error');

  -- F4: moneda inválida
  INSERT INTO reservations (group_id, client_id, event_date, address, total_price, payment_status, payout_status, status, group_earnings, currency_code)
  VALUES (v_group_id, v_client_id, CURRENT_DATE+34, 'T', 500, 'paid', 'held', 'confirmed', 500, NULL) RETURNING id INTO rf4;
  v_result := settle_group_cancellation(rf4, NULL, 'group_cancelled', NULL);
  v_report := v_report || format('F4_moneda_invalida: %s (error=%s)\n', (v_result->>'error')='unsupported_currency', v_result->>'error');

  -- F6: strike 3 → suspensión automática (bonus, riesgo real de producto)
  INSERT INTO reservations (group_id, client_id, event_date, address, total_price, base_price, payment_status, payout_status, status, currency_code)
  VALUES (v_group_id, v_client_id, CURRENT_DATE+35, 'T', 120, 100, 'pending_payment', 'pending', 'confirmed', 'MXN') RETURNING id INTO rf6;
  v_result := confirm_full_payment_and_credit_wallet(rf6, 'test-f6', NULL, NULL);
  v_exp_pending_mxn := v_exp_pending_mxn + 100; v_exp_total_earned_mxn := v_exp_total_earned_mxn + 100;
  v_result := settle_group_cancellation(rf6, NULL, 'group_cancelled', NULL);
  v_exp_pending_mxn := v_exp_pending_mxn - 100; v_exp_total_earned_mxn := v_exp_total_earned_mxn - 100;
  SELECT strike_count INTO v_strikes_after FROM groups WHERE id=v_group_id;
  v_report := v_report || format('F6_tercer_strike_suspende: %s (strikes_before=%s strikes_after=%s suspended_at=%s is_active=%s)\n',
    v_strikes_after - v_strikes_before = 3 AND (SELECT suspended_at IS NOT NULL AND NOT is_active FROM groups WHERE id=v_group_id),
    v_strikes_before, v_strikes_after,
    (SELECT suspended_at FROM groups WHERE id=v_group_id), (SELECT is_active FROM groups WHERE id=v_group_id));

  -- F7: payout_status='blocked' + v_credited=0 (pago tardío nunca acreditado,
  -- pero la cancelación SÍ es atribuible al grupo — único caller verificado).
  -- No debe mutar wallet, no debe insertar wallet_transaction, y el resto
  -- del flujo (status/refund_amount/strike/notificación) debe completarse.
  INSERT INTO reservations (group_id, client_id, event_date, address, total_price, base_price, payment_status, payout_status, status, currency_code)
  VALUES (v_group_id, v_client_id, CURRENT_DATE+52, 'T', 400, 333, 'pending_payment', 'pending', 'cancelled', 'MXN') RETURNING id INTO rf7;
  v_result := confirm_full_payment_and_credit_wallet(rf7, 'test-f7', NULL, NULL);
  v_report := v_report || format('F7pre_confirm_deja_blocked: %s (ok=%s blocked=%s payout_status=%s)\n',
    (v_result->>'ok')='false' AND (v_result->>'blocked')='true' AND (SELECT payout_status FROM reservations WHERE id=rf7)='blocked',
    v_result->>'ok', v_result->>'blocked', (SELECT payout_status FROM reservations WHERE id=rf7));
  SELECT pending_balance, available_balance, pending_balance_usd, available_balance_usd, total_earned, total_earned_usd
  INTO v_snap_pending, v_snap_available, v_snap_pending_usd, v_snap_available_usd, v_snap_te, v_snap_te_usd
  FROM group_wallets WHERE id=v_wallet_id;
  SELECT strike_count INTO v_strikes_before FROM groups WHERE id=v_group_id;
  v_result := settle_group_cancellation(rf7, NULL, 'group_cancelled', NULL);
  SELECT strike_count INTO v_strikes_after FROM groups WHERE id=v_group_id;
  v_report := v_report || format('F7_blocked_credited_0: %s (ok=%s refund_amount=%s currency=%s wt_rows=%s wallet_sin_cambio=%s status=%s payout=%s strike_delta=%s tiene_group_strike=%s tiene_notificacion=%s)\n',
    (v_result->>'ok')::boolean
      AND (v_result->>'refund_amount')::numeric = 400
      AND (SELECT COUNT(*) FROM wallet_transactions WHERE reservation_id=rf7) = 0
      AND (SELECT pending_balance=v_snap_pending AND available_balance=v_snap_available AND pending_balance_usd=v_snap_pending_usd
                  AND available_balance_usd=v_snap_available_usd AND total_earned=v_snap_te AND total_earned_usd=v_snap_te_usd
           FROM group_wallets WHERE id=v_wallet_id)
      AND (SELECT status FROM reservations WHERE id=rf7)='cancelled'
      AND (SELECT payout_status FROM reservations WHERE id=rf7)='refunded'
      AND (v_strikes_after - v_strikes_before) = 1
      AND EXISTS (SELECT 1 FROM group_strikes WHERE reservation_id=rf7)
      AND EXISTS (SELECT 1 FROM notifications WHERE (data->>'reservation_id') = rf7::text AND type='reservation'),
    v_result->>'ok', v_result->>'refund_amount', v_result->>'currency',
    (SELECT COUNT(*) FROM wallet_transactions WHERE reservation_id=rf7),
    (SELECT pending_balance=v_snap_pending AND available_balance=v_snap_available AND pending_balance_usd=v_snap_pending_usd
            AND available_balance_usd=v_snap_available_usd AND total_earned=v_snap_te AND total_earned_usd=v_snap_te_usd
     FROM group_wallets WHERE id=v_wallet_id),
    (SELECT status FROM reservations WHERE id=rf7), (SELECT payout_status FROM reservations WHERE id=rf7),
    v_strikes_after - v_strikes_before,
    EXISTS (SELECT 1 FROM group_strikes WHERE reservation_id=rf7),
    EXISTS (SELECT 1 FROM notifications WHERE (data->>'reservation_id') = rf7::text AND type='reservation'));
  v_report := v_report || format('F8_ningun_bucket_negativo_tras_F: %s\n',
    (SELECT pending_balance>=0 AND available_balance>=0 AND pending_balance_usd>=0 AND available_balance_usd>=0 AND total_earned>=0 AND total_earned_usd>=0
     FROM group_wallets WHERE id=v_wallet_id));

  ------------------------------------------------------------------
  -- SECCIÓN G: resolve_dispute
  ------------------------------------------------------------------
  PERFORM set_config('request.jwt.claim.sub', v_admin_id::text, true);

  -- G1: resolved_client MXN (solo pendiente)
  INSERT INTO reservations (group_id, client_id, event_date, address, total_price, base_price, payment_status, payout_status, status, currency_code)
  VALUES (v_group_id, v_client_id, CURRENT_DATE+36, 'T', 1800, 1500, 'pending_payment', 'pending', 'confirmed', 'MXN') RETURNING id INTO rg1;
  v_result := confirm_full_payment_and_credit_wallet(rg1, 'test-g1', NULL, NULL);
  v_exp_pending_mxn := v_exp_pending_mxn + 1500; v_exp_total_earned_mxn := v_exp_total_earned_mxn + 1500;
  INSERT INTO disputes (reservation_id, opened_by, status, reason) VALUES (rg1, v_client_id, 'open', 'test G1') RETURNING id INTO dg1;
  v_result := resolve_dispute(dg1, 'resolved_client', 'nota G1');
  v_exp_pending_mxn := v_exp_pending_mxn - 1500;
  v_report := v_report || format('G1_resolved_client_mxn_pendiente: %s (dispute_status=%s reservation_payout=%s)\n',
    (v_result->>'ok')::boolean AND (SELECT status FROM disputes WHERE id=dg1)='resolved_client' AND (SELECT payout_status FROM reservations WHERE id=rg1)='refunded',
    (SELECT status FROM disputes WHERE id=dg1), (SELECT payout_status FROM reservations WHERE id=rg1));

  -- G2: resolved_client USD
  INSERT INTO reservations (group_id, client_id, event_date, address, total_price, base_price, payment_status, payout_status, status, currency_code)
  VALUES (v_group_id, v_client_id, CURRENT_DATE+37, 'T', 216, 180, 'pending_payment', 'pending', 'confirmed', 'USD') RETURNING id INTO rg2;
  v_result := confirm_full_payment_and_credit_wallet(rg2, 'test-g2', NULL, NULL);
  v_exp_pending_usd := v_exp_pending_usd + 180; v_exp_total_earned_usd := v_exp_total_earned_usd + 180;
  INSERT INTO disputes (reservation_id, opened_by, status, reason) VALUES (rg2, v_client_id, 'open', 'test G2') RETURNING id INTO dg2;
  v_result := resolve_dispute(dg2, 'resolved_client', 'nota G2');
  v_exp_pending_usd := v_exp_pending_usd - 180;
  v_report := v_report || format('G2_resolved_client_usd: %s (dispute_status=%s)\n', (SELECT status FROM disputes WHERE id=dg2)='resolved_client', (SELECT status FROM disputes WHERE id=dg2));

  -- G3: resolved_group (mueve wallet vía release_event_payment interno — requiere llegada)
  INSERT INTO reservations (group_id, client_id, event_date, address, total_price, base_price, payment_status, payout_status, status, currency_code)
  VALUES (v_group_id, v_client_id, CURRENT_DATE+38, 'T', 1200, 1000, 'pending_payment', 'pending', 'confirmed', 'MXN') RETURNING id INTO rg3;
  v_result := confirm_full_payment_and_credit_wallet(rg3, 'test-g3', NULL, NULL);
  v_exp_pending_mxn := v_exp_pending_mxn + 1000; v_exp_total_earned_mxn := v_exp_total_earned_mxn + 1000;
  UPDATE reservations SET status='completed', group_arrived_at = NOW() WHERE id = rg3;
  INSERT INTO disputes (reservation_id, opened_by, status, reason) VALUES (rg3, v_client_id, 'open', 'test G3') RETURNING id INTO dg3;
  v_result := resolve_dispute(dg3, 'resolved_group', 'nota G3');
  v_exp_pending_mxn := v_exp_pending_mxn - 1000; v_exp_available_mxn := v_exp_available_mxn + 1000;
  v_report := v_report || format('G3_resolved_group_libera_wallet: %s (dispute_status=%s reservation_payout=%s)\n',
    (SELECT status FROM disputes WHERE id=dg3)='resolved_group' AND (SELECT payout_status FROM reservations WHERE id=rg3)='released',
    (SELECT status FROM disputes WHERE id=dg3), (SELECT payout_status FROM reservations WHERE id=rg3));

  -- G4: manual_payment_already_transferred → RAISE EXCEPTION, disputa NO se resuelve
  INSERT INTO reservations (group_id, client_id, event_date, address, total_price, base_price, payment_status, payout_status, status, currency_code)
  VALUES (v_group_id, v_client_id, CURRENT_DATE+39, 'T', 720, 600, 'pending_payment', 'pending', 'confirmed', 'MXN') RETURNING id INTO rg4;
  v_result := confirm_full_payment_and_credit_wallet(rg4, 'test-g4', NULL, NULL);
  v_exp_pending_mxn := v_exp_pending_mxn + 600; v_exp_total_earned_mxn := v_exp_total_earned_mxn + 600;
  v_result := admin_register_group_payment(rg4, 200, 'advance', 'r.jpg', NULL, NULL, NOW());
  v_exp_pending_mxn := v_exp_pending_mxn - 200;
  INSERT INTO disputes (reservation_id, opened_by, status, reason) VALUES (rg4, v_client_id, 'open', 'test G4') RETURNING id INTO dg4;
  BEGIN
    v_result := resolve_dispute(dg4, 'resolved_client', 'nota G4');
    v_report := v_report || 'G4_manual_payment_already_transferred: FAIL (no lanzó excepción)' || E'\n';
  EXCEPTION WHEN OTHERS THEN
    v_report := v_report || format('G4_manual_payment_already_transferred: %s (mensaje=%s dispute_sigue_open=%s)\n',
      SQLERRM LIKE '%ya tiene $%' AND (SELECT status FROM disputes WHERE id=dg4)='open',
      SQLERRM, (SELECT status FROM disputes WHERE id=dg4));
  END;

  -- G5: moneda inválida → RAISE EXCEPTION, disputa NO se resuelve
  INSERT INTO reservations (group_id, client_id, event_date, address, total_price, payment_status, payout_status, status, group_earnings, currency_code)
  VALUES (v_group_id, v_client_id, CURRENT_DATE+40, 'T', 500, 'paid', 'held', 'confirmed', 500, NULL) RETURNING id INTO rg5;
  INSERT INTO disputes (reservation_id, opened_by, status, reason) VALUES (rg5, v_client_id, 'open', 'test G5') RETURNING id INTO dg5;
  BEGIN
    v_result := resolve_dispute(dg5, 'resolved_client', 'nota G5');
    v_report := v_report || 'G5_moneda_invalida: FAIL (no lanzó excepción)' || E'\n';
  EXCEPTION WHEN OTHERS THEN
    v_report := v_report || format('G5_moneda_invalida: %s (mensaje=%s dispute_sigue_open=%s)\n',
      SQLERRM LIKE '%moneda%' AND (SELECT status FROM disputes WHERE id=dg5)='open', SQLERRM, (SELECT status FROM disputes WHERE id=dg5));
  END;

  -- G7: resolved_client sobre reserva YA liberada (rama "liberado", distinta a G1)
  INSERT INTO reservations (group_id, client_id, event_date, address, total_price, base_price, payment_status, payout_status, status, currency_code)
  VALUES (v_group_id, v_client_id, CURRENT_DATE+41, 'T', 2880, 2400, 'pending_payment', 'pending', 'confirmed', 'MXN') RETURNING id INTO rg7;
  v_result := confirm_full_payment_and_credit_wallet(rg7, 'test-g7', NULL, NULL);
  v_exp_pending_mxn := v_exp_pending_mxn + 2400; v_exp_total_earned_mxn := v_exp_total_earned_mxn + 2400;
  UPDATE reservations SET status='completed', group_arrived_at = NOW() WHERE id = rg7;
  v_result := release_group_earnings_atomic(rg7, v_admin_id);
  v_exp_pending_mxn := v_exp_pending_mxn - 2400; v_exp_available_mxn := v_exp_available_mxn + 2400;
  INSERT INTO disputes (reservation_id, opened_by, status, reason) VALUES (rg7, v_client_id, 'open', 'test G7') RETURNING id INTO dg7;
  v_result := resolve_dispute(dg7, 'resolved_client', 'nota G7');
  v_exp_available_mxn := v_exp_available_mxn - 2400;
  v_report := v_report || format('G7_resolved_client_rama_liberado: %s (dispute_status=%s payout=%s)\n',
    (SELECT status FROM disputes WHERE id=dg7)='resolved_client' AND (SELECT payout_status FROM reservations WHERE id=rg7)='refunded',
    (SELECT status FROM disputes WHERE id=dg7), (SELECT payout_status FROM reservations WHERE id=rg7));
  v_report := v_report || '  (NOTA: no se construyó un caso con pendiente>0 Y liberado>0 simultáneamente — requeriría estado half_released, fuera del alcance de P1F. Ver reporte.)' || E'\n';

  ------------------------------------------------------------------
  -- SECCIÓN H: claims / concurrencia
  ------------------------------------------------------------------

  -- H1: claim válido
  INSERT INTO reservations (group_id, client_id, event_date, address, total_price, base_price, payment_status, payout_status, status, currency_code)
  VALUES (v_group_id, v_client_id, CURRENT_DATE+42, 'T', 1200, 1000, 'pending_payment', 'pending', 'confirmed', 'MXN') RETURNING id INTO rh1;
  v_result := confirm_full_payment_and_credit_wallet(rh1, 'test-h1', NULL, NULL);
  v_exp_pending_mxn := v_exp_pending_mxn + 1000; v_exp_total_earned_mxn := v_exp_total_earned_mxn + 1000;
  v_result := claim_reservation_refund(rh1, 'full', 1200, 'stripe', 'pi_h1');
  c_h1 := (v_result->>'claim_id')::uuid;
  v_report := v_report || format('H1_claim_valido: %s (claim_id=%s)\n', (v_result->>'ok')::boolean, v_result->>'claim_id');

  -- H2: claim duplicado (mismo provider+payment_id)
  v_result := claim_reservation_refund(rh1, 'full', 1200, 'stripe', 'pi_h1');
  v_report := v_report || format('H2_claim_duplicado_rechazado: %s (error=%s)\n', (v_result->>'error')='refund_already_in_progress', v_result->>'error');

  -- H3: refund gana lock → advance rechazado por refund_in_progress
  INSERT INTO reservations (group_id, client_id, event_date, address, total_price, base_price, payment_status, payout_status, status, currency_code)
  VALUES (v_group_id, v_client_id, CURRENT_DATE+43, 'T', 960, 800, 'pending_payment', 'pending', 'confirmed', 'MXN') RETURNING id INTO rh3;
  v_result := confirm_full_payment_and_credit_wallet(rh3, 'test-h3', NULL, NULL);
  v_exp_pending_mxn := v_exp_pending_mxn + 800; v_exp_total_earned_mxn := v_exp_total_earned_mxn + 800;
  v_result := claim_reservation_refund(rh3, 'full', 960, 'stripe', 'pi_h3');
  c_h3 := (v_result->>'claim_id')::uuid;
  v_result := admin_register_group_payment(rh3, 200, 'advance', 'r.jpg', NULL, NULL, NOW());
  v_report := v_report || format('H3_advance_rechazado_por_refund_in_progress: %s (error=%s)\n', (v_result->>'error')='refund_in_progress', v_result->>'error');

  -- H4: anticipo existente → claim rechazado
  INSERT INTO reservations (group_id, client_id, event_date, address, total_price, base_price, payment_status, payout_status, status, currency_code)
  VALUES (v_group_id, v_client_id, CURRENT_DATE+44, 'T', 960, 800, 'pending_payment', 'pending', 'confirmed', 'MXN') RETURNING id INTO rh4;
  v_result := confirm_full_payment_and_credit_wallet(rh4, 'test-h4', NULL, NULL);
  v_exp_pending_mxn := v_exp_pending_mxn + 800; v_exp_total_earned_mxn := v_exp_total_earned_mxn + 800;
  v_result := admin_register_group_payment(rh4, 200, 'advance', 'r.jpg', NULL, NULL, NOW());
  v_exp_pending_mxn := v_exp_pending_mxn - 200;
  v_result := claim_reservation_refund(rh4, 'full', 960, 'stripe', 'pi_h4');
  v_report := v_report || format('H4_claim_rechazado_por_manual_payment: %s (error=%s)\n', (v_result->>'error')='manual_payment_already_transferred', v_result->>'error');

  -- H5: estados válidos del CHECK (processing→provider_succeeded→done, y provider_failed)
  UPDATE provider_refund_claims SET status='provider_succeeded', updated_at=NOW() WHERE id=c_h1;
  UPDATE provider_refund_claims SET status='done', updated_at=NOW() WHERE id=c_h1;
  UPDATE provider_refund_claims SET status='provider_failed', updated_at=NOW() WHERE id=c_h3;
  v_report := v_report || format('H5_estados_validos_check: %s (c_h1=%s c_h3=%s)\n',
    (SELECT status FROM provider_refund_claims WHERE id=c_h1)='done' AND (SELECT status FROM provider_refund_claims WHERE id=c_h3)='provider_failed',
    (SELECT status FROM provider_refund_claims WHERE id=c_h1), (SELECT status FROM provider_refund_claims WHERE id=c_h3));

  -- H6: estado inválido rechazado por el CHECK constraint
  BEGIN
    UPDATE provider_refund_claims SET status='bogus_status' WHERE id=c_h1;
    v_report := v_report || 'H6_estado_invalido_rechazado: FAIL (UPDATE permitido)' || E'\n';
  EXCEPTION WHEN check_violation THEN
    v_report := v_report || 'H6_estado_invalido_rechazado: true (check_violation)' || E'\n';
  END;

  ------------------------------------------------------------------
  -- SECCIÓN I: group_payment_requests
  ------------------------------------------------------------------

  -- I1: pending existente + idempotencia
  INSERT INTO reservations (group_id, client_id, event_date, address, total_price, base_price, payment_status, payout_status, status, currency_code)
  VALUES (v_group_id, v_client_id, CURRENT_DATE+45, 'T', 1200, 1000, 'pending_payment', 'pending', 'confirmed', 'MXN') RETURNING id INTO ri1;
  v_result := confirm_full_payment_and_credit_wallet(ri1, 'test-i1', NULL, NULL);
  v_exp_pending_mxn := v_exp_pending_mxn + 1000; v_exp_total_earned_mxn := v_exp_total_earned_mxn + 1000;
  UPDATE reservations SET status='completed', group_arrived_at = NOW() WHERE id = ri1;
  v_result := release_group_earnings_atomic(ri1, v_admin_id);
  v_exp_pending_mxn := v_exp_pending_mxn - 1000; v_exp_available_mxn := v_exp_available_mxn + 1000;

  PERFORM set_config('request.jwt.claim.sub', v_owner_id::text, true);
  v_result := group_request_payment(ri1);
  v_req_id := (v_result->>'request_id')::uuid;
  v_report := v_report || format('I1a_pending_creado: %s (already_requested=%s)\n', (v_result->>'ok')::boolean AND (v_result->>'already_requested')='false', v_result->>'already_requested');
  v_result := group_request_payment(ri1);
  v_report := v_report || format('I1b_idempotente_mismo_request: %s (already_requested=%s mismo_id=%s)\n',
    (v_result->>'already_requested')='true' AND (v_result->>'request_id')::uuid = v_req_id, v_result->>'already_requested', (v_result->>'request_id')::uuid = v_req_id);
  PERFORM set_config('request.jwt.claim.sub', v_admin_id::text, true);

  -- I2: final settlement exacto → saldo 0 → pending→completed EN LA MISMA operación
  v_result := admin_register_group_payment(ri1, 1000, 'final_settlement', 'r.jpg', NULL, 'REF-I2', NOW());
  v_exp_available_mxn := v_exp_available_mxn - 1000;
  v_report := v_report || format('I2_final_exacto_cierra_request: %s (ok=%s request_status=%s)\n',
    (v_result->>'ok')::boolean AND (SELECT status FROM group_payment_requests WHERE id=v_req_id)='completed',
    v_result->>'ok', (SELECT status FROM group_payment_requests WHERE id=v_req_id));

  -- I3: intento fallido NO marca completed
  INSERT INTO reservations (group_id, client_id, event_date, address, total_price, base_price, payment_status, payout_status, status, currency_code)
  VALUES (v_group_id, v_client_id, CURRENT_DATE+46, 'T', 600, 500, 'pending_payment', 'pending', 'confirmed', 'MXN') RETURNING id INTO ri3;
  v_result := confirm_full_payment_and_credit_wallet(ri3, 'test-i3', NULL, NULL);
  v_exp_pending_mxn := v_exp_pending_mxn + 500; v_exp_total_earned_mxn := v_exp_total_earned_mxn + 500;
  UPDATE reservations SET status='completed', group_arrived_at = NOW() WHERE id = ri3;
  v_result := release_group_earnings_atomic(ri3, v_admin_id);
  v_exp_pending_mxn := v_exp_pending_mxn - 500; v_exp_available_mxn := v_exp_available_mxn + 500;

  PERFORM set_config('request.jwt.claim.sub', v_owner_id::text, true);
  v_result := group_request_payment(ri3);
  PERFORM set_config('request.jwt.claim.sub', v_admin_id::text, true);
  v_result := admin_register_group_payment(ri3, 999, 'final_settlement', 'r.jpg', NULL, 'REF-I3', NOW());
  v_report := v_report || format('I3_intento_fallido_no_marca_completed: %s (error=%s request_sigue=%s)\n',
    NOT (v_result->>'ok')::boolean AND (SELECT status FROM group_payment_requests WHERE reservation_id=ri3)='pending',
    v_result->>'error', (SELECT status FROM group_payment_requests WHERE reservation_id=ri3));
  -- limpio ri3 para no dejar saldo colgado en las cifras esperadas: liquidación correcta
  v_result := admin_register_group_payment(ri3, 500, 'final_settlement', 'r.jpg', NULL, 'REF-I3B', NOW());
  v_exp_available_mxn := v_exp_available_mxn - 500;

  ------------------------------------------------------------------
  -- SECCIÓN J: withdrawals
  ------------------------------------------------------------------

  -- J1: group no puede autorretirarse
  PERFORM set_config('request.jwt.claim.sub', v_owner_id::text, true);
  v_result := request_withdrawal(50, '123456789012345678', 'BBVA', 'Test');
  v_report := v_report || format('J1_group_self_withdrawal_disabled: %s (error=%s)\n', (v_result->>'error')='group_self_withdrawal_disabled', v_result->>'error');

  -- J2: INSERT directo bloqueado por RLS
  EXECUTE 'SET ROLE authenticated';
  PERFORM set_config('request.jwt.claim.sub', v_owner_id::text, true);
  BEGIN
    INSERT INTO withdrawals (user_id, amount, status, payout_method) VALUES (v_owner_id, 111, 'pending', 'spei');
    v_report := v_report || 'J2_insert_directo_bloqueado_rls: false (INSERT PERMITIDO)' || E'\n';
  EXCEPTION WHEN insufficient_privilege OR others THEN
    v_report := v_report || 'J2_insert_directo_bloqueado_rls: true' || E'\n';
  END;
  EXECUTE 'RESET ROLE';
  PERFORM set_config('request.jwt.claim.sub', v_admin_id::text, true);

  -- J3: SELECT propio permitido, aislado de otros usuarios
  INSERT INTO withdrawals (user_id, amount, status, payout_method) VALUES (v_owner_id, 500, 'pending', 'spei');
  INSERT INTO withdrawals (user_id, amount, status, payout_method) VALUES (v_admin_id, 999, 'pending', 'spei');
  EXECUTE 'SET ROLE authenticated';
  PERFORM set_config('request.jwt.claim.sub', v_owner_id::text, true);
  v_report := v_report || format('J3_select_propio_aislado: %s (visibles_para_owner=%s)\n',
    (SELECT COUNT(*) FROM withdrawals WHERE user_id=v_owner_id) = (SELECT COUNT(*) FROM withdrawals),
    (SELECT COUNT(*) FROM withdrawals));
  EXECUTE 'RESET ROLE';

  -- J4: admin conserva acceso total
  EXECUTE 'SET ROLE authenticated';
  PERFORM set_config('request.jwt.claim.sub', v_admin_id::text, true);
  v_report := v_report || format('J4_admin_ve_todo: %s (count=%s)\n', (SELECT COUNT(*) FROM withdrawals) >= 2, (SELECT COUNT(*) FROM withdrawals));
  EXECUTE 'RESET ROLE';
  PERFORM set_config('request.jwt.claim.sub', v_admin_id::text, true);

  ------------------------------------------------------------------
  -- INVARIANTES FINALES: MXN nunca toca columnas USD y viceversa;
  -- ningún bucket queda negativo; el total real coincide EXACTO con
  -- lo esperado acumulado operación por operación.
  ------------------------------------------------------------------
  SELECT pending_balance, available_balance, pending_balance_usd, available_balance_usd, total_earned, total_earned_usd
  INTO v_snap_pending, v_snap_available, v_snap_pending_usd, v_snap_available_usd, v_snap_te, v_snap_te_usd
  FROM group_wallets WHERE id = v_wallet_id;

  v_report := v_report || format('INVARIANTE_pending_mxn: %s (real=%s esperado=%s)\n', v_snap_pending = v_exp_pending_mxn, v_snap_pending, v_exp_pending_mxn);
  v_report := v_report || format('INVARIANTE_available_mxn: %s (real=%s esperado=%s)\n', v_snap_available = v_exp_available_mxn, v_snap_available, v_exp_available_mxn);
  v_report := v_report || format('INVARIANTE_total_earned_mxn: %s (real=%s esperado=%s)\n', v_snap_te = v_exp_total_earned_mxn, v_snap_te, v_exp_total_earned_mxn);
  v_report := v_report || format('INVARIANTE_pending_usd: %s (real=%s esperado=%s)\n', v_snap_pending_usd = v_exp_pending_usd, v_snap_pending_usd, v_exp_pending_usd);
  v_report := v_report || format('INVARIANTE_available_usd: %s (real=%s esperado=%s)\n', v_snap_available_usd = v_exp_available_usd, v_snap_available_usd, v_exp_available_usd);
  v_report := v_report || format('INVARIANTE_total_earned_usd: %s (real=%s esperado=%s)\n', v_snap_te_usd = v_exp_total_earned_usd, v_snap_te_usd, v_exp_total_earned_usd);
  v_report := v_report || format('INVARIANTE_ningun_bucket_negativo: %s\n',
    v_snap_pending >= 0 AND v_snap_available >= 0 AND v_snap_pending_usd >= 0 AND v_snap_available_usd >= 0 AND v_snap_te >= 0 AND v_snap_te_usd >= 0);

  v_report := v_report || E'══════ FIN 537 — todo se revierte ahora (RAISE) ══════';
  RAISE EXCEPTION '%', v_report;
END;
$test537$;
