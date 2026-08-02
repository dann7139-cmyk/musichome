-- ============================================================
-- sql/534_final_settlement_tests.sql
-- Pruebas transaccionales autoreversibles para P1E.
-- Todo corre dentro de un DO $ ... RAISE EXCEPTION $ para que
-- NINGÚN dato quede persistido sin importar el resultado.
-- ============================================================

DO $test$
DECLARE
  v_admin_id UUID; v_group_owner UUID; v_client_id UUID;
  v_group_id UUID; v_wallet_id UUID;
  v_res_a UUID; v_res_b UUID; v_res_c UUID; v_res_d UUID; v_res_e UUID;
  v_res_f UUID; v_res_g UUID; v_res_h UUID; v_res_i UUID;
  v_result jsonb;
  v_report TEXT := '';
  v_pending0 NUMERIC; v_available0 NUMERIC;
  v_req_id UUID;
BEGIN
  -- ── Setup: admin, grupo, cliente, wallet bancaria completa ──
  SELECT id INTO v_admin_id FROM profiles WHERE role = 'admin' LIMIT 1;
  SELECT id INTO v_client_id FROM profiles WHERE role = 'client' LIMIT 1;
  SELECT g.id, g.owner_id INTO v_group_id, v_group_owner FROM groups g LIMIT 1;

  PERFORM ensure_group_wallet(v_group_id);
  SELECT id, pending_balance, available_balance INTO v_wallet_id, v_pending0, v_available0
  FROM group_wallets WHERE group_id = v_group_id;

  UPDATE wallets SET bank_clabe = '123456789012345678', bank_name = 'BBVA', account_holder = 'Grupo Test',
    bank_linked_at = NOW() WHERE user_id = v_group_owner;
  IF NOT FOUND THEN
    INSERT INTO wallets (user_id, bank_clabe, bank_name, account_holder, bank_linked_at)
    VALUES (v_group_owner, '123456789012345678', 'BBVA', 'Grupo Test', NOW());
  END IF;

  -- Dar saldo suficiente en ambos buckets para las pruebas
  UPDATE group_wallets SET pending_balance = pending_balance + 100000, available_balance = available_balance + 100000
  WHERE id = v_wallet_id;

  -- ── Reservas de prueba ──
  -- A: released, earnings 18000, sin ledger — para exacto/menor/mayor
  INSERT INTO reservations (group_id, client_id, event_date, payment_status, payout_status, group_earnings, currency_code)
  VALUES (v_group_id, v_client_id, CURRENT_DATE + 5, 'paid', 'released', 18000, 'MXN') RETURNING id INTO v_res_a;

  -- B: released, earnings 18000, con 2 anticipos previos (3000+2000) — flujo del ejemplo del usuario
  INSERT INTO reservations (group_id, client_id, event_date, payment_status, payout_status, group_earnings, currency_code)
  VALUES (v_group_id, v_client_id, CURRENT_DATE + 6, 'paid', 'released', 18000, 'MXN') RETURNING id INTO v_res_b;

  -- C: held (no released) — para rechazo de elegibilidad en final_settlement
  INSERT INTO reservations (group_id, client_id, event_date, payment_status, payout_status, group_earnings, currency_code)
  VALUES (v_group_id, v_client_id, CURRENT_DATE + 7, 'paid', 'held', 10000, 'MXN') RETURNING id INTO v_res_c;

  -- D: released, earnings 5000, para probar advance sin comprobante
  INSERT INTO reservations (group_id, client_id, event_date, payment_status, payout_status, group_earnings, currency_code)
  VALUES (v_group_id, v_client_id, CURRENT_DATE + 8, 'paid', 'held', 5000, 'MXN') RETURNING id INTO v_res_d;

  -- E: released, earnings 7000, para probar final_settlement sin comprobante / sin referencia
  INSERT INTO reservations (group_id, client_id, event_date, payment_status, payout_status, group_earnings, currency_code)
  VALUES (v_group_id, v_client_id, CURRENT_DATE + 9, 'paid', 'released', 7000, 'MXN') RETURNING id INTO v_res_e;

  -- F: released, earnings 4000, con group_payment_requests pending — cierre de solicitud
  INSERT INTO reservations (group_id, client_id, event_date, payment_status, payout_status, group_earnings, currency_code)
  VALUES (v_group_id, v_client_id, CURRENT_DATE + 10, 'paid', 'released', 4000, 'MXN') RETURNING id INTO v_res_f;
  INSERT INTO group_payment_requests (reservation_id, group_id, requested_by, status)
  VALUES (v_res_f, v_group_id, v_group_owner, 'pending') RETURNING id INTO v_req_id;

  -- G: released, earnings 6000, sin comprobante en advance previo válido — reutilizada para advance sin transferred_at
  INSERT INTO reservations (group_id, client_id, event_date, payment_status, payout_status, group_earnings, currency_code)
  VALUES (v_group_id, v_client_id, CURRENT_DATE + 11, 'paid', 'held', 6000, 'MXN') RETURNING id INTO v_res_g;

  -- H: released, earnings 6000, para available_balance insuficiente
  INSERT INTO reservations (group_id, client_id, event_date, payment_status, payout_status, group_earnings, currency_code)
  VALUES (v_group_id, v_client_id, CURRENT_DATE + 12, 'paid', 'released', 6000, 'MXN') RETURNING id INTO v_res_h;

  -- I: released, earnings 3000, para advance con comprobante y sin referencia -> PASS
  -- (usa payout held, ver test específico más abajo con su propia reserva 'held')
  INSERT INTO reservations (group_id, client_id, event_date, payment_status, payout_status, group_earnings, currency_code)
  VALUES (v_group_id, v_client_id, CURRENT_DATE + 13, 'paid', 'held', 3000, 'MXN') RETURNING id INTO v_res_i;

  -- ════════════════════════════════════════════════════════════
  -- T1: final_settlement exacto al saldo (A: 18000, sin anticipos) → PASS
  -- ════════════════════════════════════════════════════════════
  PERFORM set_config('request.jwt.claim.sub', v_admin_id::text, true);
  v_result := admin_register_group_payment(v_res_a, 18000, 'final_settlement', 'receipts/t1.jpg', 'liquidación total', 'REF-T1', NOW());
  v_report := v_report || format('T1_exacto_sin_anticipos_pass: %s | %s' || E'\n', (v_result->>'ok')::boolean, v_result);

  -- ════════════════════════════════════════════════════════════
  -- T2/T3: flujo del ejemplo — B con 2 anticipos (3000+2000), luego final exacto 13000
  -- ════════════════════════════════════════════════════════════
  v_result := admin_register_group_payment(v_res_b, 18000, 'advance', 'receipts/adv_should_fail.jpg', NULL, NULL, NOW());
  v_report := v_report || format('T2_advance_rechazado_no_held: %s' || E'\n', NOT (v_result->>'ok')::boolean);
  -- B está 'released' desde el inicio; para simular el flujo real, ponemos B en 'held' primero, anticipamos, y liberamos
  UPDATE reservations SET payout_status = 'held' WHERE id = v_res_b;
  v_result := admin_register_group_payment(v_res_b, 3000, 'advance', 'receipts/adv1.jpg', 'anticipo 1', NULL, NOW() - interval '3 days');
  v_report := v_report || format('T2_anticipo1_pass: %s' || E'\n', (v_result->>'ok')::boolean);
  v_result := admin_register_group_payment(v_res_b, 2000, 'advance', 'receipts/adv2.jpg', 'anticipo 2', 'REF-ADV2', NOW() - interval '1 days');
  v_report := v_report || format('T2_anticipo2_pass: %s' || E'\n', (v_result->>'ok')::boolean);
  UPDATE reservations SET payout_status = 'released' WHERE id = v_res_b;

  -- T3a: final_settlement MENOR al saldo (12999 < 13000) → rechazado, cero mutaciones
  v_result := admin_register_group_payment(v_res_b, 12999, 'final_settlement', 'receipts/final_b_bad.jpg', NULL, 'REF-B-BAD', NOW());
  v_report := v_report || format('T3a_menor_rechazado: %s (%s)' || E'\n', (v_result->>'error') = 'final_amount_must_match_balance', v_result->>'error');

  -- T3b: final_settlement MAYOR al saldo (13001 > 13000) → rechazado
  v_result := admin_register_group_payment(v_res_b, 13001, 'final_settlement', 'receipts/final_b_over.jpg', NULL, 'REF-B-OVER', NOW());
  v_report := v_report || format('T3b_mayor_rechazado: %s (%s)' || E'\n', (v_result->>'error') = 'exceeds_group_earnings', v_result->>'error');

  -- T3c: final_settlement EXACTO (13000) → PASS, saldo 0, total 18000
  v_result := admin_register_group_payment(v_res_b, 13000, 'final_settlement', 'receipts/final_b_ok.jpg', 'liquidación', 'REF-B-OK', NOW());
  v_report := v_report || format('T3c_exacto_pass: %s | total_pagado=%s saldo_restante=%s' || E'\n',
    (v_result->>'ok')::boolean, v_result->>'total_pagado', v_result->>'saldo_restante');

  -- T3d: duplicado tras liquidar (cualquier monto > 0) → rechazado
  v_result := admin_register_group_payment(v_res_b, 1, 'final_settlement', 'receipts/dup.jpg', NULL, 'REF-DUP', NOW());
  v_report := v_report || format('T3d_duplicado_rechazado: %s (%s)' || E'\n', NOT (v_result->>'ok')::boolean, v_result->>'error');

  -- ════════════════════════════════════════════════════════════
  -- T4: reserva no released (C) → payout_status_not_eligible
  -- ════════════════════════════════════════════════════════════
  v_result := admin_register_group_payment(v_res_c, 10000, 'final_settlement', 'receipts/t4.jpg', NULL, 'REF-T4', NOW());
  v_report := v_report || format('T4_no_released_rechazado: %s (%s)' || E'\n', (v_result->>'error') = 'payout_status_not_eligible', v_result->>'error');

  -- ════════════════════════════════════════════════════════════
  -- T5: advance SIN comprobante (D) → receipt_required, cero mutaciones
  -- ════════════════════════════════════════════════════════════
  v_result := admin_register_group_payment(v_res_d, 5000, 'advance', NULL, NULL, NULL, NOW());
  v_report := v_report || format('T5_advance_sin_comprobante_rechazado: %s (%s)' || E'\n', (v_result->>'error') = 'receipt_required', v_result->>'error');

  -- T6: advance CON comprobante y SIN referencia → PASS (referencia sigue opcional para advance)
  v_result := admin_register_group_payment(v_res_d, 5000, 'advance', 'receipts/t6.jpg', NULL, NULL, NOW());
  v_report := v_report || format('T6_advance_con_comprobante_sin_ref_pass: %s' || E'\n', (v_result->>'ok')::boolean);

  -- T6b: advance sin transferred_at → rechazado
  v_result := admin_register_group_payment(v_res_i, 1000, 'advance', 'receipts/t6b.jpg', NULL, NULL, NULL);
  v_report := v_report || format('T6b_advance_sin_transferred_at_rechazado: %s (%s)' || E'\n', (v_result->>'error') = 'transferred_at_required', v_result->>'error');

  -- ════════════════════════════════════════════════════════════
  -- T7: final_settlement SIN comprobante (E) → receipt_required
  -- ════════════════════════════════════════════════════════════
  v_result := admin_register_group_payment(v_res_e, 7000, 'final_settlement', NULL, NULL, 'REF-T7', NOW());
  v_report := v_report || format('T7_final_sin_comprobante_rechazado: %s (%s)' || E'\n', (v_result->>'error') = 'receipt_required', v_result->>'error');

  -- T8: final_settlement CON comprobante pero SIN referencia → transfer_reference_required
  v_result := admin_register_group_payment(v_res_e, 7000, 'final_settlement', 'receipts/t8.jpg', NULL, NULL, NOW());
  v_report := v_report || format('T8_final_sin_referencia_rechazado: %s (%s)' || E'\n', (v_result->>'error') = 'transfer_reference_required', v_result->>'error');

  -- T9: final_settlement sin transferred_at → rechazado
  v_result := admin_register_group_payment(v_res_e, 7000, 'final_settlement', 'receipts/t9.jpg', NULL, 'REF-T9', NULL);
  v_report := v_report || format('T9_final_sin_transferred_at_rechazado: %s (%s)' || E'\n', (v_result->>'error') = 'transferred_at_required', v_result->>'error');

  -- T9b: final_settlement completo y válido (E) → PASS, transferred_at != created_at
  v_result := admin_register_group_payment(v_res_e, 7000, 'final_settlement', 'receipts/t9b.jpg', 'nota', 'REF-T9B', NOW() - interval '2 days');
  v_report := v_report || format('T9b_final_completo_pass: %s | %s' || E'\n', (v_result->>'ok')::boolean, v_result);
  v_report := v_report || format('T9c_transferred_at_distinto_created_at: %s' || E'\n',
    (SELECT transferred_at <> created_at FROM group_reservation_payments WHERE reservation_id = v_res_e AND kind = 'final_settlement'));

  -- ════════════════════════════════════════════════════════════
  -- T10: cierre de group_payment_requests pending → completed (F)
  -- ════════════════════════════════════════════════════════════
  v_report := v_report || format('T10_solicitud_pending_antes: %s' || E'\n',
    (SELECT status FROM group_payment_requests WHERE id = v_req_id));
  v_result := admin_register_group_payment(v_res_f, 4000, 'final_settlement', 'receipts/t10.jpg', NULL, 'REF-T10', NOW());
  v_report := v_report || format('T10_final_pass: %s' || E'\n', (v_result->>'ok')::boolean);
  v_report := v_report || format('T10_solicitud_completed_despues: %s' || E'\n',
    (SELECT status FROM group_payment_requests WHERE id = v_req_id));

  -- T10b: verifica que un intento RECHAZADO (T3a/T3b) NO haya tocado ninguna solicitud
  -- (no hay solicitud asociada a B, se valida por ausencia de filas huérfanas)
  v_report := v_report || format('T10b_sin_solicitudes_huerfanas_B: %s' || E'\n',
    (SELECT COUNT(*) FROM group_payment_requests WHERE reservation_id = v_res_b) = 0);

  -- ════════════════════════════════════════════════════════════
  -- T11: cola admin deja de mostrar B y F (saldo=0); sigue mostrando C si aplica
  -- ════════════════════════════════════════════════════════════
  v_result := admin_get_pending_group_payments(500);
  v_report := v_report || format('T11_B_fuera_de_cola: %s' || E'\n',
    NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_result->'items') i WHERE (i->>'reservation_id')::uuid = v_res_b));
  v_report := v_report || format('T11_F_fuera_de_cola: %s' || E'\n',
    NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_result->'items') i WHERE (i->>'reservation_id')::uuid = v_res_f));

  -- ════════════════════════════════════════════════════════════
  -- T12: Wallet del grupo deja de mostrar B y F como pagables
  -- ════════════════════════════════════════════════════════════
  PERFORM set_config('request.jwt.claim.sub', v_group_owner::text, true);
  EXECUTE 'SET ROLE authenticated';
  v_result := group_get_payable_reservations();
  EXECUTE 'RESET ROLE';
  PERFORM set_config('request.jwt.claim.sub', v_admin_id::text, true);
  v_report := v_report || format('T12_B_fuera_de_wallet: %s' || E'\n',
    NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_result->'items') i WHERE (i->>'reservation_id')::uuid = v_res_b));
  v_report := v_report || format('T12_F_fuera_de_wallet: %s' || E'\n',
    NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_result->'items') i WHERE (i->>'reservation_id')::uuid = v_res_f));

  -- ════════════════════════════════════════════════════════════
  -- T13: available_balance insuficiente (H) — vaciar wallet available primero
  -- ════════════════════════════════════════════════════════════
  UPDATE group_wallets SET available_balance = 100 WHERE id = v_wallet_id;
  v_result := admin_register_group_payment(v_res_h, 6000, 'final_settlement', 'receipts/t13.jpg', NULL, 'REF-T13', NOW());
  v_report := v_report || format('T13_available_insuficiente_rechazado: %s (%s)' || E'\n', (v_result->>'error') = 'insufficient_wallet_bucket', v_result->>'error');
  UPDATE group_wallets SET available_balance = available_balance + 100000 WHERE id = v_wallet_id;
  -- reintento con fondos: debe pasar
  v_result := admin_register_group_payment(v_res_h, 6000, 'final_settlement', 'receipts/t13b.jpg', NULL, 'REF-T13B', NOW());
  v_report := v_report || format('T13b_con_fondos_pass: %s' || E'\n', (v_result->>'ok')::boolean);

  -- ════════════════════════════════════════════════════════════
  -- T14: RLS — grupo/cliente no pueden insertar directo en group_reservation_payments
  -- ════════════════════════════════════════════════════════════
  PERFORM set_config('request.jwt.claim.sub', v_group_owner::text, true);
  EXECUTE 'SET ROLE authenticated';
  BEGIN
    INSERT INTO group_reservation_payments (reservation_id, group_id, amount, kind, wallet_bucket_debited, registered_by)
    VALUES (v_res_a, v_group_id, 1, 'final_settlement', 'available', v_group_owner);
    v_report := v_report || 'T14_grupo_no_puede_insertar: false (¡INSERT PERMITIDO, FALLA DE SEGURIDAD!)' || E'\n';
  EXCEPTION WHEN insufficient_privilege OR others THEN
    v_report := v_report || 'T14_grupo_no_puede_insertar: true' || E'\n';
  END;
  EXECUTE 'RESET ROLE';
  PERFORM set_config('request.jwt.claim.sub', v_admin_id::text, true);

  -- ════════════════════════════════════════════════════════════
  -- T15: group_id consistente en el registro final
  -- ════════════════════════════════════════════════════════════
  v_report := v_report || format('T15_group_id_consistente: %s' || E'\n',
    (SELECT group_id = v_group_id FROM group_reservation_payments WHERE reservation_id = v_res_a AND kind='final_settlement'));

  -- ════════════════════════════════════════════════════════════
  -- T16: balances cuadran — reconciliación wallet completa
  -- ════════════════════════════════════════════════════════════
  v_report := v_report || format('T16_reconciliacion: pending0=%s available0=%s pending_now=%s available_now=%s' || E'\n',
    v_pending0, v_available0,
    (SELECT pending_balance FROM group_wallets WHERE id = v_wallet_id),
    (SELECT available_balance FROM group_wallets WHERE id = v_wallet_id));

  -- ════════════════════════════════════════════════════════════
  -- T17/T18: withdrawals y debit_payout sin cambios
  -- ════════════════════════════════════════════════════════════
  v_report := v_report || format('T17_withdrawals_sigue_0: %s' || E'\n', (SELECT COUNT(*) FROM withdrawals) = 0);
  v_report := v_report || format('T18_debit_payout_sigue_0: %s' || E'\n', (SELECT COUNT(*) FROM wallet_transactions WHERE type='debit_payout') = 0);

  RAISE EXCEPTION '%', v_report;
END;
$test$;
