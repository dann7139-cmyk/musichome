-- ============================================================
-- sql/532_group_payment_requests_tests.sql — Fase P1D
-- Transaccional, autorevertible. Reutiliza el grupo/owner/cliente reales,
-- crea un grupo sintético "ajeno" para probar aislamiento, y revierte todo.
-- ============================================================

DO $$
DECLARE
  v_group_id   UUID := '83911568-2694-4541-81ae-af1f80bc490e';
  v_owner_id   UUID := '929ba9ba-1dfd-4b76-abf1-18168b1ac1ba';
  v_client_id  UUID := '889e7168-a30a-49c5-a32a-cbeb320d00f8';
  v_admin_id   UUID;
  v_ajeno_group UUID;
  v_wallet_id  UUID;
  v_pending_before_p1d NUMERIC; v_available_before_p1d NUMERIC;
  v_pending_after_p1d  NUMERIC; v_available_after_p1d  NUMERIC;
  v_wd0 INT; v_dp0 INT; v_wd1 INT; v_dp1 INT;
  v_res_h UUID; v_res_j UUID; v_res_liq UUID; v_res_e100 UUID;
  v_out JSONB; v_req1_id UUID; v_req2_id UUID;
  v_report TEXT := '';
BEGIN
  SELECT id INTO v_admin_id FROM profiles WHERE role = 'admin' ORDER BY created_at LIMIT 1;
  SELECT id FROM group_wallets WHERE group_id = v_group_id INTO v_wallet_id;

  INSERT INTO groups (name, owner_id, state, country, is_active)
  VALUES ('__TEST_P1D_AJENO__', v_client_id, 'Jalisco', 'México', false)
  RETURNING id INTO v_ajeno_group;

  v_wd0 := (SELECT count(*) FROM withdrawals);
  v_dp0 := (SELECT count(*) FROM wallet_transactions WHERE type = 'debit_payout');

  -- ── Reservas ──
  INSERT INTO reservations (group_id, client_id, event_date, address, total_price, status, payment_status, payout_status, group_earnings)
  VALUES (v_group_id, v_client_id, '2099-03-01', 'P1D H (elegible)', 4800, 'completed', 'paid', 'released', 4000) RETURNING id INTO v_res_h;

  INSERT INTO reservations (group_id, client_id, event_date, address, total_price, status, payment_status, payout_status, group_earnings)
  VALUES (v_group_id, v_client_id, '2099-03-02', 'P1D J (no released)', 3600, 'completed', 'paid', 'held', 3000) RETURNING id INTO v_res_j;

  INSERT INTO reservations (group_id, client_id, event_date, address, total_price, status, payment_status, payout_status, group_earnings)
  VALUES (v_group_id, v_client_id, '2099-03-03', 'P1D LIQ (ya liquidada)', 2400, 'completed', 'paid', 'released', 2000) RETURNING id INTO v_res_liq;
  -- Simular liquidación ya hecha (kind='final_settlement' del esquema P1C, sin activar lógica de P1E)
  INSERT INTO group_reservation_payments (reservation_id, group_id, amount, kind, wallet_bucket_debited, registered_by)
  VALUES (v_res_liq, v_group_id, 2000, 'final_settlement', 'available', v_admin_id);

  INSERT INTO reservations (group_id, client_id, event_date, address, total_price, status, payment_status, payout_status, group_earnings)
  VALUES (v_group_id, v_client_id, '2099-03-04', 'P1D E100 (100pct anticipado)', 6000, 'completed', 'paid', 'held', 5000) RETURNING id INTO v_res_e100;
  UPDATE reservations SET group_arrived_at = NOW() WHERE id = v_res_e100;

  -- ── Setup dinero (P1C, ya probado) — financiar y consumir ANTES de medir P1D ──
  UPDATE group_wallets SET pending_balance = pending_balance + 5000 WHERE id = v_wallet_id;
  PERFORM set_config('request.jwt.claim.sub', v_admin_id::text, true);
  PERFORM admin_register_group_payment(v_res_e100, 5000, 'advance', NULL, '100pct');
  PERFORM release_group_earnings_atomic(v_res_e100, v_admin_id);

  -- ── Snapshot financiero justo antes de tocar SOLO funciones de P1D ──
  SELECT pending_balance, available_balance INTO v_pending_before_p1d, v_available_before_p1d
  FROM group_wallets WHERE id = v_wallet_id;

  -- ── T_faltan_datos_bancarios (bank_clabe/nombre/titular todos NULL hoy) ──
  PERFORM set_config('request.jwt.claim.sub', v_owner_id::text, true);
  v_out := group_request_payment(v_res_h);
  v_report := v_report || format('T_faltan_datos_bancarios: %s (error=%s)\n',
    (v_out->>'ok') = 'false' AND (v_out->>'error') = 'missing_bank_data', v_out->>'error');

  -- ── T_clabe_sin_nombre_titular (#22) ──
  UPDATE wallets SET bank_clabe = '646180157000000018', bank_name = NULL, account_holder = NULL
  WHERE user_id = v_owner_id;
  v_out := group_request_payment(v_res_h);
  v_report := v_report || format('T_clabe_sin_nombre_titular: %s (error=%s)\n',
    (v_out->>'ok') = 'false' AND (v_out->>'error') = 'missing_bank_data', v_out->>'error');

  -- ── P1B/P1C sigue mostrando H aunque todavía NO exista ninguna solicitud ──
  PERFORM set_config('request.jwt.claim.sub', v_admin_id::text, true);
  v_out := admin_get_pending_group_payments(50);
  v_report := v_report || format('T_p1b_muestra_sin_solicitud: %s (badge=%s)\n', (
    SELECT (i->>'reservation_id')::uuid = v_res_h AND COALESCE((i->>'payment_requested')::boolean, false) = false
    FROM jsonb_array_elements(v_out->'items') i WHERE (i->>'reservation_id')::uuid = v_res_h
  ), (SELECT i->>'payment_requested' FROM jsonb_array_elements(v_out->'items') i WHERE (i->>'reservation_id')::uuid = v_res_h));
  PERFORM set_config('request.jwt.claim.sub', v_owner_id::text, true);

  -- ── Completar datos bancarios (los 3 campos) ──
  UPDATE wallets SET bank_name = 'STP', account_holder = 'Titular Prueba P1D' WHERE user_id = v_owner_id;

  -- ── T_solicita_propia_elegible ──
  v_out := group_request_payment(v_res_h);
  v_report := v_report || format('T_solicita_propia_elegible: %s (already=%s)\n',
    (v_out->>'ok') = 'true', v_out->>'already_requested');
  v_req1_id := (v_out->>'request_id')::uuid;

  -- ── T_duplicado_idempotente ──
  v_out := group_request_payment(v_res_h);
  v_report := v_report || format('T_duplicado_idempotente: %s (mismo_id=%s)\n',
    (v_out->>'already_requested') = 'true', (v_out->>'request_id')::uuid = v_req1_id);
  v_report := v_report || format('T_duplicado_sin_fila_nueva: %s\n',
    (SELECT count(*) FROM group_payment_requests WHERE reservation_id = v_res_h) = 1);

  -- ── T_reserva_ajena (otro grupo intenta) ──
  PERFORM set_config('request.jwt.claim.sub', v_client_id::text, true); -- dueño del grupo ajeno
  v_out := group_request_payment(v_res_h);
  v_report := v_report || format('T_reserva_ajena_rechazada: %s (error=%s)\n',
    (v_out->>'ok') = 'false' AND (v_out->>'error') = 'not_owner', v_out->>'error');
  PERFORM set_config('request.jwt.claim.sub', v_owner_id::text, true);

  -- ── T_no_released ──
  v_out := group_request_payment(v_res_j);
  v_report := v_report || format('T_no_released_rechazada: %s (error=%s)\n',
    (v_out->>'ok') = 'false' AND (v_out->>'error') = 'not_released', v_out->>'error');

  -- ── T_saldo_cero_ya_liquidada ──
  v_out := group_request_payment(v_res_liq);
  v_report := v_report || format('T_saldo_cero_rechazada: %s (error=%s)\n',
    (v_out->>'ok') = 'false' AND (v_out->>'error') = 'no_balance_due', v_out->>'error');

  -- ── T_100pct_anticipado_rechazada ──
  v_out := group_request_payment(v_res_e100);
  v_report := v_report || format('T_100pct_anticipado_rechazada: %s (error=%s)\n',
    (v_out->>'ok') = 'false' AND (v_out->>'error') = 'no_balance_due', v_out->>'error');

  -- ── T_notificacion_admin_creada ──
  v_report := v_report || format('T_notificacion_admin_creada: %s\n', EXISTS (
    SELECT 1 FROM notifications
    WHERE type = 'payment' AND data->>'reservation_id' = v_res_h::text
  ));

  -- ── T_group_id_integridad (#17) ──
  v_report := v_report || format('T_group_id_integridad: %s\n', NOT EXISTS (
    SELECT 1 FROM group_payment_requests gpr
    JOIN reservations r ON r.id = gpr.reservation_id
    WHERE gpr.group_id <> r.group_id
  ));

  -- ── P1B/P1C sigue mostrando la reserva aunque no haya solicitud, y el
  --    badge de H (que SÍ tiene solicitud) es correcto ──
  PERFORM set_config('request.jwt.claim.sub', v_admin_id::text, true);
  v_out := admin_get_pending_group_payments(50);
  v_report := v_report || format('T_p1c_badge_admin_pending_true: %s\n', (
    SELECT (i->>'payment_requested')::boolean = true
    FROM jsonb_array_elements(v_out->'items') i WHERE (i->>'reservation_id')::uuid = v_res_h
  ));

  -- ── T_grupo_ve_su_lista_con_badge_true (#20) ──
  PERFORM set_config('request.jwt.claim.sub', v_owner_id::text, true);
  v_out := group_get_payable_reservations();
  v_report := v_report || format('T_grupo_lista_badge_true: %s\n', (
    SELECT (i->>'payment_requested')::boolean = true
    FROM jsonb_array_elements(v_out->'items') i WHERE (i->>'reservation_id')::uuid = v_res_h
  ));

  -- ── #18/#19/#21: cerrar la solicitud (completed) y verificar que el badge cae ──
  PERFORM set_config('request.jwt.claim.sub', v_admin_id::text, true);
  UPDATE group_payment_requests SET status = 'completed' WHERE id = v_req1_id;

  v_out := admin_get_pending_group_payments(50);
  v_report := v_report || format('T_completed_no_produce_badge_true (#18): %s\n', (
    SELECT COALESCE((i->>'payment_requested')::boolean, false) = false
    FROM jsonb_array_elements(v_out->'items') i WHERE (i->>'reservation_id')::uuid = v_res_h
  ));

  -- ── #21: puede crear una NUEVA pending sin violar el índice único ──
  PERFORM set_config('request.jwt.claim.sub', v_owner_id::text, true);
  v_out := group_request_payment(v_res_h);
  v_req2_id := (v_out->>'request_id')::uuid;
  v_report := v_report || format('T_nueva_pending_tras_completed (#21): %s (nuevo_id_distinto=%s)\n',
    (v_out->>'ok') = 'true' AND (v_out->>'already_requested') = 'false',
    v_req2_id <> v_req1_id);

  -- ── #20 de nuevo: ahora sí debe volver a true con la nueva pending ──
  PERFORM set_config('request.jwt.claim.sub', v_admin_id::text, true);
  v_out := admin_get_pending_group_payments(50);
  v_report := v_report || format('T_pending_nueva_produce_badge_true (#20): %s\n', (
    SELECT (i->>'payment_requested')::boolean = true
    FROM jsonb_array_elements(v_out->'items') i WHERE (i->>'reservation_id')::uuid = v_res_h
  ));

  -- ── #19: cancelled tampoco produce badge ──
  UPDATE group_payment_requests SET status = 'cancelled' WHERE id = v_req2_id;
  v_out := admin_get_pending_group_payments(50);
  v_report := v_report || format('T_cancelled_no_produce_badge_true (#19): %s\n', (
    SELECT COALESCE((i->>'payment_requested')::boolean, false) = false
    FROM jsonb_array_elements(v_out->'items') i WHERE (i->>'reservation_id')::uuid = v_res_h
  ));

  -- ── RLS: el grupo ajeno NO puede leer la solicitud de H ──
  EXECUTE 'SET ROLE authenticated';
  PERFORM set_config('request.jwt.claim.sub', v_client_id::text, true);
  v_report := v_report || format('T_rls_otro_grupo_no_ve_solicitud: %s\n', NOT EXISTS (
    SELECT 1 FROM group_payment_requests WHERE reservation_id = v_res_h
  ));
  -- ── RLS: el admin SÍ puede leerla ──
  PERFORM set_config('request.jwt.claim.sub', v_admin_id::text, true);
  v_report := v_report || format('T_rls_admin_ve_solicitud: %s\n', EXISTS (
    SELECT 1 FROM group_payment_requests WHERE reservation_id = v_res_h
  ));
  EXECUTE 'RESET ROLE';

  -- ── Dinero: snapshot final — SOLO funciones de P1D corrieron desde el snapshot anterior ──
  SELECT pending_balance, available_balance INTO v_pending_after_p1d, v_available_after_p1d
  FROM group_wallets WHERE id = v_wallet_id;
  v_report := v_report || format('T_p1d_no_toca_pending: %s (delta=%s)\n',
    v_pending_after_p1d = v_pending_before_p1d, v_pending_after_p1d - v_pending_before_p1d);
  v_report := v_report || format('T_p1d_no_toca_available: %s (delta=%s)\n',
    v_available_after_p1d = v_available_before_p1d, v_available_after_p1d - v_available_before_p1d);

  v_wd1 := (SELECT count(*) FROM withdrawals);
  v_dp1 := (SELECT count(*) FROM wallet_transactions WHERE type = 'debit_payout');
  v_report := v_report || format('T_sin_withdrawals_nuevos: %s (antes=%s despues=%s)\n', v_wd1 = v_wd0, v_wd0, v_wd1);
  v_report := v_report || format('T_sin_debit_payout_nuevos: %s (antes=%s despues=%s)\n', v_dp1 = v_dp0, v_dp0, v_dp1);

  RAISE EXCEPTION E'\n=== RESULTADOS sql/532 (autorevertido) ===\n%', v_report;
END $$;
