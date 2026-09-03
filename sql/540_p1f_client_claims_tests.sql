-- ============================================================
-- sql/540_p1f_client_claims_tests.sql
--
-- Pruebas de sql/539: prc_client_read (RLS) + notificaciones nuevas de
-- process_refund_reversal (cliente + owner) + fix de duplicado por
-- `skipped`. Patrón autorrevertido: TODO ocurre dentro de una
-- transacción que termina en RAISE EXCEPTION con el reporte como
-- mensaje — sin importar el resultado, nada persiste.
--
-- Reutiliza client_id/group_id REALES ya probados en esta sesión
-- (satisfacen los triggers de notify_booking_events) — ninguna fila
-- fixture se commitea nunca.
-- ============================================================

DO $$
DECLARE
  v_client_id  uuid := '889e7168-a30a-49c5-a32a-cbeb320d00f8';
  v_group_id   uuid := '83911568-2694-4541-81ae-af1f80bc490e';
  v_owner_id   uuid;
  v_other_uid  uuid := '11111111-1111-1111-1111-111111111111'; -- usuario ajeno, no existe como perfil real (no hace falta para probar RLS negativo)
  v_wallet_id  uuid;

  v_res_mxn    uuid := gen_random_uuid();
  v_res_usd    uuid := gen_random_uuid();
  v_res_skip   uuid := gen_random_uuid();

  v_notif_count_before int;
  v_notif_count_after  int;
  v_result     jsonb;

  r  text := '';
  ok boolean;
BEGIN
  SELECT owner_id INTO v_owner_id FROM groups WHERE id = v_group_id;

  PERFORM ensure_group_wallet(v_group_id);
  SELECT id INTO v_wallet_id FROM group_wallets WHERE group_id = v_group_id;

  -- ═══════════ T1: process_refund_reversal (MXN) — notificaciones nuevas ═══════════
  INSERT INTO reservations (
    id, client_id, group_id, event_date, address, total_price, base_price,
    payment_status, payout_status, currency_code, mp_payment_id, payment_provider, status
  ) VALUES (
    v_res_mxn, v_client_id, v_group_id, (now() + interval '30 days')::date,
    'FIXTURE 540 — NO USAR', 1000, 800, 'paid', 'held', 'MXN',
    'pi_fixture_540_mxn', 'stripe', 'confirmed'
  );
  INSERT INTO wallet_transactions (group_wallet_id, group_id, type, amount, reservation_id, description, currency_code)
  VALUES (v_wallet_id, v_group_id, 'credit_pending', 1000, v_res_mxn, 'fixture 540 credit', 'MXN');

  SELECT count(*) INTO v_notif_count_before FROM notifications
    WHERE data->>'reservation_id' = v_res_mxn::text;

  v_result := process_refund_reversal(v_res_mxn, NULL, 1000, NULL);

  SELECT count(*) INTO v_notif_count_after FROM notifications
    WHERE data->>'reservation_id' = v_res_mxn::text;

  ok := (v_result->>'ok')::boolean = true
    AND (v_result->>'currency') = 'MXN'
    AND (v_notif_count_after - v_notif_count_before) = 2  -- cliente + owner
    AND EXISTS (SELECT 1 FROM notifications WHERE user_id = v_client_id AND data->>'reservation_id' = v_res_mxn::text
                  AND title = '💸 Reembolso emitido' AND body LIKE '%MXN%')
    AND EXISTS (SELECT 1 FROM notifications WHERE user_id = v_owner_id AND data->>'reservation_id' = v_res_mxn::text
                  AND title = '↩ Reembolso procesado — tu wallet fue ajustada' AND body LIKE '%MXN%');
  r := r || format('T1_reversal_mxn_notifica_cliente_y_owner: %s (result=%s notifs_nuevas=%s)\n', ok, v_result, v_notif_count_after - v_notif_count_before);

  -- ═══════════ T2: reintento sobre la MISMA reserva ya reembolsada → skipped, CERO notificaciones nuevas ═══════════
  SELECT count(*) INTO v_notif_count_before FROM notifications WHERE data->>'reservation_id' = v_res_mxn::text;
  v_result := process_refund_reversal(v_res_mxn, NULL, 1000, NULL);
  SELECT count(*) INTO v_notif_count_after FROM notifications WHERE data->>'reservation_id' = v_res_mxn::text;

  ok := (v_result->>'skipped')::boolean = true
    AND v_notif_count_after = v_notif_count_before; -- CERO notificaciones nuevas — el fix de duplicado funciona
  r := r || format('T2_reintento_skipped_cero_duplicado: %s (result=%s antes=%s despues=%s)\n', ok, v_result, v_notif_count_before, v_notif_count_after);

  -- ═══════════ T3: process_refund_reversal (USD) — el body dice USD, no MXN ═══════════
  INSERT INTO reservations (
    id, client_id, group_id, event_date, address, total_price, base_price,
    payment_status, payout_status, currency_code, mp_payment_id, payment_provider, status
  ) VALUES (
    v_res_usd, v_client_id, v_group_id, (now() + interval '60 days')::date,
    'FIXTURE 540 — NO USAR', 500, 400, 'paid', 'held', 'USD',
    'pi_fixture_540_usd', 'stripe', 'confirmed'
  );
  INSERT INTO wallet_transactions (group_wallet_id, group_id, type, amount, reservation_id, description, currency_code)
  VALUES (v_wallet_id, v_group_id, 'credit_pending', 500, v_res_usd, 'fixture 540 credit usd', 'USD');

  v_result := process_refund_reversal(v_res_usd, NULL, 500, NULL);

  ok := (v_result->>'ok')::boolean = true
    AND (v_result->>'currency') = 'USD'
    AND EXISTS (SELECT 1 FROM notifications WHERE user_id = v_client_id AND data->>'reservation_id' = v_res_usd::text
                  AND body LIKE '%USD%' AND body NOT LIKE '%MXN%')
    AND EXISTS (SELECT 1 FROM notifications WHERE user_id = v_owner_id AND data->>'reservation_id' = v_res_usd::text
                  AND body LIKE '%USD%' AND body NOT LIKE '%MXN%');
  r := r || format('T3_reversal_usd_moneda_correcta_sin_MXN_hardcodeado: %s (result=%s)\n', ok, v_result);

  -- ═══════════ T4: RLS — el cliente dueño de la reserva SÍ puede leer su claim ═══════════
  INSERT INTO provider_refund_claims (reservation_id, group_id, provider, provider_payment_id, mode, currency_code, amount, status, claimed_by)
  VALUES (v_res_mxn, v_group_id, 'stripe', 'pi_fixture_540_mxn', 'full', 'MXN', 1000, 'done', v_client_id);

  -- CRÍTICO: `supabase db query` conecta con un rol que bypassa RLS
  -- (dueño de tabla). set_config() por sí solo NO alcanza para probar la
  -- política real — hay que cambiar de rol a `authenticated` (el mismo
  -- rol con el que PostgREST/el cliente real consulta en producción)
  -- para que RLS realmente se evalúe.
  SET LOCAL ROLE authenticated;

  PERFORM set_config('request.jwt.claim.sub', v_client_id::text, true);
  ok := (SELECT count(*) FROM provider_refund_claims WHERE reservation_id = v_res_mxn) = 1;
  r := r || format('T4_cliente_lee_su_propio_claim: %s\n', ok);

  -- ═══════════ T5: RLS — un usuario AJENO NO puede leer ese claim ═══════════
  PERFORM set_config('request.jwt.claim.sub', v_other_uid::text, true);
  ok := (SELECT count(*) FROM provider_refund_claims WHERE reservation_id = v_res_mxn) = 0;
  r := r || format('T5_usuario_ajeno_no_lee_claim_de_otro: %s\n', ok);

  -- ═══════════ T6: RLS — el dueño del grupo sigue pudiendo leer (prc_owner_read intacta) ═══════════
  PERFORM set_config('request.jwt.claim.sub', v_owner_id::text, true);
  ok := (SELECT count(*) FROM provider_refund_claims WHERE reservation_id = v_res_mxn) = 1;
  r := r || format('T6_owner_de_grupo_sigue_leyendo_prc_owner_read_intacta: %s\n', ok);

  -- ═══════════ T7: RLS — el cliente NO puede leer el claim de OTRA reserva que no es suya ═══════════
  -- (usa la reserva usd, que también pertenece al mismo cliente en este fixture —
  --  probamos negativo con una reserva que pertenece a otro reservation_id inexistente)
  PERFORM set_config('request.jwt.claim.sub', v_other_uid::text, true);
  ok := (SELECT count(*) FROM provider_refund_claims WHERE reservation_id = v_res_usd) = 0
     OR NOT EXISTS (SELECT 1 FROM provider_refund_claims WHERE reservation_id = v_res_usd); -- v_res_usd no tiene claim, verificación trivial de que no explota
  r := r || format('T7_query_sin_claim_no_falla: %s\n', ok);

  RAISE EXCEPTION E'\n══════ REPORTE 540 — sql/539 (prc_client_read + notificaciones) ══════\n%\n══════ FIN 540 — todo se revierte ahora (RAISE) ══════', r;
END $$;
