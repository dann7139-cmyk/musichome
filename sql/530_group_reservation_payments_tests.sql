-- ============================================================
-- sql/530_group_reservation_payments_tests.sql
-- Fase P1C — pruebas de admin_register_group_payment() + corrección de
-- release_group_earnings_atomic() + actualización de admin_get_pending_group_payments()
--
-- Transaccional, autorevertible. Usa el grupo/wallet/owner/cliente reales
-- existentes, financia pending_balance con exactamente lo necesario para
-- los casos que sí deben tener éxito, y revierte todo al final.
--
-- Las pruebas de RLS usan EXECUTE 'SET ROLE authenticated' (no basta con
-- set_config del JWT claim: esta conexión corre con privilegios elevados
-- que bypasan RLS por defecto; SET ROLE es necesario para quedar
-- realmente sujeto a las policies, igual que un cliente real via PostgREST).
-- ============================================================

DO $$
DECLARE
  v_group_id  UUID := '83911568-2694-4541-81ae-af1f80bc490e';
  v_owner_id  UUID := '929ba9ba-1dfd-4b76-abf1-18168b1ac1ba';
  v_client_id UUID := '889e7168-a30a-49c5-a32a-cbeb320d00f8';
  v_admin_id  UUID;
  v_wallet_id UUID;
  v_pending0  NUMERIC;
  v_available0 NUMERIC;
  v_res_a UUID; v_res_b UUID; v_res_c UUID; v_res_d UUID; v_res_e UUID;
  v_res_f UUID; v_res_g UUID;
  v_out JSONB;
  v_report TEXT := '';
  v_pending_now NUMERIC;
  v_available_now NUMERIC;
BEGIN
  SELECT id INTO v_admin_id FROM profiles WHERE role = 'admin' ORDER BY created_at LIMIT 1;
  SELECT id, pending_balance, available_balance INTO v_wallet_id, v_pending0, v_available0
  FROM group_wallets WHERE group_id = v_group_id;

  UPDATE group_wallets SET pending_balance = pending_balance + 27000 WHERE id = v_wallet_id;

  INSERT INTO reservations (group_id, client_id, event_date, address, total_price, status, payment_status, payout_status, group_earnings)
  VALUES (v_group_id, v_client_id, '2099-02-01', 'P1C A (0 anticipos)', 6000, 'completed', 'paid', 'held', 5000) RETURNING id INTO v_res_a;

  INSERT INTO reservations (group_id, client_id, event_date, address, total_price, status, payment_status, payout_status, group_earnings)
  VALUES (v_group_id, v_client_id, '2099-02-02', 'P1C B (1 anticipo)', 7200, 'completed', 'paid', 'held', 6000) RETURNING id INTO v_res_b;

  INSERT INTO reservations (group_id, client_id, event_date, address, total_price, status, payment_status, payout_status, group_earnings)
  VALUES (v_group_id, v_client_id, '2099-02-03', 'P1C C (multiples anticipos)', 10800, 'completed', 'paid', 'held', 9000) RETURNING id INTO v_res_c;

  INSERT INTO reservations (group_id, client_id, event_date, address, total_price, status, payment_status, payout_status, group_earnings)
  VALUES (v_group_id, v_client_id, '2099-02-04', 'P1C D (excede)', 4800, 'completed', 'paid', 'held', 4000) RETURNING id INTO v_res_d;

  INSERT INTO reservations (group_id, client_id, event_date, address, total_price, status, payment_status, payout_status, group_earnings)
  VALUES (v_group_id, v_client_id, '2099-02-05', 'P1C E (100 pct anticipado)', 8400, 'completed', 'paid', 'held', 7000) RETURNING id INTO v_res_e;

  INSERT INTO reservations (group_id, client_id, event_date, address, total_price, status, payment_status, payout_status, group_earnings, group_arrived_at)
  VALUES (v_group_id, v_client_id, '2099-02-06', 'P1C F (ya released)', 3600, 'completed', 'paid', 'released', 3000, NOW()) RETURNING id INTO v_res_f;

  INSERT INTO reservations (group_id, client_id, event_date, address, total_price, status, payment_status, payout_status, group_earnings)
  VALUES (v_group_id, v_client_id, '2099-02-07', 'P1C G (bucket insuficiente)', 3600, 'completed', 'paid', 'held', 3000) RETURNING id INTO v_res_g;

  UPDATE reservations SET group_arrived_at = NOW() WHERE id IN (v_res_a, v_res_b, v_res_c, v_res_e);

  PERFORM set_config('request.jwt.claim.sub', v_admin_id::text, true);

  v_out := release_group_earnings_atomic(v_res_a, v_admin_id);
  v_report := v_report || format('T_cero_anticipos_release_normal: %s (released=%s, esperado=5000)\n',
    (v_out->>'released')::numeric = 5000, v_out->>'released');

  v_out := admin_register_group_payment(v_res_b, 2000, 'advance', 'test/receipt1.jpg', 'anticipo 1');
  v_report := v_report || format('T_un_anticipo_ok: %s\n', (v_out->>'ok') = 'true');
  v_out := release_group_earnings_atomic(v_res_b, v_admin_id);
  v_report := v_report || format('T_un_anticipo_release_correcto: %s (released=%s, esperado=4000)\n',
    (v_out->>'released')::numeric = 4000, v_out->>'released');

  PERFORM admin_register_group_payment(v_res_c, 2000, 'advance', NULL, 'a1');
  PERFORM admin_register_group_payment(v_res_c, 3000, 'advance', NULL, 'a2');
  PERFORM admin_register_group_payment(v_res_c, 1000, 'advance', NULL, 'a3');
  v_out := release_group_earnings_atomic(v_res_c, v_admin_id);
  v_report := v_report || format('T_multiples_anticipos_release_correcto: %s (released=%s, esperado=3000)\n',
    (v_out->>'released')::numeric = 3000, v_out->>'released');

  v_out := admin_register_group_payment(v_res_d, 5000, 'advance', NULL, NULL);
  v_report := v_report || format('T_exceso_rechazado: %s (error=%s)\n',
    (v_out->>'ok') = 'false' AND (v_out->>'error') = 'exceeds_group_earnings', v_out->>'error');

  PERFORM admin_register_group_payment(v_res_e, 7000, 'advance', NULL, 'todo');
  v_out := release_group_earnings_atomic(v_res_e, v_admin_id);
  v_report := v_report || format('T_100pct_release_cero: %s (released=%s)\n',
    (v_out->>'released')::numeric = 0, v_out->>'released');
  v_report := v_report || format('T_100pct_sin_wallet_transaction_credit: %s\n',
    NOT EXISTS (SELECT 1 FROM wallet_transactions WHERE reservation_id = v_res_e AND type = 'credit_available'));

  v_out := admin_register_group_payment(v_res_f, 500, 'advance', NULL, NULL);
  v_report := v_report || format('T_despues_de_released_rechazado: %s (error=%s)\n',
    (v_out->>'ok') = 'false' AND (v_out->>'error') = 'payout_status_not_eligible', v_out->>'error');

  v_out := admin_register_group_payment(v_res_g, 3000, 'advance', NULL, NULL);
  v_report := v_report || format('T_bucket_insuficiente_rechazado: %s (error=%s)\n',
    (v_out->>'ok') = 'false' AND (v_out->>'error') = 'insufficient_wallet_bucket', v_out->>'error');

  v_report := v_report || format('T_group_id_integridad: %s\n', NOT EXISTS (
    SELECT 1 FROM group_reservation_payments grp
    JOIN reservations r ON r.id = grp.reservation_id
    WHERE grp.group_id <> r.group_id
  ));

  v_out := admin_get_pending_group_payments(50);
  v_report := v_report || format('T_p1b_excluye_100pct: %s\n',
    NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_out->'items') i WHERE (i->>'reservation_id')::uuid = v_res_e));
  v_report := v_report || format('T_p1b_muestra_saldo_real_B: %s\n', (
    SELECT (i->>'saldo_pendiente')::numeric = 4000 AND (i->>'total_anticipado')::numeric = 2000
    FROM jsonb_array_elements(v_out->'items') i WHERE (i->>'reservation_id')::uuid = v_res_b
  ));

  -- ── Reconciliación (capturada ANTES de tocar SET ROLE) ──
  SELECT pending_balance, available_balance INTO v_pending_now, v_available_now
  FROM group_wallets WHERE id = v_wallet_id;
  v_report := v_report || format('T_reconciliacion_pending: %s (delta_sobre_base=%s, esperado=0)\n',
    (v_pending_now - v_pending0) = 0, v_pending_now - v_pending0);
  v_report := v_report || format('T_reconciliacion_available: %s (delta=%s, esperado=12000)\n',
    (v_available_now - v_available0) = 12000, v_available_now - v_available0);

  -- ── RLS: probar como rol `authenticated` real (esta conexión bypasa RLS por defecto) ──
  EXECUTE 'SET ROLE authenticated';
  PERFORM set_config('request.jwt.claim.sub', v_owner_id::text, true);
  BEGIN
    INSERT INTO group_reservation_payments (reservation_id, group_id, amount, kind, wallet_bucket_debited, registered_by)
    VALUES (v_res_a, v_group_id, 100, 'advance', 'pending', v_owner_id);
    v_report := v_report || 'T_rls_group_insert_rechazado: false (se insertó)' || E'\n';
  EXCEPTION WHEN insufficient_privilege THEN
    v_report := v_report || 'T_rls_group_insert_rechazado: true' || E'\n';
  END;

  PERFORM set_config('request.jwt.claim.sub', v_client_id::text, true);
  BEGIN
    INSERT INTO group_reservation_payments (reservation_id, group_id, amount, kind, wallet_bucket_debited, registered_by)
    VALUES (v_res_a, v_group_id, 100, 'advance', 'pending', v_client_id);
    v_report := v_report || 'T_rls_cliente_insert_rechazado: false (se insertó)' || E'\n';
  EXCEPTION WHEN insufficient_privilege THEN
    v_report := v_report || 'T_rls_cliente_insert_rechazado: true' || E'\n';
  END;
  EXECUTE 'RESET ROLE';

  RAISE EXCEPTION E'\n=== RESULTADOS sql/530 (autorevertido) ===\n%', v_report;
END $$;
