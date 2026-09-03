-- ============================================================
-- sql/536_p1f_hardening_tests.sql
-- Pruebas transaccionales autoreversibles para P1F.
-- ============================================================

DO $test$
DECLARE
  v_admin_id UUID; v_group_owner UUID; v_client_id UUID;
  v_group_id UUID; v_wallet_id UUID;
  v_res_mxn UUID; v_res_usd UUID; v_res_unsupported UUID; v_res_unsupported_arrived UUID;
  v_res_refund_then_advance UUID; v_res_advance_then_refund UUID;
  v_result jsonb; v_claim_id UUID; v_claim_id2 UUID;
  v_report TEXT := '';
  v_pending0 NUMERIC; v_available0 NUMERIC; v_pending_usd0 NUMERIC; v_available_usd0 NUMERIC;
BEGIN
  SELECT id INTO v_admin_id FROM profiles WHERE role = 'admin' LIMIT 1;
  SELECT id INTO v_client_id FROM profiles WHERE role = 'client' LIMIT 1;
  SELECT id, owner_id INTO v_group_id, v_group_owner FROM groups WHERE owner_id IS NOT NULL LIMIT 1;

  PERFORM ensure_group_wallet(v_group_id);
  SELECT id, pending_balance, available_balance, pending_balance_usd, available_balance_usd
  INTO v_wallet_id, v_pending0, v_available0, v_pending_usd0, v_available_usd0
  FROM group_wallets WHERE group_id = v_group_id;

  UPDATE wallets SET bank_clabe = '123456789012345678', bank_name = 'BBVA', account_holder = 'Grupo Test',
    bank_linked_at = NOW() WHERE user_id = v_group_owner;
  IF NOT FOUND THEN
    INSERT INTO wallets (user_id, bank_clabe, bank_name, account_holder, bank_linked_at)
    VALUES (v_group_owner, '123456789012345678', 'BBVA', 'Grupo Test', NOW());
  END IF;

  UPDATE group_wallets SET pending_balance = pending_balance + 100000, available_balance = available_balance + 100000,
    pending_balance_usd = pending_balance_usd + 5000, available_balance_usd = available_balance_usd + 5000
  WHERE id = v_wallet_id;

  -- Reserva MXN
  INSERT INTO reservations (group_id, client_id, event_date, address, total_price, payment_status, payout_status, status, group_earnings, currency_code)
  VALUES (v_group_id, v_client_id, CURRENT_DATE + 5, 'Test address', 21600, 'paid', 'held', 'confirmed', 18000, 'MXN') RETURNING id INTO v_res_mxn;

  -- Reserva USD
  INSERT INTO reservations (group_id, client_id, event_date, address, total_price, payment_status, payout_status, status, group_earnings, currency_code)
  VALUES (v_group_id, v_client_id, CURRENT_DATE + 6, 'Test address', 1200, 'paid', 'held', 'confirmed', 1000, 'USD') RETURNING id INTO v_res_usd;

  -- Reserva con moneda NULL (simula no soportada, sin debilitar el CHECK real)
  INSERT INTO reservations (group_id, client_id, event_date, address, total_price, payment_status, payout_status, status, group_earnings, currency_code)
  VALUES (v_group_id, v_client_id, CURRENT_DATE + 7, 'Test address', 6000, 'paid', 'held', 'confirmed', 5000, NULL) RETURNING id INTO v_res_unsupported;

  -- Variante CON llegada verificada: release_group_earnings_atomic evalúa
  -- el guard de llegada (group_arrived_at/arrival_verified) ANTES que el
  -- guard de moneda. Sin llegada, la función nunca alcanza a evaluar la
  -- moneda — solo devuelve skipped:true por falta de llegada (hallazgo de
  -- la verificación forense previa). Esta reserva sí cumple llegada para
  -- que T7 pruebe realmente el guard de moneda, no el de llegada.
  INSERT INTO reservations (group_id, client_id, event_date, address, total_price, payment_status, payout_status, status, group_earnings, currency_code, group_arrived_at)
  VALUES (v_group_id, v_client_id, CURRENT_DATE + 11, 'Test address', 6000, 'paid', 'held', 'confirmed', 5000, NULL, NOW()) RETURNING id INTO v_res_unsupported_arrived;

  -- Reservas para exclusión mutua
  INSERT INTO reservations (group_id, client_id, event_date, address, total_price, payment_status, payout_status, status, group_earnings, currency_code)
  VALUES (v_group_id, v_client_id, CURRENT_DATE + 8, 'Test address', 6000, 'paid', 'held', 'confirmed', 5000, 'MXN') RETURNING id INTO v_res_refund_then_advance;
  INSERT INTO reservations (group_id, client_id, event_date, address, total_price, payment_status, payout_status, status, group_earnings, currency_code)
  VALUES (v_group_id, v_client_id, CURRENT_DATE + 9, 'Test address', 6000, 'paid', 'held', 'confirmed', 5000, 'MXN') RETURNING id INTO v_res_advance_then_refund;

  PERFORM set_config('request.jwt.claim.sub', v_admin_id::text, true);

  -- ═══ MXN advance/final ═══
  v_result := admin_register_group_payment(v_res_mxn, 5000, 'advance', 'r.jpg', NULL, NULL, NOW());
  v_report := v_report || format('T1_advance_mxn_pass: %s (bucket=%s currency=%s)\n', (v_result->>'ok')::boolean, v_result->>'bucket_debitado', v_result->>'currency');

  UPDATE reservations SET status='completed' WHERE id=v_res_mxn;
  UPDATE reservations SET group_arrived_at = NOW() WHERE id=v_res_mxn;  -- llegada válida real (requisito de release_group_earnings_atomic)
  PERFORM release_group_earnings_atomic(v_res_mxn, v_admin_id);
  v_result := admin_register_group_payment(v_res_mxn, 13000, 'final_settlement', 'r.jpg', NULL, 'REF1', NOW());
  v_report := v_report || format('T2_final_mxn_pass: %s (bucket=%s currency=%s)\n', (v_result->>'ok')::boolean, v_result->>'bucket_debitado', v_result->>'currency');

  -- ═══ USD advance/final ═══
  v_result := admin_register_group_payment(v_res_usd, 300, 'advance', 'r.jpg', NULL, NULL, NOW());
  v_report := v_report || format('T3_advance_usd_pass: %s (bucket=%s currency=%s)\n', (v_result->>'ok')::boolean, v_result->>'bucket_debitado', v_result->>'currency');

  UPDATE reservations SET status='completed' WHERE id=v_res_usd;
  UPDATE reservations SET group_arrived_at = NOW() WHERE id=v_res_usd;  -- llegada válida real (requisito de release_group_earnings_atomic)
  PERFORM release_group_earnings_atomic(v_res_usd, v_admin_id);
  v_result := admin_register_group_payment(v_res_usd, 700, 'final_settlement', 'r.jpg', NULL, 'REF2', NOW());
  v_report := v_report || format('T4_final_usd_pass: %s (bucket=%s currency=%s)\n', (v_result->>'ok')::boolean, v_result->>'bucket_debitado', v_result->>'currency');

  -- ═══ Cruzadas: verificar que MXN/USD nunca se tocan entre sí ═══
  v_report := v_report || format('T5_wallet_final_state: pending=%s(base %s) available=%s(base %s) pending_usd=%s(base %s) available_usd=%s(base %s)\n',
    (SELECT pending_balance FROM group_wallets WHERE id=v_wallet_id), v_pending0,
    (SELECT available_balance FROM group_wallets WHERE id=v_wallet_id), v_available0,
    (SELECT pending_balance_usd FROM group_wallets WHERE id=v_wallet_id), v_pending_usd0,
    (SELECT available_balance_usd FROM group_wallets WHERE id=v_wallet_id), v_available_usd0);
  -- MXN: T1 advance debita pending 5000. release_group_earnings_atomic AHORA
  -- sí corre (llegada válida) y mueve to_release=group_earnings-ya_anticipado
  -- =18000-5000=13000 de pending→available. T2 final_settlement debita esos
  -- mismos 13000 de available (saldo_restante=18000-5000=13000).
  -- pending esperado:   base+100000 -5000(T1) -13000(release) = base+82000
  -- available esperado: base+100000 +13000(release) -13000(T2) = base+100000 (se cancelan)
  -- Mismo patrón para USD: pending -300(T3) -700(release); available +700(release) -700(T4).
  v_report := v_report || format('T5b_mxn_pending_correcto: %s\n', (SELECT pending_balance FROM group_wallets WHERE id=v_wallet_id) = v_pending0 + 100000 - 5000 - 13000);
  v_report := v_report || format('T5c_mxn_available_correcto: %s\n', (SELECT available_balance FROM group_wallets WHERE id=v_wallet_id) = v_available0 + 100000 + 13000 - 13000);
  v_report := v_report || format('T5d_usd_pending_correcto: %s\n', (SELECT pending_balance_usd FROM group_wallets WHERE id=v_wallet_id) = v_pending_usd0 + 5000 - 300 - 700);
  v_report := v_report || format('T5e_usd_available_correcto: %s\n', (SELECT available_balance_usd FROM group_wallets WHERE id=v_wallet_id) = v_available_usd0 + 5000 + 700 - 700);

  -- ═══ Moneda no soportada (NULL) ═══
  v_result := admin_register_group_payment(v_res_unsupported, 1000, 'advance', 'r.jpg', NULL, NULL, NOW());
  v_report := v_report || format('T6_unsupported_currency_rechazado: %s (error=%s)\n', (v_result->>'error')='unsupported_currency', v_result->>'error');

  v_result := release_group_earnings_atomic(v_res_unsupported_arrived, v_admin_id);
  v_report := v_report || format('T7_release_unsupported_currency_rechazado: %s (error=%s)\n', (v_result->>'error')='unsupported_currency', v_result->>'error');

  -- ═══ Exclusión mutua: claim gana lock -> advance rechazado ═══
  v_result := claim_reservation_refund(v_res_refund_then_advance, 'full', 5000, 'stripe', 'pi_test_1');
  v_report := v_report || format('T8_claim_pass: %s (claim_id=%s)\n', (v_result->>'ok')::boolean, v_result->>'claim_id');
  v_claim_id := (v_result->>'claim_id')::uuid;

  v_result := admin_register_group_payment(v_res_refund_then_advance, 1000, 'advance', 'r.jpg', NULL, NULL, NOW());
  v_report := v_report || format('T9_advance_rechazado_por_refund_in_progress: %s (error=%s)\n', (v_result->>'error')='refund_in_progress', v_result->>'error');

  -- ═══ Exclusión mutua: advance gana -> claim rechazado por manual_payment_already_transferred ═══
  v_result := admin_register_group_payment(v_res_advance_then_refund, 1000, 'advance', 'r.jpg', NULL, NULL, NOW());
  v_report := v_report || format('T10_advance_pass: %s\n', (v_result->>'ok')::boolean);

  v_result := claim_reservation_refund(v_res_advance_then_refund, 'full', 5000, 'stripe', 'pi_test_2');
  v_report := v_report || format('T11_claim_rechazado_por_manual_payment: %s (error=%s)\n', (v_result->>'error')='manual_payment_already_transferred', v_result->>'error');

  -- ═══ Claim duplicado (mismo provider+payment_id) ═══
  v_result := claim_reservation_refund(v_res_refund_then_advance, 'full', 5000, 'stripe', 'pi_test_1');
  v_report := v_report || format('T12_claim_duplicado_rechazado: %s (error=%s)\n', NOT (v_result->>'ok')::boolean, v_result->>'error');

  -- ═══ process_refund_reversal: partial_refund_not_supported ═══
  -- (v_res_usd ya tiene 1000 acreditado a credit_pending vía admin_register anterior? no, v_res_usd nunca pasó por confirm_full_payment, no tiene credit_pending)
  -- Usemos v_res_mxn que sí tiene historial de wallet_transactions credit_pending vía... tampoco, en este test no llamamos confirm_full_payment_and_credit_wallet.
  -- Insertamos manualmente una fila credit_pending para simular un pago ya confirmado, en una reserva nueva sin anticipos.
  DECLARE
    v_res_for_refund UUID;
  BEGIN
    INSERT INTO reservations (group_id, client_id, event_date, address, total_price, payment_status, payout_status, status, group_earnings, currency_code)
    VALUES (v_group_id, v_client_id, CURRENT_DATE + 10, 'Test address', 6000, 'paid', 'held', 'confirmed', 5000, 'MXN') RETURNING id INTO v_res_for_refund;

    PERFORM ensure_group_wallet(v_group_id);
    INSERT INTO wallet_transactions (group_wallet_id, group_id, type, amount, reservation_id, description, currency_code)
    VALUES (v_wallet_id, v_group_id, 'credit_pending', 5000, v_res_for_refund, 'simulado para prueba', 'MXN');

    v_result := process_refund_reversal(v_res_for_refund, 'test_refund_1', 2000, NULL);
    v_report := v_report || format('T13_partial_refund_not_supported: %s (error=%s)\n', (v_result->>'error')='partial_refund_not_supported', v_result->>'error');

    v_result := process_refund_reversal(v_res_for_refund, 'test_refund_1', 6000, NULL);
    v_report := v_report || format('T14_refund_completo_pass: %s (reversed=%s currency=%s)\n', (v_result->>'ok')::boolean, v_result->>'reversed', v_result->>'currency');
  END;

  -- ═══ RLS: grupo no puede escribir directo en provider_refund_claims ═══
  EXECUTE 'SET ROLE authenticated';
  PERFORM set_config('request.jwt.claim.sub', v_group_owner::text, true);
  BEGIN
    INSERT INTO provider_refund_claims (reservation_id, group_id, provider, provider_payment_id, mode, currency_code, amount, claimed_by)
    VALUES (v_res_mxn, v_group_id, 'stripe', 'fake_direct_insert', 'full', 'MXN', 100, v_group_owner);
    v_report := v_report || 'T15_grupo_no_puede_insertar_claim_directo: false (INSERT PERMITIDO)' || E'\n';
  EXCEPTION WHEN insufficient_privilege OR others THEN
    v_report := v_report || 'T15_grupo_no_puede_insertar_claim_directo: true' || E'\n';
  END;
  -- Grupo SÍ puede leer sus propios claims
  v_report := v_report || format('T16_grupo_lee_su_claim: %s\n', (SELECT COUNT(*) FROM provider_refund_claims WHERE id = v_claim_id) = 1);
  EXECUTE 'RESET ROLE';
  PERFORM set_config('request.jwt.claim.sub', v_admin_id::text, true);

  -- ═══ Regresión: withdrawals/debit_payout sin cambios ═══
  v_report := v_report || format('T17_withdrawals_sigue_0: %s\n', (SELECT COUNT(*) FROM withdrawals) = 0);

  -- ═══ request_withdrawal: grupo bloqueado ═══
  EXECUTE 'SET ROLE authenticated';
  PERFORM set_config('request.jwt.claim.sub', v_group_owner::text, true);
  v_result := request_withdrawal(100, '123456789012345678', 'BBVA', 'Test');
  v_report := v_report || format('T18_group_self_withdrawal_disabled: %s (error=%s)\n', (v_result->>'error')='group_self_withdrawal_disabled', v_result->>'error');

  -- INSERT/UPDATE directo en withdrawals como group
  BEGIN
    INSERT INTO withdrawals (user_id, amount, status, payout_method) VALUES (v_group_owner, 999999, 'pending', 'spei');
    v_report := v_report || 'T19_group_insert_withdrawals_rechazado: false (INSERT PERMITIDO)' || E'\n';
  EXCEPTION WHEN insufficient_privilege OR others THEN
    v_report := v_report || 'T19_group_insert_withdrawals_rechazado: true' || E'\n';
  END;
  EXECUTE 'RESET ROLE';
  PERFORM set_config('request.jwt.claim.sub', v_admin_id::text, true);

  RAISE EXCEPTION '%', v_report;
END;
$test$;
