-- ═══════════════════════════════════════════════════════════════════════════
-- 695 — PRUEBAS DE SEGURIDAD de la ACL de las 17 funciones internas (sql/694)
-- ═══════════════════════════════════════════════════════════════════════════
-- AUTOREVERTIBLE: BEGIN → DO → RAISE EXCEPTION → ROLLBACK. No inserta, no
-- actualiza y no borra NADA.
--
-- ⚠️  REGLA DE ESTA SUITE: **jamás ejecuta las 17 funciones**. Comprueba los
-- permisos con `has_function_privilege`, que solo LEE el catálogo. Ejecutarlas
-- para "probar" que fallan movería dinero real si alguna llegara a pasar, así
-- que no se hace ni dentro de una transacción revertida.
--
-- Cómo leer los resultados:
--   · ANTES de sql/694 → la suite FALLA en [1] y dice exactamente cuántas
--     funciones sigue pudiendo invocar `anon`. Eso documenta el estado inseguro.
--   · DESPUÉS de sql/694 → 8/8 PASS.
--
-- Cubre lo que pidió el usuario: anon no puede; un cliente autenticado no
-- puede; un proveedor autenticado tampoco (mismo rol `authenticated` en
-- PostgREST — el rol es el límite, no la persona); service_role conserva
-- acceso; postgres conserva acceso; y las 4 con invocador real en la app siguen
-- disponibles para `authenticated` para no romper la app instalada.
-- ═══════════════════════════════════════════════════════════════════════════

BEGIN;

DO $suite$
DECLARE
  -- Grupo A: internas puras → solo postgres y service_role.
  SOLO_BACKEND TEXT[] := ARRAY[
    'public.auto_cancel_unpaid_bookings()',
    'public.auto_cancel_expired_bookings()',
    'public.auto_finalize_stuck_events()',
    'public.auto_start_due_events()',
    'public.check_transit_nudges()',
    'public.send_client_retention_notifications()',
    'public.confirm_full_payment_and_credit_wallet(uuid, text, numeric, numeric)',
    'public.mp_credit_pending_earnings(uuid, text, numeric)',
    'public.confirm_extra_hour_stripe_payment(uuid, text, numeric, text, numeric)',
    'public.distribute_event_earnings(uuid)',
    'public.process_refund_reversal(uuid, text, numeric, uuid)',
    'public.settle_cancellation(uuid, text, text, uuid)',
    'public.settle_group_cancellation(uuid, text, text, uuid)'
  ];
  -- Grupo B: conservan `authenticated` porque la app instalada las llama.
  CON_AUTHENTICATED TEXT[] := ARRAY[
    'public.mark_abandoned_reservations()',
    'public.release_group_earnings_atomic(uuid, uuid)',
    'public.release_half_on_arrival(uuid, double precision, double precision)',
    'public.validate_arrival_code(uuid, text)'
  ];
  v_fn     TEXT;
  v_malas  TEXT := '';
  v_n      INT;
BEGIN
  -- ══ [1] anon NO puede ejecutar NINGUNA de las 17 ═════════════════════════
  FOREACH v_fn IN ARRAY (SOLO_BACKEND || CON_AUTHENTICATED) LOOP
    IF has_function_privilege('anon', v_fn, 'EXECUTE') THEN
      v_malas := v_malas || E'\n    · ' || v_fn;
    END IF;
  END LOOP;
  ASSERT v_malas = '',
    '[1] anon TODAVIA puede ejecutar estas funciones internas:' || v_malas;

  -- ══ [2] authenticated NO puede ejecutar las 13 puramente internas ════════
  -- Mismo rol para cliente y proveedor: en PostgREST ambos entran como
  -- `authenticated`, así que esta sola comprobación cubre los dos casos que
  -- pidió el usuario (cliente autenticado y proveedor autenticado).
  v_malas := '';
  FOREACH v_fn IN ARRAY SOLO_BACKEND LOOP
    IF has_function_privilege('authenticated', v_fn, 'EXECUTE') THEN
      v_malas := v_malas || E'\n    · ' || v_fn;
    END IF;
  END LOOP;
  ASSERT v_malas = '',
    '[2] authenticated (cliente O proveedor) TODAVIA puede ejecutar:' || v_malas;

  -- ══ [3] service_role CONSERVA acceso a las 17 (webhooks/edge) ═══════════
  v_malas := '';
  FOREACH v_fn IN ARRAY (SOLO_BACKEND || CON_AUTHENTICATED) LOOP
    IF NOT has_function_privilege('service_role', v_fn, 'EXECUTE') THEN
      v_malas := v_malas || E'\n    · ' || v_fn;
    END IF;
  END LOOP;
  ASSERT v_malas = '',
    '[3] service_role PERDIO acceso (romperia Stripe/Conekta/webhooks):' || v_malas;

  -- ══ [4] postgres CONSERVA acceso a las 17 (los 6 crons corren como el) ══
  v_malas := '';
  FOREACH v_fn IN ARRAY (SOLO_BACKEND || CON_AUTHENTICATED) LOOP
    IF NOT has_function_privilege('postgres', v_fn, 'EXECUTE') THEN
      v_malas := v_malas || E'\n    · ' || v_fn;
    END IF;
  END LOOP;
  ASSERT v_malas = '',
    '[4] postgres PERDIO acceso (romperia los crons):' || v_malas;

  -- ══ [5] las 4 con invocador real SIGUEN disponibles para authenticated ══
  -- Si esto falla, la app instalada se rompe: el grupo no podria marcar
  -- llegada, ni liberar su pago al terminar, ni cargar sus eventos.
  v_malas := '';
  FOREACH v_fn IN ARRAY CON_AUTHENTICATED LOOP
    IF NOT has_function_privilege('authenticated', v_fn, 'EXECUTE') THEN
      v_malas := v_malas || E'\n    · ' || v_fn;
    END IF;
  END LOOP;
  ASSERT v_malas = '',
    '[5] se revoco de mas: la app instalada necesita estas como authenticated:' || v_malas;

  -- ══ [6] sin overloads: una sola copia de cada nombre ════════════════════
  SELECT COUNT(*) INTO v_n
  FROM (
    SELECT p.proname FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public'
      AND p.proname IN ('auto_cancel_unpaid_bookings','auto_cancel_expired_bookings',
        'auto_finalize_stuck_events','auto_start_due_events','check_transit_nudges',
        'send_client_retention_notifications','confirm_full_payment_and_credit_wallet',
        'mp_credit_pending_earnings','confirm_extra_hour_stripe_payment',
        'distribute_event_earnings','process_refund_reversal','settle_cancellation',
        'settle_group_cancellation','mark_abandoned_reservations',
        'release_group_earnings_atomic','release_half_on_arrival','validate_arrival_code')
    GROUP BY p.proname HAVING COUNT(*) > 1
  ) dup;
  ASSERT v_n = 0, '[6] hay overloads: ' || v_n::text || ' nombre(s) con mas de una firma';

  -- ══ [7] las 17 siguen siendo SECURITY DEFINER con search_path fijo ══════
  -- sql/694 solo cambia permisos; si esto falla, alguien toco la definicion.
  SELECT COUNT(*) INTO v_n
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public'
    AND p.proname IN ('auto_cancel_unpaid_bookings','auto_cancel_expired_bookings',
      'auto_finalize_stuck_events','auto_start_due_events','check_transit_nudges',
      'send_client_retention_notifications','confirm_full_payment_and_credit_wallet',
      'mp_credit_pending_earnings','confirm_extra_hour_stripe_payment',
      'distribute_event_earnings','process_refund_reversal','settle_cancellation',
      'settle_group_cancellation','mark_abandoned_reservations',
      'release_group_earnings_atomic','release_half_on_arrival','validate_arrival_code')
    AND (NOT p.prosecdef OR p.proconfig IS NULL);
  ASSERT v_n = 0,
    '[7] ' || v_n::text || ' funcion(es) dejaron de ser SECURITY DEFINER o perdieron search_path';

  -- ══ [8] la referencia del proyecto sigue igual ══════════════════════════
  -- confirm_reservation_payment_v2 ya estaba endurecida ANTES de sql/694
  -- (ACL `postgres | service_role`). Sirve de control: si esta prueba falla,
  -- la migracion toco algo que no debia.
  ASSERT NOT has_function_privilege('anon', 'public.confirm_reservation_payment_v2(text, text, text, uuid, bigint, text, text, bigint, text, jsonb)', 'EXECUTE')
      OR NOT EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
                     WHERE n.nspname='public' AND p.proname='confirm_reservation_payment_v2'),
    '[8] confirm_reservation_payment_v2 quedo expuesta a anon';

  RAISE EXCEPTION 'TEST_REPORT sql/695: TODO PASO (8/8) — anon sin acceso a ninguna de las 17; authenticated sin acceso a las 13 internas (cliente Y proveedor, mismo rol); service_role y postgres conservan las 17 (webhooks, edge y los 6 crons intactos); las 4 con invocador real en la app siguen disponibles para authenticated; sin overloads; las 17 siguen SECURITY DEFINER con search_path; confirm_reservation_payment_v2 sin tocar';
END
$suite$;

ROLLBACK;
