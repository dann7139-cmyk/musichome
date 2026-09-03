-- ============================================================
-- sql/555_extra_hours_regression_tests.sql
-- Regresión de horas extra (sql/550-554) — transaccional/autorevertible
-- (mismo patrón que 520/536/537: DO-block que SIEMPRE termina en
-- RAISE EXCEPTION con el reporte completo → Postgres revierte TODO,
-- pase lo que pase. No requiere fases manuales de limpieza como el
-- QA en vivo de sql/553-554 — el rollback es automático e incondicional).
--
-- Cubre: approve_extra_hour_payment_atomic, group_confirm_extra_hours,
-- confirm_cash_extra_payment, release_extra_hours_partial,
-- release_extra_hours_final.
--
-- Usa un grupo temporal aislado (__TEST_EXTRAHOURS_555__) con wallet
-- propia que arranca en 0/0/0/0/0/0, para que las cifras del lado
-- grupo sean exactas y no dependan del estado de ningún grupo real.
-- El wallet del admin SÍ es real/compartido (solo existe 1 admin) —
-- se snapshotea antes de tocar nada y se compara por delta, nunca por
-- valor absoluto.
--
-- NO modifica ninguna función productiva ni ningún otro archivo. Si
-- algo falla, el reporte indica el test — la triage (defecto de test
-- vs bug real) se hace fuera de este archivo, leyendo el código ya
-- auditado en docs/AUDITORIA_QA_EXTRA_HOURS_550_554.md.
-- ============================================================

DO $test555$
DECLARE
  -- actores
  v_admin_id  UUID;
  v_client_id UUID;
  v_owner_id  UUID;
  v_group_id  UUID;
  v_wallet_id UUID;
  v_result    JSONB;
  v_err       TEXT;
  v_report    TEXT := E'\n══════ REPORTE 555 — REGRESIÓN HORAS EXTRA (sql/550-554) ══════\n';

  -- snapshot admin (real/compartido) + acumuladores de expectativa
  v_admin_avail_pre     NUMERIC;
  v_admin_earned_pre    NUMERIC;
  v_admin_avail_usd_pre NUMERIC;
  v_admin_earned_usd_pre NUMERIC;
  v_exp_gw_avail    NUMERIC := 0;
  v_exp_gw_earned   NUMERIC := 0;
  v_exp_admin_delta NUMERIC := 0;

  -- reservas / extra_hours — sección A
  ra1 UUID; ea1 UUID;
  ra2 UUID; ea2 UUID;
  ra3 UUID; ea3 UUID;
  ra4 UUID; ea4 UUID;
  ra5 UUID; ea5 UUID;
  ra7 UUID; ea7 UUID;
  -- sección B
  rb1 UUID; eb1 UUID;
  rb3 UUID; eb3 UUID;
  rb4 UUID; eb4 UUID;
  rb5 UUID; eb5 UUID;
  -- sección C
  rc1 UUID; ec1 UUID;
  rc3 UUID; ec3 UUID;
  rc4 UUID; ec4 UUID;
  -- sección G
  rg1 UUID; eg1 UUID;

  -- scratch
  v_status  TEXT;
  v_payout  TEXT;
  v_action  TEXT;
  v_pre_status  TEXT;
  v_pre_payout  TEXT;
  v_post_status TEXT;
  v_post_payout TEXT;
  v_wt_count  INT;
  v_log_count INT;
  v_client_bal NUMERIC;
  v_c1_cash_confirmed_at TIMESTAMPTZ;
  v_wt_snapshot_before INT;
  v_wt_snapshot_after  INT;
  v_gw_avail_snapshot  NUMERIC;
  v_gw_avail_after     NUMERIC;
  v_release_result JSONB;
  v_final_gw   RECORD;
  v_final_admin RECORD;
  v_admin_avail_check NUMERIC;
BEGIN
  ------------------------------------------------------------------
  -- SETUP
  ------------------------------------------------------------------
  v_admin_id := public.get_platform_admin_id();
  SELECT id INTO v_client_id FROM profiles WHERE role = 'client' ORDER BY created_at LIMIT 1;
  SELECT owner_id INTO v_owner_id FROM groups WHERE owner_id IS NOT NULL LIMIT 1;

  INSERT INTO groups (name, owner_id, state, country, is_active)
  VALUES ('__TEST_EXTRAHOURS_555__', v_owner_id, 'Jalisco', 'México', false)
  RETURNING id INTO v_group_id;

  PERFORM public.ensure_group_wallet(v_group_id);
  SELECT id INTO v_wallet_id FROM group_wallets WHERE group_id = v_group_id;

  SELECT available_balance, total_earned, available_balance_usd, total_earned_usd
  INTO   v_admin_avail_pre, v_admin_earned_pre, v_admin_avail_usd_pre, v_admin_earned_usd_pre
  FROM   wallets WHERE user_id = v_admin_id;

  ------------------------------------------------------------------
  -- SECCIÓN A: approve_extra_hour_payment_atomic
  ------------------------------------------------------------------

  -- A1: rama efectivo
  INSERT INTO reservations (group_id, client_id, event_date, address, total_price, status, currency_code, client_available_balance)
  VALUES (v_group_id, v_client_id, CURRENT_DATE, 'T', 500, 'completed', 'MXN', 5000)
  RETURNING id INTO ra1;
  INSERT INTO extra_hours (reservation_id, hours_added, price_per_hour, total_extra_cost, platform_commission, group_extra_earnings, status, is_cash_payment, currency_code)
  VALUES (ra1, 1, 300, 300, 0, 300, 'pending', TRUE, 'MXN')
  RETURNING id INTO ea1;

  PERFORM set_config('request.jwt.claim.sub', v_client_id::text, true);
  v_result := public.approve_extra_hour_payment_atomic(ea1);

  SELECT status, payout_status INTO v_status, v_payout FROM extra_hours WHERE id = ea1;
  v_report := v_report || format('A1_status_paid: %s\n', v_status = 'paid');
  v_report := v_report || format('A1_payout_released: %s\n', v_payout = 'released');
  v_wt_count := (SELECT COUNT(*) FROM wallet_transactions WHERE reservation_id = ra1);
  v_report := v_report || format('A1_cero_wallet_transactions: %s (count=%s)\n', v_wt_count = 0, v_wt_count);
  SELECT COUNT(*), MAX(action) INTO v_log_count, v_action FROM financial_audit_logs WHERE entity_id = ea1;
  v_report := v_report || format('A1_un_audit_log_cash: %s (count=%s action=%s)\n', v_log_count = 1 AND v_action = 'extra_approved_cash', v_log_count, v_action);
  SELECT client_available_balance INTO v_client_bal FROM reservations WHERE id = ra1;
  v_report := v_report || format('A1_saldo_cliente_sin_cambio: %s (bal=%s)\n', v_client_bal = 5000, v_client_bal);

  -- A2: rama saldo
  INSERT INTO reservations (group_id, client_id, event_date, address, total_price, status, currency_code, client_available_balance)
  VALUES (v_group_id, v_client_id, CURRENT_DATE, 'T', 500, 'completed', 'MXN', 5000)
  RETURNING id INTO ra2;
  INSERT INTO extra_hours (reservation_id, hours_added, price_per_hour, total_extra_cost, platform_commission, group_extra_earnings, status, is_cash_payment, currency_code)
  VALUES (ra2, 1, 200, 200, 40, 160, 'pending', FALSE, 'MXN')
  RETURNING id INTO ea2;

  PERFORM set_config('request.jwt.claim.sub', v_client_id::text, true);
  v_result := public.approve_extra_hour_payment_atomic(ea2);

  SELECT status, payout_status INTO v_status, v_payout FROM extra_hours WHERE id = ea2;
  v_report := v_report || format('A2_status_paid: %s\n', v_status = 'paid');
  v_report := v_report || format('A2_payout_released: %s\n', v_payout = 'released');
  SELECT client_available_balance INTO v_client_bal FROM reservations WHERE id = ra2;
  v_report := v_report || format('A2_saldo_cliente_descontado_una_vez: %s (bal=%s esperado=4800)\n', v_client_bal = 4800, v_client_bal);
  v_wt_count := (SELECT COUNT(*) FROM wallet_transactions WHERE reservation_id = ra2);
  v_report := v_report || format('A2_dos_wallet_transactions: %s (count=%s)\n', v_wt_count = 2, v_wt_count);
  SELECT COUNT(*), MAX(action) INTO v_log_count, v_action FROM financial_audit_logs WHERE entity_id = ea2;
  v_report := v_report || format('A2_un_audit_log_balance: %s (count=%s action=%s)\n', v_log_count = 1 AND v_action = 'extra_approved_balance', v_log_count, v_action);
  v_exp_gw_avail    := v_exp_gw_avail + 160;
  v_exp_gw_earned   := v_exp_gw_earned + 160;
  v_exp_admin_delta := v_exp_admin_delta + 40;

  -- A3: saldo insuficiente
  INSERT INTO reservations (group_id, client_id, event_date, address, total_price, status, currency_code, client_available_balance)
  VALUES (v_group_id, v_client_id, CURRENT_DATE, 'T', 500, 'completed', 'MXN', 50)
  RETURNING id INTO ra3;
  INSERT INTO extra_hours (reservation_id, hours_added, price_per_hour, total_extra_cost, platform_commission, group_extra_earnings, status, is_cash_payment, currency_code)
  VALUES (ra3, 1, 200, 200, 40, 160, 'pending', FALSE, 'MXN')
  RETURNING id INTO ea3;

  SELECT status, payout_status INTO v_pre_status, v_pre_payout FROM extra_hours WHERE id = ea3;
  v_err := NULL;
  PERFORM set_config('request.jwt.claim.sub', v_client_id::text, true);
  BEGIN
    v_result := public.approve_extra_hour_payment_atomic(ea3);
  EXCEPTION WHEN OTHERS THEN
    v_err := SQLERRM;
  END;
  v_report := v_report || format('A3_saldo_insuficiente_excepcion: %s (err=%s)\n', v_err ILIKE '%Saldo insuficiente%', v_err);
  SELECT status, payout_status INTO v_post_status, v_post_payout FROM extra_hours WHERE id = ea3;
  v_report := v_report || format('A3_sin_residuo: %s\n', v_post_status = v_pre_status AND v_post_payout = v_pre_payout);

  -- A4: moneda no soportada
  INSERT INTO reservations (group_id, client_id, event_date, address, total_price, status, currency_code, client_available_balance)
  VALUES (v_group_id, v_client_id, CURRENT_DATE, 'T', 500, 'completed', 'MXN', 5000)
  RETURNING id INTO ra4;
  INSERT INTO extra_hours (reservation_id, hours_added, price_per_hour, total_extra_cost, platform_commission, group_extra_earnings, status, is_cash_payment, currency_code)
  VALUES (ra4, 1, 200, 200, 40, 160, 'pending', FALSE, NULL)
  RETURNING id INTO ea4;

  v_err := NULL;
  PERFORM set_config('request.jwt.claim.sub', v_client_id::text, true);
  BEGIN
    v_result := public.approve_extra_hour_payment_atomic(ea4);
  EXCEPTION WHEN OTHERS THEN
    v_err := SQLERRM;
  END;
  v_report := v_report || format('A4_moneda_no_soportada_excepcion: %s (err=%s)\n', v_err ILIKE '%unsupported_currency%', v_err);

  -- A5: caller no es el cliente de la reserva
  INSERT INTO reservations (group_id, client_id, event_date, address, total_price, status, currency_code, client_available_balance)
  VALUES (v_group_id, v_client_id, CURRENT_DATE, 'T', 500, 'completed', 'MXN', 5000)
  RETURNING id INTO ra5;
  INSERT INTO extra_hours (reservation_id, hours_added, price_per_hour, total_extra_cost, platform_commission, group_extra_earnings, status, is_cash_payment, currency_code)
  VALUES (ra5, 1, 200, 200, 40, 160, 'pending', FALSE, 'MXN')
  RETURNING id INTO ea5;

  v_err := NULL;
  PERFORM set_config('request.jwt.claim.sub', v_owner_id::text, true);  -- owner, no el cliente
  BEGIN
    v_result := public.approve_extra_hour_payment_atomic(ea5);
  EXCEPTION WHEN OTHERS THEN
    v_err := SQLERRM;
  END;
  v_report := v_report || format('A5_caller_no_cliente_excepcion: %s (err=%s)\n', v_err ILIKE '%unauthorized%', v_err);

  -- A6: 2ª llamada sobre fila ya 'paid' (guard preexistente, sin cambios de sql/550)
  PERFORM set_config('request.jwt.claim.sub', v_client_id::text, true);
  v_result := public.approve_extra_hour_payment_atomic(ea1);
  v_report := v_report || format('A6_skip_already_paid: %s (result=%s)\n', (v_result->>'skipped')::boolean = true AND v_result->>'reason' = 'already_paid', v_result::text);
  SELECT COUNT(*) INTO v_log_count FROM financial_audit_logs WHERE entity_id = ea1;
  v_report := v_report || format('A6_sin_log_duplicado: %s (count=%s)\n', v_log_count = 1, v_log_count);

  -- A7: hora extra rechazada
  INSERT INTO reservations (group_id, client_id, event_date, address, total_price, status, currency_code, client_available_balance)
  VALUES (v_group_id, v_client_id, CURRENT_DATE, 'T', 500, 'completed', 'MXN', 5000)
  RETURNING id INTO ra7;
  INSERT INTO extra_hours (reservation_id, hours_added, price_per_hour, total_extra_cost, platform_commission, group_extra_earnings, status, is_cash_payment, currency_code)
  VALUES (ra7, 1, 200, 200, 40, 160, 'rejected', FALSE, 'MXN')
  RETURNING id INTO ea7;

  v_err := NULL;
  PERFORM set_config('request.jwt.claim.sub', v_client_id::text, true);
  BEGIN
    v_result := public.approve_extra_hour_payment_atomic(ea7);
  EXCEPTION WHEN OTHERS THEN
    v_err := SQLERRM;
  END;
  v_report := v_report || format('A7_rechazada_excepcion: %s (err=%s)\n', v_err ILIKE '%rechazada%', v_err);

  ------------------------------------------------------------------
  -- SECCIÓN B: group_confirm_extra_hours
  ------------------------------------------------------------------

  -- B1: rama saldo, 1ª llamada
  INSERT INTO reservations (group_id, client_id, event_date, address, total_price, status, currency_code, client_available_balance)
  VALUES (v_group_id, v_client_id, CURRENT_DATE, 'T', 500, 'completed', 'MXN', 1000)
  RETURNING id INTO rb1;
  INSERT INTO extra_hours (reservation_id, hours_added, price_per_hour, total_extra_cost, platform_commission, group_extra_earnings, status, is_cash_payment, currency_code)
  VALUES (rb1, 1, 150, 150, 30, 120, 'awaiting_group_confirmation', FALSE, 'MXN')
  RETURNING id INTO eb1;

  PERFORM set_config('request.jwt.claim.sub', v_owner_id::text, true);
  v_result := public.group_confirm_extra_hours(eb1);

  SELECT status, payout_status INTO v_status, v_payout FROM extra_hours WHERE id = eb1;
  v_report := v_report || format('B1_status_accepted: %s\n', v_status = 'accepted');
  v_report := v_report || format('B1_payout_released: %s\n', v_payout = 'released');
  SELECT client_available_balance INTO v_client_bal FROM reservations WHERE id = rb1;
  v_report := v_report || format('B1_saldo_cliente_descontado_una_vez: %s (bal=%s esperado=850)\n', v_client_bal = 850, v_client_bal);
  v_wt_count := (SELECT COUNT(*) FROM wallet_transactions WHERE reservation_id = rb1);
  v_report := v_report || format('B1_dos_wallet_transactions: %s (count=%s)\n', v_wt_count = 2, v_wt_count);
  SELECT COUNT(*), MAX(action) INTO v_log_count, v_action FROM financial_audit_logs WHERE entity_id = eb1;
  v_report := v_report || format('B1_un_audit_log: %s (count=%s action=%s)\n', v_log_count = 1 AND v_action = 'group_confirmed_balance', v_log_count, v_action);
  v_exp_gw_avail    := v_exp_gw_avail + 120;
  v_exp_gw_earned   := v_exp_gw_earned + 120;
  v_exp_admin_delta := v_exp_admin_delta + 30;

  -- B2: 2ª llamada sobre la misma fila (idempotencia — guard preexistente)
  PERFORM set_config('request.jwt.claim.sub', v_owner_id::text, true);
  v_result := public.group_confirm_extra_hours(eb1);
  v_report := v_report || format('B2_skip_already_processed: %s (result=%s)\n', (v_result->>'skipped')::boolean = true AND v_result->>'reason' = 'already_processed', v_result::text);
  SELECT client_available_balance INTO v_client_bal FROM reservations WHERE id = rb1;
  v_report := v_report || format('B2_saldo_sin_cambio: %s (bal=%s)\n', v_client_bal = 850, v_client_bal);
  SELECT COUNT(*) INTO v_log_count FROM financial_audit_logs WHERE entity_id = eb1;
  v_report := v_report || format('B2_sin_log_duplicado: %s (count=%s)\n', v_log_count = 1, v_log_count);

  -- B3: caller no es el owner del grupo
  INSERT INTO reservations (group_id, client_id, event_date, address, total_price, status, currency_code, client_available_balance)
  VALUES (v_group_id, v_client_id, CURRENT_DATE, 'T', 500, 'completed', 'MXN', 1000)
  RETURNING id INTO rb3;
  INSERT INTO extra_hours (reservation_id, hours_added, price_per_hour, total_extra_cost, platform_commission, group_extra_earnings, status, is_cash_payment, currency_code)
  VALUES (rb3, 1, 150, 150, 30, 120, 'awaiting_group_confirmation', FALSE, 'MXN')
  RETURNING id INTO eb3;

  PERFORM set_config('request.jwt.claim.sub', v_client_id::text, true);  -- cliente, no el owner
  v_result := public.group_confirm_extra_hours(eb3);
  v_report := v_report || format('B3_unauthorized: %s (result=%s)\n', (v_result->>'ok')::boolean = false AND (v_result->>'error') ILIKE '%unauthorized%', v_result::text);

  -- B4: saldo insuficiente
  INSERT INTO reservations (group_id, client_id, event_date, address, total_price, status, currency_code, client_available_balance)
  VALUES (v_group_id, v_client_id, CURRENT_DATE, 'T', 500, 'completed', 'MXN', 10)
  RETURNING id INTO rb4;
  INSERT INTO extra_hours (reservation_id, hours_added, price_per_hour, total_extra_cost, platform_commission, group_extra_earnings, status, is_cash_payment, currency_code)
  VALUES (rb4, 1, 200, 200, 40, 160, 'awaiting_group_confirmation', FALSE, 'MXN')
  RETURNING id INTO eb4;

  PERFORM set_config('request.jwt.claim.sub', v_owner_id::text, true);
  v_result := public.group_confirm_extra_hours(eb4);
  v_report := v_report || format('B4_saldo_insuficiente: %s (result=%s)\n', (v_result->>'ok')::boolean = false AND v_result->>'error' = 'saldo_insuficiente', v_result::text);

  -- B5: moneda no soportada
  INSERT INTO reservations (group_id, client_id, event_date, address, total_price, status, currency_code, client_available_balance)
  VALUES (v_group_id, v_client_id, CURRENT_DATE, 'T', 500, 'completed', 'MXN', 1000)
  RETURNING id INTO rb5;
  INSERT INTO extra_hours (reservation_id, hours_added, price_per_hour, total_extra_cost, platform_commission, group_extra_earnings, status, is_cash_payment, currency_code)
  VALUES (rb5, 1, 200, 200, 40, 160, 'awaiting_group_confirmation', FALSE, NULL)
  RETURNING id INTO eb5;

  PERFORM set_config('request.jwt.claim.sub', v_owner_id::text, true);
  v_result := public.group_confirm_extra_hours(eb5);
  v_report := v_report || format('B5_moneda_no_soportada: %s (result=%s)\n', (v_result->>'ok')::boolean = false AND v_result->>'error' = 'unsupported_currency', v_result::text);

  ------------------------------------------------------------------
  -- SECCIÓN C: confirm_cash_extra_payment
  ------------------------------------------------------------------

  -- C1: 1ª llamada
  INSERT INTO reservations (group_id, client_id, event_date, address, total_price, status, currency_code)
  VALUES (v_group_id, v_client_id, CURRENT_DATE, 'T', 500, 'completed', 'MXN')
  RETURNING id INTO rc1;
  INSERT INTO extra_hours (reservation_id, hours_added, price_per_hour, total_extra_cost, platform_commission, group_extra_earnings, status, is_cash_payment, currency_code)
  VALUES (rc1, 1, 250, 250, 0, 250, 'pending', FALSE, 'MXN')
  RETURNING id INTO ec1;

  PERFORM set_config('request.jwt.claim.sub', v_owner_id::text, true);
  PERFORM public.confirm_cash_extra_payment(ec1, rc1);

  SELECT status, payout_status, cash_confirmed_at INTO v_status, v_payout, v_c1_cash_confirmed_at FROM extra_hours WHERE id = ec1;
  v_report := v_report || format('C1_status_paid: %s\n', v_status = 'paid');
  v_report := v_report || format('C1_payout_released: %s\n', v_payout = 'released');
  v_report := v_report || format('C1_cash_confirmed_at_fijado: %s (valor=%s)\n', v_c1_cash_confirmed_at IS NOT NULL, v_c1_cash_confirmed_at);
  SELECT COUNT(*), MAX(action) INTO v_log_count, v_action FROM financial_audit_logs WHERE entity_id = ec1;
  v_report := v_report || format('C1_un_audit_log: %s (count=%s action=%s)\n', v_log_count = 1 AND v_action = 'cash_extra_confirmed', v_log_count, v_action);
  v_wt_count := (SELECT COUNT(*) FROM wallet_transactions WHERE reservation_id = rc1);
  v_report := v_report || format('C1_cero_wallet_transactions: %s (count=%s)\n', v_wt_count = 0, v_wt_count);

  -- C2: 2ª llamada sobre la misma fila — verifica el fix de idempotencia sql/554
  PERFORM set_config('request.jwt.claim.sub', v_owner_id::text, true);
  PERFORM public.confirm_cash_extra_payment(ec1, rc1);

  v_report := v_report || format('C2_cash_confirmed_at_sin_cambio: %s\n',
    (SELECT cash_confirmed_at FROM extra_hours WHERE id = ec1) = v_c1_cash_confirmed_at);
  SELECT COUNT(*) INTO v_log_count FROM financial_audit_logs WHERE entity_id = ec1;
  v_report := v_report || format('C2_sin_log_duplicado: %s (count=%s)\n', v_log_count = 1, v_log_count);
  v_wt_count := (SELECT COUNT(*) FROM wallet_transactions WHERE reservation_id = rc1);
  v_report := v_report || format('C2_cero_wallet_transactions: %s (count=%s)\n', v_wt_count = 0, v_wt_count);

  -- C3: caller no autorizado (cliente, no parte del grupo)
  INSERT INTO reservations (group_id, client_id, event_date, address, total_price, status, currency_code)
  VALUES (v_group_id, v_client_id, CURRENT_DATE, 'T', 500, 'completed', 'MXN')
  RETURNING id INTO rc3;
  INSERT INTO extra_hours (reservation_id, hours_added, price_per_hour, total_extra_cost, platform_commission, group_extra_earnings, status, is_cash_payment, currency_code)
  VALUES (rc3, 1, 250, 250, 0, 250, 'pending', FALSE, 'MXN')
  RETURNING id INTO ec3;

  v_err := NULL;
  PERFORM set_config('request.jwt.claim.sub', v_client_id::text, true);  -- cliente, no parte del grupo
  BEGIN
    PERFORM public.confirm_cash_extra_payment(ec3, rc3);
  EXCEPTION WHEN OTHERS THEN
    v_err := SQLERRM;
  END;
  v_report := v_report || format('C3_unauthorized_excepcion: %s (err=%s)\n', v_err ILIKE '%unauthorized%', v_err);

  -- C4: id/reservation_id desalineados (extra_hour real, pero de OTRA reserva)
  INSERT INTO reservations (group_id, client_id, event_date, address, total_price, status, currency_code)
  VALUES (v_group_id, v_client_id, CURRENT_DATE, 'T', 500, 'completed', 'MXN')
  RETURNING id INTO rc4;
  INSERT INTO extra_hours (reservation_id, hours_added, price_per_hour, total_extra_cost, platform_commission, group_extra_earnings, status, is_cash_payment, currency_code)
  VALUES (rc4, 1, 250, 250, 0, 250, 'pending', FALSE, 'MXN')
  RETURNING id INTO ec4;

  v_err := NULL;
  PERFORM set_config('request.jwt.claim.sub', v_owner_id::text, true);  -- autorizado (mismo grupo), pero IDs desalineados
  BEGIN
    PERFORM public.confirm_cash_extra_payment(ec4, rc1);  -- ec4 pertenece a rc4, no a rc1
  EXCEPTION WHEN OTHERS THEN
    v_err := SQLERRM;
  END;
  v_report := v_report || format('C4_no_encontrada_excepcion: %s (err=%s)\n', v_err ILIKE '%no encontrada%', v_err);
  SELECT status INTO v_status FROM extra_hours WHERE id = ec4;
  v_report := v_report || format('C4_ec4_sin_tocar: %s (status=%s)\n', v_status = 'pending', v_status);

  ------------------------------------------------------------------
  -- SECCIÓN D: invariante payout_status='released' en las 3 rutas exitosas
  ------------------------------------------------------------------
  v_report := v_report || format('D1_payout_released_en_las_3_rutas: %s\n',
    (SELECT payout_status FROM extra_hours WHERE id = ea2) = 'released' AND
    (SELECT payout_status FROM extra_hours WHERE id = eb1) = 'released' AND
    (SELECT payout_status FROM extra_hours WHERE id = ec1) = 'released'
  );

  ------------------------------------------------------------------
  -- SECCIÓN E: no doble crédito + funciones de liberación como no-op
  ------------------------------------------------------------------
  SELECT available_balance INTO v_gw_avail_snapshot
  FROM group_wallets WHERE id = v_wallet_id;
  v_report := v_report || format('E1_group_wallets_available_exacto: %s (real=%s esperado=%s)\n', v_gw_avail_snapshot = v_exp_gw_avail, v_gw_avail_snapshot, v_exp_gw_avail);

  SELECT available_balance INTO v_admin_avail_check
  FROM wallets WHERE user_id = v_admin_id;
  v_report := v_report || format('E2_admin_wallet_delta_exacto: %s (real=%s esperado=%s)\n',
    v_admin_avail_check = v_admin_avail_pre + v_exp_admin_delta,
    v_admin_avail_check, v_admin_avail_pre + v_exp_admin_delta);

  v_wt_snapshot_before := (SELECT COUNT(*) FROM wallet_transactions WHERE reservation_id IN (ra1, ra2, rb1, rc1));
  SELECT available_balance INTO v_gw_avail_snapshot FROM group_wallets WHERE id = v_wallet_id;

  v_release_result := public.release_extra_hours_partial(ra1);
  v_report := v_report || format('E3_partial_ra1_cash_0_released: %s (result=%s)\n', (v_release_result->>'released')::int = 0, v_release_result::text);
  v_release_result := public.release_extra_hours_partial(ra2);
  v_report := v_report || format('E3_partial_ra2_balance_0_released: %s (result=%s)\n', (v_release_result->>'released')::int = 0, v_release_result::text);
  v_release_result := public.release_extra_hours_partial(rb1);
  v_report := v_report || format('E3_partial_rb1_0_released: %s (result=%s)\n', (v_release_result->>'released')::int = 0, v_release_result::text);
  v_release_result := public.release_extra_hours_partial(rc1);
  v_report := v_report || format('E3_partial_rc1_cash_0_released: %s (result=%s)\n', (v_release_result->>'released')::int = 0, v_release_result::text);

  v_release_result := public.release_extra_hours_final(ra1);
  v_report := v_report || format('E4_final_ra1_cash_0_released: %s (result=%s)\n', (v_release_result->>'released')::int = 0, v_release_result::text);
  v_release_result := public.release_extra_hours_final(ra2);
  v_report := v_report || format('E4_final_ra2_balance_0_released: %s (result=%s)\n', (v_release_result->>'released')::int = 0, v_release_result::text);
  v_release_result := public.release_extra_hours_final(rb1);
  v_report := v_report || format('E4_final_rb1_0_released: %s (result=%s)\n', (v_release_result->>'released')::int = 0, v_release_result::text);
  v_release_result := public.release_extra_hours_final(rc1);
  v_report := v_report || format('E4_final_rc1_cash_0_released: %s (result=%s)\n', (v_release_result->>'released')::int = 0, v_release_result::text);

  v_wt_snapshot_after := (SELECT COUNT(*) FROM wallet_transactions WHERE reservation_id IN (ra1, ra2, rb1, rc1));
  v_report := v_report || format('E5_cero_wallet_transactions_nuevas_por_release: %s (antes=%s despues=%s)\n', v_wt_snapshot_after = v_wt_snapshot_before, v_wt_snapshot_before, v_wt_snapshot_after);

  SELECT available_balance INTO v_gw_avail_after FROM group_wallets WHERE id = v_wallet_id;
  v_report := v_report || format('E6_cero_cambio_group_wallets_por_release: %s (antes=%s despues=%s)\n', v_gw_avail_after = v_gw_avail_snapshot, v_gw_avail_snapshot, v_gw_avail_after);

  ------------------------------------------------------------------
  -- SECCIÓN F: rutas de efectivo nunca tocan wallets (chequeo consolidado, al final)
  ------------------------------------------------------------------
  v_wt_count := (SELECT COUNT(*) FROM wallet_transactions WHERE reservation_id IN (ra1, rc1));
  v_report := v_report || format('F1_rutas_efectivo_cero_wallet_transactions_final: %s (count=%s)\n', v_wt_count = 0, v_wt_count);

  ------------------------------------------------------------------
  -- SECCIÓN G: errores / autorización / rollback
  ------------------------------------------------------------------

  -- G1: sin sesión (auth.uid() NULL)
  INSERT INTO reservations (group_id, client_id, event_date, address, total_price, status, currency_code, client_available_balance)
  VALUES (v_group_id, v_client_id, CURRENT_DATE, 'T', 500, 'completed', 'MXN', 5000)
  RETURNING id INTO rg1;
  INSERT INTO extra_hours (reservation_id, hours_added, price_per_hour, total_extra_cost, platform_commission, group_extra_earnings, status, is_cash_payment, currency_code)
  VALUES (rg1, 1, 200, 200, 40, 160, 'pending', FALSE, 'MXN')
  RETURNING id INTO eg1;

  SELECT status, payout_status INTO v_pre_status, v_pre_payout FROM extra_hours WHERE id = eg1;
  v_err := NULL;
  -- se limpian AMBAS variables que auth.uid() consulta (claim.sub y claims
  -- completos) — no basta con vaciar una si la sesión ya trae la otra seteada
  PERFORM set_config('request.jwt.claim.sub', '', true);
  PERFORM set_config('request.jwt.claims', '', true);
  BEGIN
    v_result := public.approve_extra_hour_payment_atomic(eg1);
  EXCEPTION WHEN OTHERS THEN
    v_err := SQLERRM;
  END;
  PERFORM set_config('request.jwt.claim.sub', v_client_id::text, true);  -- restaurar caller inmediatamente
  v_report := v_report || format('G1_sin_sesion_excepcion: %s (err=%s)\n', v_err ILIKE '%sesión requerida%', v_err);
  SELECT status, payout_status INTO v_post_status, v_post_payout FROM extra_hours WHERE id = eg1;
  v_report := v_report || format('G1_sin_residuo: %s\n', v_post_status = v_pre_status AND v_post_payout = v_pre_payout);

  -- G2: ver C4 (id/reservation_id desalineados) — referenciado aquí por completitud
  v_report := v_report || 'G2_ver_C4_no_encontrada: cubierto arriba' || E'\n';

  -- G3: consolidado — ninguno de los intentos que debían fallar (A3,A4,A5,A7,C3,C4,G1) dejó residuo
  v_report := v_report || format('G3_ningun_intento_fallido_dejo_residuo: %s\n',
    (SELECT status FROM extra_hours WHERE id = ea3) = 'pending' AND (SELECT payout_status FROM extra_hours WHERE id = ea3) = 'held' AND
    (SELECT status FROM extra_hours WHERE id = ea4) = 'pending' AND (SELECT payout_status FROM extra_hours WHERE id = ea4) = 'held' AND
    (SELECT status FROM extra_hours WHERE id = ea5) = 'pending' AND (SELECT payout_status FROM extra_hours WHERE id = ea5) = 'held' AND
    (SELECT status FROM extra_hours WHERE id = ea7) = 'rejected' AND
    (SELECT status FROM extra_hours WHERE id = ec3) = 'pending' AND
    (SELECT status FROM extra_hours WHERE id = ec4) = 'pending' AND
    (SELECT status FROM extra_hours WHERE id = eg1) = 'pending' AND (SELECT payout_status FROM extra_hours WHERE id = eg1) = 'held'
  );

  ------------------------------------------------------------------
  -- INVARIANTES FINALES
  ------------------------------------------------------------------
  SELECT available_balance, total_earned, pending_balance, pending_balance_usd, available_balance_usd, total_earned_usd
  INTO   v_final_gw
  FROM   group_wallets WHERE id = v_wallet_id;

  v_report := v_report || format('INVARIANTE_gw_available_exacto: %s (real=%s esperado=%s)\n', v_final_gw.available_balance = v_exp_gw_avail, v_final_gw.available_balance, v_exp_gw_avail);
  v_report := v_report || format('INVARIANTE_gw_total_earned_exacto: %s (real=%s esperado=%s)\n', v_final_gw.total_earned = v_exp_gw_earned, v_final_gw.total_earned, v_exp_gw_earned);
  v_report := v_report || format('INVARIANTE_gw_pending_sin_tocar: %s (real=%s)\n', v_final_gw.pending_balance = 0, v_final_gw.pending_balance);
  v_report := v_report || format('INVARIANTE_gw_usd_sin_tocar: %s\n', v_final_gw.pending_balance_usd = 0 AND v_final_gw.available_balance_usd = 0 AND v_final_gw.total_earned_usd = 0);

  SELECT available_balance, total_earned, available_balance_usd, total_earned_usd
  INTO   v_final_admin
  FROM   wallets WHERE user_id = v_admin_id;

  v_report := v_report || format('INVARIANTE_admin_available_delta_exacto: %s (real=%s esperado=%s)\n', v_final_admin.available_balance = v_admin_avail_pre + v_exp_admin_delta, v_final_admin.available_balance, v_admin_avail_pre + v_exp_admin_delta);
  v_report := v_report || format('INVARIANTE_admin_total_earned_delta_exacto: %s (real=%s esperado=%s)\n', v_final_admin.total_earned = v_admin_earned_pre + v_exp_admin_delta, v_final_admin.total_earned, v_admin_earned_pre + v_exp_admin_delta);
  v_report := v_report || format('INVARIANTE_admin_usd_sin_tocar: %s\n', v_final_admin.available_balance_usd = v_admin_avail_usd_pre AND v_final_admin.total_earned_usd = v_admin_earned_usd_pre);
  v_report := v_report || format('INVARIANTE_ningun_bucket_negativo: %s\n',
    v_final_gw.available_balance >= 0 AND v_final_gw.total_earned >= 0 AND v_final_admin.available_balance >= 0 AND v_final_admin.total_earned >= 0);

  v_report := v_report || E'══════ FIN 555 — todo se revierte ahora (RAISE) ══════';
  RAISE EXCEPTION '%', v_report;
END;
$test555$;
