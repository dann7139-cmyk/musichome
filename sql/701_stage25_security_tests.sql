-- ═══════════════════════════════════════════════════════════════════════════
-- 701 — SUITE DE SEGURIDAD de la Etapa 2.5 (autorevertible de principio a fin)
-- ═══════════════════════════════════════════════════════════════════════════
-- Requisito: `sql/699` aplicado (las 3 envolturas + el helper). Los REVOKE de
-- `700` los aplica la propia suite dentro de su transacción y los revierte, así
-- se puede demostrar el cierre SIN cerrar nada en producción — el mismo patrón
-- que sql/698.
--
-- ⚠️  NO MUEVE DINERO, NI FICTICIO. Las pruebas están construidas para que
-- `release_group_earnings_atomic` NUNCA llegue a su bloque de wallet: cada caso
-- se detiene antes, en una de sus guardas de estado (`payment_not_confirmed`,
-- `no_arrival_verification`, `already_released`). Eso es justo lo que se quiere
-- demostrar, y además evita tocar `group_wallets` / `wallet_transactions` /
-- `wallets` incluso dentro de una transacción revertida.
--
-- Todo lo sembrado lleva prefijo RTSEC25 y desaparece con el ROLLBACK.
-- ═══════════════════════════════════════════════════════════════════════════

BEGIN;

-- ─── Los REVOKE de 700, aquí solo para poder probarlos ────────────────────
REVOKE EXECUTE ON FUNCTION public.validate_start_code(UUID, TEXT)   FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.validate_arrival_code(UUID, TEXT) FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.release_half_on_arrival(UUID, DOUBLE PRECISION, DOUBLE PRECISION)
  FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.release_group_earnings_atomic(UUID, UUID)
  FROM PUBLIC, anon, authenticated;

DO $suite$
DECLARE
  v_cliente UUID := '889e7168-a30a-49c5-a32a-cbeb320d00f8';
  v_dueñoA  UUID := '929ba9ba-1dfd-4b76-abf1-18168b1ac1ba';
  v_dueñoB  UUID;
  v_mx UUID; v_gA UUID; v_gB UUID;
  v_resA UUID;      -- del grupo A: pagada, payout held, SIN llegada
  v_resA2 UUID;     -- del grupo A: payout ya released (idempotencia)
  v_resA3 UUID;     -- del grupo A: sin pagar
  v_resB UUID;      -- del grupo B (para cruce entre proveedores)
  v_d JSONB; v_code TEXT; v_n INT;
BEGIN
  SELECT id INTO v_mx FROM public.countries WHERE currency_code='MXN' LIMIT 1;
  SELECT id INTO v_dueñoB FROM public.profiles WHERE id NOT IN (v_cliente, v_dueñoA) LIMIT 1;
  ASSERT v_dueñoB IS NOT NULL, 'falta un tercer perfil para probar el cruce entre proveedores';

  RESET role;
  INSERT INTO public.groups (id,owner_id,name,genre,country_id)
  VALUES (gen_random_uuid(),v_dueñoA,'RTSEC25 Grupo A','Banda',v_mx) RETURNING id INTO v_gA;
  INSERT INTO public.groups (id,owner_id,name,genre,country_id)
  VALUES (gen_random_uuid(),v_dueñoB,'RTSEC25 Grupo B','Banda',v_mx) RETURNING id INTO v_gB;

  -- Pagada, payout retenido, SIN llegada registrada
  INSERT INTO public.reservations (id,client_id,group_id,event_date,event_time,address,
    total_price,base_price,status,payment_status,payout_status,currency_code,hours_count)
  VALUES (gen_random_uuid(),v_cliente,v_gA,CURRENT_DATE+900,'20:00','RTSEC25 A',
    10000,8000,'confirmed','paid','held','MXN',3) RETURNING id INTO v_resA;
  -- Payout YA liberado (para idempotencia / doble liberación)
  INSERT INTO public.reservations (id,client_id,group_id,event_date,event_time,address,
    total_price,base_price,status,payment_status,payout_status,currency_code,hours_count,group_arrived_at)
  VALUES (gen_random_uuid(),v_cliente,v_gA,CURRENT_DATE+901,'20:00','RTSEC25 A2',
    10000,8000,'completed','paid','released','MXN',3,NOW()) RETURNING id INTO v_resA2;
  -- Sin pagar
  INSERT INTO public.reservations (id,client_id,group_id,event_date,event_time,address,
    total_price,base_price,status,payment_status,payout_status,currency_code,hours_count)
  VALUES (gen_random_uuid(),v_cliente,v_gA,CURRENT_DATE+902,'20:00','RTSEC25 A3',
    10000,8000,'confirmed','unpaid','held','MXN',3) RETURNING id INTO v_resA3;
  -- Del grupo B
  INSERT INTO public.reservations (id,client_id,group_id,event_date,event_time,address,
    total_price,base_price,status,payment_status,payout_status,currency_code,hours_count)
  VALUES (gen_random_uuid(),v_cliente,v_gB,CURRENT_DATE+903,'20:00','RTSEC25 B',
    7000,6000,'confirmed','paid','held','MXN',3) RETURNING id INTO v_resB;

  SELECT arrival_code INTO v_code FROM public.reservations WHERE id = v_resA;
  ASSERT v_code IS NOT NULL, 'el trigger de folio/codigo deberia haber puesto arrival_code';

  -- ══════════════ [1] ANON no puede nada ══════════════
  PERFORM set_config('request.jwt.claims','',true);
  PERFORM set_config('role','anon',true);
  FOR v_n IN 1..1 LOOP
    BEGIN
      PERFORM public.validate_start_code(v_resA, v_code);
      RAISE EXCEPTION '[1] anon pudo usar validate_start_code como oraculo';
    EXCEPTION WHEN insufficient_privilege THEN NULL;
    END;
    BEGIN
      PERFORM public.release_group_earnings_atomic(v_resA, NULL);
      RAISE EXCEPTION '[1] anon pudo llamar la primitiva financiera';
    EXCEPTION WHEN insufficient_privilege THEN NULL;
    END;
    BEGIN
      PERFORM public.group_release_earnings(v_resA);
      RAISE EXCEPTION '[1] anon pudo llamar la envoltura';
    EXCEPTION WHEN insufficient_privilege THEN NULL;
    END;
  END LOOP;

  -- ══════════════ [2] CLIENTE no puede liberar ni marcar llegada ══════════
  PERFORM set_config('request.jwt.claims', json_build_object('sub',v_cliente::text,'role','authenticated')::text, true);
  PERFORM set_config('role','authenticated',true);

  v_d := public.group_release_earnings(v_resA);
  ASSERT v_d->>'error' = 'not_group_owner', '[2] el cliente no debe poder liberar: ' || v_d::text;
  v_d := public.group_confirm_arrival(v_resA, 0, 0);
  ASSERT v_d->>'error' = 'not_group_owner', '[2] el cliente no debe poder marcar llegada: ' || v_d::text;
  v_d := public.group_validate_start_code(v_resA, v_code);
  ASSERT v_d->>'error' = 'not_group_owner', '[2] el cliente no debe validar el codigo: ' || v_d::text;
  -- Y tampoco por la primitiva, que ya no tiene EXECUTE
  BEGIN
    PERFORM public.release_group_earnings_atomic(v_resA, NULL);
    RAISE EXCEPTION '[2] el cliente alcanzo la primitiva financiera';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;

  -- ══════════════ [3] PROVEEDOR B no puede operar la reserva de A ═════════
  PERFORM set_config('request.jwt.claims', json_build_object('sub',v_dueñoB::text,'role','authenticated')::text, true);
  PERFORM set_config('role','authenticated',true);
  v_d := public.group_release_earnings(v_resA);
  ASSERT v_d->>'error' = 'not_group_owner', '[3] B pudo liberar la reserva de A: ' || v_d::text;
  v_d := public.group_confirm_arrival(v_resA, 0, 0);
  ASSERT v_d->>'error' = 'not_group_owner', '[3] B pudo marcar llegada en la reserva de A: ' || v_d::text;
  v_d := public.group_validate_start_code(v_resA, v_code);
  ASSERT v_d->>'error' = 'not_group_owner', '[3] B pudo usar el codigo de A: ' || v_d::text;

  -- ══════════════ [4] ID inexistente/manipulado no filtra nada ═══════════
  v_d := public.group_release_earnings(gen_random_uuid());
  ASSERT v_d->>'error' = 'not_group_owner',
    '[4] un id inventado deberia dar el MISMO error que uno ajeno (sin enumeracion): ' || v_d::text;

  -- ══════════════ [5..8] EL PROVEEDOR CORRECTO: pasa autorizacion y se ═══
  --                detiene en las guardas de estado, sin mover dinero
  PERFORM set_config('request.jwt.claims', json_build_object('sub',v_dueñoA::text,'role','authenticated')::text, true);
  PERFORM set_config('role','authenticated',true);

  -- [5] llegada NO validada -> la primitiva se salta sin liberar
  v_d := public.group_release_earnings(v_resA);
  ASSERT v_d->>'error' IS DISTINCT FROM 'not_group_owner',
    '[5] el dueño correcto no deberia recibir not_group_owner: ' || v_d::text;
  ASSERT v_d->>'reason' = 'no_arrival_verification',
    '[5] sin llegada verificada deberia saltarse, llego: ' || v_d::text;

  -- [6] pago NO confirmado -> rechazo por estado, no por autorizacion
  v_d := public.group_release_earnings(v_resA3);
  ASSERT v_d->>'error' = 'payment_not_confirmed',
    '[6] sin pago confirmado deberia rechazar por estado, llego: ' || v_d::text;

  -- [7] payout YA liberado -> idempotente, no duplica
  v_d := public.group_release_earnings(v_resA2);
  ASSERT (v_d->>'ok')::boolean AND (v_d->>'skipped')::boolean
     AND v_d->>'reason' = 'already_released',
    '[7] un payout ya liberado no debe volver a liberarse, llego: ' || v_d::text;
  -- repetirlo sigue siendo seguro
  v_d := public.group_release_earnings(v_resA2);
  ASSERT v_d->>'reason' = 'already_released', '[7] la llamada repetida debe seguir siendo idempotente';

  -- [8] nada se movio: cero transacciones de wallet para estas reservas
  RESET role;
  SELECT COUNT(*) INTO v_n FROM public.wallet_transactions
  WHERE reservation_id IN (v_resA, v_resA2, v_resA3, v_resB);
  ASSERT v_n = 0, '[8] la suite movio dinero y no debia: ' || v_n::text || ' wallet_transactions';
  SELECT COUNT(*) INTO v_n FROM public.reservations
  WHERE id IN (v_resA, v_resA3) AND payout_status <> 'held';
  ASSERT v_n = 0, '[8] algun payout cambio de estado';

  -- ══════════════ [9] El codigo: solo el dueño, y uno malo falla ═════════
  PERFORM set_config('request.jwt.claims', json_build_object('sub',v_dueñoA::text,'role','authenticated')::text, true);
  PERFORM set_config('role','authenticated',true);
  -- dos intentos incorrectos (NO es fuerza bruta: son dos)
  v_d := public.group_validate_start_code(v_resA, '0000');
  ASSERT (v_d->>'ok')::boolean = false, '[9] un codigo incorrecto deberia fallar';
  v_d := public.group_validate_start_code(v_resA, '9999');
  ASSERT (v_d->>'ok')::boolean = false OR v_code = '9999', '[9] otro codigo incorrecto deberia fallar';
  -- el correcto sí funciona para el dueño
  v_d := public.group_validate_start_code(v_resA, v_code);
  ASSERT (v_d->>'ok')::boolean, '[9] el dueño con el codigo correcto deberia poder: ' || v_d::text;

  -- ══════════════ [10] Llegada: el dueño pasa la autorizacion ════════════
  v_d := public.group_confirm_arrival(v_resA, 0, 0);
  ASSERT v_d->>'error' IS DISTINCT FROM 'not_group_owner',
    '[10] el dueño correcto no deberia recibir not_group_owner al marcar llegada: ' || v_d::text;

  -- ══════════════ [11] Backend conserva los flujos internos ══════════════
  RESET role;
  ASSERT has_function_privilege('service_role','public.release_group_earnings_atomic(uuid, uuid)','EXECUTE'),
    '[11] service_role perdio la primitiva financiera';
  ASSERT has_function_privilege('postgres','public.release_group_earnings_atomic(uuid, uuid)','EXECUTE'),
    '[11] postgres perdio la primitiva financiera (romperia los crons)';
  ASSERT has_function_privilege('service_role','public.validate_start_code(uuid, text)','EXECUTE')
     AND has_function_privilege('service_role','public.release_half_on_arrival(uuid, double precision, double precision)','EXECUTE'),
    '[11] service_role perdio alguna primitiva';
  ASSERT NOT has_function_privilege('anon','public.validate_start_code(uuid, text)','EXECUTE'),
    '[11] anon conserva el oraculo del codigo';
  ASSERT NOT has_function_privilege('authenticated','public.release_group_earnings_atomic(uuid, uuid)','EXECUTE'),
    '[11] authenticated conserva la primitiva financiera';
  ASSERT has_function_privilege('authenticated','public.group_release_earnings(uuid)','EXECUTE'),
    '[11] authenticated deberia conservar la ENVOLTURA';

  -- ══════════════ [12] Sin overloads ═════════════════════════════════════
  SELECT COUNT(*) INTO v_n FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
  WHERE n.nspname='public' AND p.proname IN
    ('reservation_group_if_owner','group_validate_start_code','group_confirm_arrival','group_release_earnings');
  ASSERT v_n = 4, '[12] esperaba 4 funciones nuevas sin overloads, hay ' || v_n::text;

  RAISE EXCEPTION 'TEST_REPORT sql/701: TODO PASO (12/12) — anon no alcanza ni las primitivas ni las envolturas; el cliente no libera ni marca llegada ni valida codigo; el proveedor B no puede operar la reserva de A; un id inventado da el mismo error que uno ajeno (sin enumeracion); el dueño correcto pasa la autorizacion y se detiene en las guardas de estado (no_arrival_verification, payment_not_confirmed) SIN mover dinero; un payout ya liberado es idempotente y no se duplica; cero wallet_transactions creadas; el codigo solo lo valida el dueño; postgres y service_role conservan las primitivas y authenticated conserva solo las envolturas';
END
$suite$;

ROLLBACK;
