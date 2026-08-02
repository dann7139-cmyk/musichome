-- ============================================================
-- sql/528_admin_pending_group_payments_tests.sql
-- Fase P1B — pruebas de admin_get_pending_group_payments()
--
-- Transaccional, autorevertible (RAISE EXCEPTION al final): reutiliza el
-- único grupo/wallet reales existentes, inserta reservations sintéticas
-- (status='completed' para no disparar el motor de disponibilidad),
-- prueba también save_bank_account() como el propio dueño del grupo, y
-- revierte TODO al terminar. Cero rastro en datos reales.
-- ============================================================

DO $$
DECLARE
  v_group_id   UUID := '83911568-2694-4541-81ae-af1f80bc490e'; -- grupo real existente
  v_owner_id   UUID := '929ba9ba-1dfd-4b76-abf1-18168b1ac1ba'; -- dueño real de ese grupo
  v_client_id  UUID := '889e7168-a30a-49c5-a32a-cbeb320d00f8'; -- cliente real existente
  v_admin_id   UUID;
  v_res_a      UUID; -- released, earnings>0, SIN datos bancarios → debe aparecer
  v_res_b      UUID; -- held → NO debe aparecer
  v_res_c      UUID; -- released, earnings=0 → NO debe aparecer
  v_res_d      UUID; -- released, earnings>0, mismo grupo que A → debe aparecer separada
  v_res_e      UUID; -- released, CON datos bancarios (tras save_bank_account) → debe aparecer sin aviso
  v_out        JSONB;
  v_report     TEXT := '';
  v_items      JSONB;
BEGIN
  SELECT id INTO v_admin_id FROM profiles WHERE role = 'admin' ORDER BY created_at LIMIT 1;
  IF v_admin_id IS NULL THEN RAISE EXCEPTION 'No hay ningún admin en profiles — no se puede probar'; END IF;

  -- ── Reservas sintéticas: status='completed' evita el motor de disponibilidad ──
  INSERT INTO reservations (group_id, client_id, event_date, address, total_price, status, payment_status, payout_status, group_earnings)
  VALUES (v_group_id, v_client_id, '2099-01-01', 'Test P1B A', 6000, 'completed', 'paid', 'released', 5000)
  RETURNING id INTO v_res_a;

  INSERT INTO reservations (group_id, client_id, event_date, address, total_price, status, payment_status, payout_status, group_earnings)
  VALUES (v_group_id, v_client_id, '2099-01-02', 'Test P1B B (held)', 6000, 'completed', 'paid', 'held', 5000)
  RETURNING id INTO v_res_b;

  INSERT INTO reservations (group_id, client_id, event_date, address, total_price, status, payment_status, payout_status, group_earnings)
  VALUES (v_group_id, v_client_id, '2099-01-03', 'Test P1B C (earnings 0)', 6000, 'completed', 'paid', 'released', 4800)
  RETURNING id INTO v_res_c;
  UPDATE reservations SET group_earnings = 0 WHERE id = v_res_c; -- fuerza 0 sin re-disparar triggers de total_price

  INSERT INTO reservations (group_id, client_id, event_date, address, total_price, status, payment_status, payout_status, group_earnings)
  VALUES (v_group_id, v_client_id, '2099-01-04', 'Test P1B D (mismo grupo que A)', 7200, 'completed', 'paid', 'released', 6000)
  RETURNING id INTO v_res_d;

  INSERT INTO reservations (group_id, client_id, event_date, address, total_price, status, payment_status, payout_status, group_earnings)
  VALUES (v_group_id, v_client_id, '2099-01-05', 'Test P1B E (con datos bancarios)', 6000, 'completed', 'paid', 'released', 5000)
  RETURNING id INTO v_res_e;

  -- ── T1: rol admin permitido ──
  PERFORM set_config('request.jwt.claim.sub', v_admin_id::text, true);
  v_out := admin_get_pending_group_payments(50);
  v_report := v_report || format('T1 admin_permitido: %s (ok=%s)\n', (v_out->>'ok') = 'true', v_out->>'ok');

  v_items := v_out->'items';

  -- ── T2: no-admin rechazado ──
  PERFORM set_config('request.jwt.claim.sub', v_client_id::text, true);
  v_out := admin_get_pending_group_payments(50);
  v_report := v_report || format('T2 no_admin_rechazado: %s (error=%s)\n',
    (v_out->>'ok') = 'false' AND (v_out->>'error') = 'not_admin', v_out->>'error');

  -- Volver a admin para el resto
  PERFORM set_config('request.jwt.claim.sub', v_admin_id::text, true);
  v_out := admin_get_pending_group_payments(50);
  v_items := v_out->'items';

  -- ── T3: released (A) aparece ──
  v_report := v_report || format('T3 released_aparece: %s\n',
    EXISTS (SELECT 1 FROM jsonb_array_elements(v_items) i WHERE (i->>'reservation_id')::uuid = v_res_a));

  -- ── T4: held (B) NO aparece ──
  v_report := v_report || format('T4 held_no_aparece: %s\n',
    NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_items) i WHERE (i->>'reservation_id')::uuid = v_res_b));

  -- ── T5: earnings=0 (C) NO aparece ──
  v_report := v_report || format('T5 earnings_cero_no_aparece: %s\n',
    NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_items) i WHERE (i->>'reservation_id')::uuid = v_res_c));

  -- ── T6: faltan datos bancarios (A) → sigue visible, campos bank_* en null ──
  v_report := v_report || format('T6 sin_datos_bancarios_sigue_visible: %s\n',
    EXISTS (
      SELECT 1 FROM jsonb_array_elements(v_items) i
      WHERE (i->>'reservation_id')::uuid = v_res_a
        AND i->'bank_clabe' = 'null'::jsonb
    ));

  -- ── T7: dos reservas del mismo grupo (A y D) aparecen separadas ──
  v_report := v_report || format('T7_dos_reservas_mismo_grupo_separadas: %s\n', (
    (SELECT count(*) FROM jsonb_array_elements(v_items) i
     WHERE (i->>'reservation_id')::uuid IN (v_res_a, v_res_d)) = 2
  ));

  -- ── T8: p_limit funciona ──
  v_out := admin_get_pending_group_payments(1);
  v_report := v_report || format('T8_limit_1_devuelve_1: %s\n',
    jsonb_array_length(v_out->'items') = 1);

  -- ── T9 (bonus, valida datos bancarios reales): guardar datos bancarios como
  --     el propio dueño del grupo, vía save_bank_account (RPC real de P1A) ──
  PERFORM set_config('request.jwt.claim.sub', v_owner_id::text, true);
  PERFORM save_bank_account('646180157000000018', 'STP', 'Titular de Prueba P1B');

  PERFORM set_config('request.jwt.claim.sub', v_admin_id::text, true);
  v_out := admin_get_pending_group_payments(50);
  v_items := v_out->'items';
  v_report := v_report || format('T9_con_datos_bancarios_visibles: %s\n', (
    SELECT (i->>'bank_clabe') = '646180157000000018' AND (i->>'account_holder') = 'Titular de Prueba P1B'
    FROM jsonb_array_elements(v_items) i
    WHERE (i->>'reservation_id')::uuid = v_res_e
  ));

  RAISE EXCEPTION E'\n=== RESULTADOS sql/528 (autorevertido, sin rastro real) ===\n%', v_report;
END $$;
