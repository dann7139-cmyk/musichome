-- ═══════════════════════════════════════════════════════════════════════════
-- sql/693 — SUITE DE PRUEBAS de sql/692 (client_get_event_dashboard)
-- ═══════════════════════════════════════════════════════════════════════════
--
-- NO APLICA NADA. Solo prueba. Todo dentro de BEGIN...ROLLBACK, termina en
-- RAISE EXCEPTION: ni una fila queda en la base real.
--
-- Requiere sql/685, 688, 692 aplicados.
--
-- CUBRE:
--   [1]  Sin sesión, evento inexistente y evento ajeno → error, sin filtrar datos.
--   [2]  Evento nuevo SIN servicios: services vacío, totales vacíos.
--   [3]  Presupuesto declarado sin ninguna reserva: el bloque budget existe.
--   [4]  Solo cotizaciones pendientes: aparecen como kind='quote', NO cuentan
--        como contratado.
--   [5]  Reserva pagada al 100%: contratado = pagado, pendiente = 0.
--   [6]  Reserva sin pagar: contratado > 0, pagado = 0, pendiente = contratado.
--   [7]  ANTICIPO: deposit_paid cuenta SOLO su monto, no el total.
--   [8]  Estados que NO cuentan como contratado: cancelled, rejected, expired.
--   [9]  'completed' SÍ cuenta como contratado (no usa estados_que_ocupan).
--   [10] payment_status que NO son dinero entrado: refunded, paid_blocked,
--        payment_failed, unpaid → pagado 0.
--   [11] DOS MONEDAS: dos bloques independientes, jamás sumadas.
--   [12] Presupuesto: remaining y over_budget; superarlo NO bloquea nada.
--   [13] provider_count y provider_limit = 20.
--   [14] Dos proveedores de la MISMA categoría conviven.
--   [15] category_key resuelto, incluido género compuesto (sql/688).
--   [16] Una cotización que ya tiene reserva no se duplica como pendiente.
--   [17] events.total_price NO se usa ni se modifica.
--   [18] Sin overloads.
-- ═══════════════════════════════════════════════════════════════════════════

BEGIN;

DO $suite$
DECLARE
  v_client UUID := '889e7168-a30a-49c5-a32a-cbeb320d00f8'; -- Lala, real (solo FK)
  v_owner  UUID := '929ba9ba-1dfd-4b76-abf1-18168b1ac1ba'; -- dueño real (solo FK)
  v_mx UUID; v_us UUID;
  v_date DATE := CURRENT_DATE + 500;
  v_ev UUID; v_ev2 UUID;
  v_d JSONB; v_b JSONB; v_t JSONB;
  v_n INT;
  v_svc JSONB;
BEGIN
  SELECT id INTO v_mx FROM public.countries WHERE currency_code='MXN' LIMIT 1;
  SELECT id INTO v_us FROM public.countries WHERE currency_code='USD' LIMIT 1;

  -- ══ [1] Accesos indebidos ═════════════════════════════════════════════════
  RESET role;
  INSERT INTO public.events (client_id, event_date, event_time, address, status)
  VALUES (v_client, v_date, '20:00', 'RT693 Salon Principal', 'active') RETURNING id INTO v_ev;

  PERFORM set_config('request.jwt.claims','',true); RESET role;
  v_d := public.client_get_event_dashboard(v_ev);
  ASSERT v_d->>'error' = 'not_authenticated', '[1] sin sesión: ' || v_d::text;

  PERFORM set_config('request.jwt.claims', json_build_object('sub',v_owner::text,'role','authenticated')::text, true);
  PERFORM set_config('role','authenticated',true);
  v_d := public.client_get_event_dashboard(v_ev);
  ASSERT v_d->>'error' = 'event_not_owned_by_client', '[1] evento ajeno: ' || v_d::text;
  ASSERT v_d->'event' IS NULL, '[1] filtró datos del evento a un usuario ajeno';

  PERFORM set_config('request.jwt.claims', json_build_object('sub',v_client::text,'role','authenticated')::text, true);
  PERFORM set_config('role','authenticated',true);
  v_d := public.client_get_event_dashboard(gen_random_uuid());
  ASSERT v_d->>'error' = 'event_not_found', '[1] inexistente: ' || v_d::text;

  -- ══ [2] Evento nuevo sin servicios ════════════════════════════════════════
  v_d := public.client_get_event_dashboard(v_ev);
  ASSERT (v_d->>'ok')::boolean, '[2] ' || v_d::text;
  ASSERT jsonb_array_length(v_d->'services') = 0, '[2] services debería estar vacío';
  ASSERT jsonb_array_length(v_d->'totals_by_currency') = 0, '[2] totales deberían estar vacíos';
  ASSERT (v_d->>'provider_count')::int = 0, '[2] provider_count';
  ASSERT (v_d->>'provider_limit')::int = 20, '[13] provider_limit debería ser 20';
  ASSERT v_d->'budget' = 'null'::jsonb OR v_d->'budget' IS NULL, '[2] sin presupuesto declarado no debe haber bloque budget';

  -- ══ [3] Presupuesto declarado, todavía sin reservas ═══════════════════════
  RESET role;
  UPDATE public.events SET budget_max = 100000, budget_currency = 'MXN' WHERE id = v_ev;
  PERFORM set_config('request.jwt.claims', json_build_object('sub',v_client::text,'role','authenticated')::text, true);
  PERFORM set_config('role','authenticated',true);
  v_d := public.client_get_event_dashboard(v_ev);
  v_b := v_d->'budget';
  ASSERT v_b IS NOT NULL AND v_b <> 'null'::jsonb, '[3] falta el bloque budget';
  ASSERT (v_b->>'budget_max')::numeric = 100000, '[3] budget_max';
  ASSERT (v_b->>'contracted')::numeric = 0,      '[3] contratado debería ser 0';
  ASSERT (v_b->>'remaining')::numeric = 100000,  '[3] remaining';
  ASSERT (v_b->>'over_budget')::boolean = false, '[3] over_budget';

  -- ══ Siembra de proveedores (como superusuario, la RLS de groups lo exige) ══
  DECLARE
    v_g1 UUID; v_g2 UUID; v_g3 UUID; v_g4 UUID; v_g5 UUID; v_gus UUID; v_gcomp UUID;
  BEGIN
    RESET role;
    INSERT INTO public.groups (id,owner_id,name,genre,country_id) VALUES
      (gen_random_uuid(), v_owner, 'RT693 Mariachi A', 'Mariachi', v_mx) RETURNING id INTO v_g1;
    INSERT INTO public.groups (id,owner_id,name,genre,country_id) VALUES
      (gen_random_uuid(), v_owner, 'RT693 Mariachi B', 'Mariachi', v_mx) RETURNING id INTO v_g2;
    INSERT INTO public.groups (id,owner_id,name,genre,country_id) VALUES
      (gen_random_uuid(), v_owner, 'RT693 Comida',     'Comida',   v_mx) RETURNING id INTO v_g3;
    INSERT INTO public.groups (id,owner_id,name,genre,country_id) VALUES
      (gen_random_uuid(), v_owner, 'RT693 Cancelado',  'DJ',       v_mx) RETURNING id INTO v_g4;
    INSERT INTO public.groups (id,owner_id,name,genre,country_id) VALUES
      (gen_random_uuid(), v_owner, 'RT693 Completado', 'Banda',    v_mx) RETURNING id INTO v_g5;
    INSERT INTO public.groups (id,owner_id,name,genre,country_id) VALUES
      (gen_random_uuid(), v_owner, 'RT693 En dolares', 'Solistas', v_us) RETURNING id INTO v_gus;
    INSERT INTO public.groups (id,owner_id,name,genre,country_id) VALUES
      (gen_random_uuid(), v_owner, 'RT693 Compuesto',  'Norteño/Sierreño', v_mx) RETURNING id INTO v_gcomp;

    -- [5] pagada al 100%  · 10 000 MXN
    INSERT INTO public.reservations (id,client_id,group_id,event_id,event_date,event_time,address,
      total_price,status,payment_status,currency_code,hours_count)
    VALUES (gen_random_uuid(),v_client,v_g1,v_ev,v_date,'20:00','RT693 Salon Principal',
      10000,'confirmed','paid','MXN',3);

    -- [6] sin pagar · 8 000 MXN
    INSERT INTO public.reservations (id,client_id,group_id,event_id,event_date,event_time,address,
      total_price,status,payment_status,currency_code,hours_count)
    VALUES (gen_random_uuid(),v_client,v_g2,v_ev,v_date,'20:00','RT693 Salon Principal',
      8000,'pending_payment','unpaid','MXN',3);

    -- [7] ANTICIPO · total 20 000, anticipo real 5 000
    INSERT INTO public.reservations (id,client_id,group_id,event_id,event_date,event_time,address,
      total_price,status,payment_status,deposit_amount,deposit_paid,currency_code,hours_count)
    VALUES (gen_random_uuid(),v_client,v_g3,v_ev,v_date,'20:00','RT693 Salon Principal',
      20000,'accepted','deposit_paid',6000,5000,'MXN',3);

    -- [8] cancelada CON dinero: no cuenta ni como contratado ni como pagado
    INSERT INTO public.reservations (id,client_id,group_id,event_id,event_date,event_time,address,
      total_price,status,payment_status,currency_code,hours_count)
    VALUES (gen_random_uuid(),v_client,v_g4,v_ev,v_date,'20:00','RT693 Salon Principal',
      99000,'cancelled','refunded','MXN',3);

    -- [9] completada y pagada · 4 000 MXN — SÍ cuenta
    INSERT INTO public.reservations (id,client_id,group_id,event_id,event_date,event_time,address,
      total_price,status,payment_status,currency_code,hours_count)
    VALUES (gen_random_uuid(),v_client,v_g5,v_ev,v_date,'20:00','RT693 Salon Principal',
      4000,'completed','fully_paid','MXN',3);

    -- [11] otra MONEDA · 300 USD pagados
    INSERT INTO public.reservations (id,client_id,group_id,event_id,event_date,event_time,address,
      total_price,status,payment_status,currency_code,hours_count)
    VALUES (gen_random_uuid(),v_client,v_gus,v_ev,v_date,'20:00','RT693 Salon Principal',
      300,'confirmed','paid','USD',3);

    -- [15] género compuesto, sin pagar · 1 000 MXN
    INSERT INTO public.reservations (id,client_id,group_id,event_id,event_date,event_time,address,
      total_price,status,payment_status,currency_code,hours_count)
    VALUES (gen_random_uuid(),v_client,v_gcomp,v_ev,v_date,'20:00','RT693 Salon Principal',
      1000,'accepted','unpaid','MXN',3);

    -- [4] cotización pendiente (no contratada) · 7 000
    INSERT INTO public.quotes (id,group_id,client_id,event_type,event_address,event_municipio,
      event_estado,event_date,event_time,duration_hours,status,venue_covered,venue_size,
      needs_sound,base_price,total_amount,event_id,num_personas)
    VALUES (gen_random_uuid(),v_g1,v_client,'boda','RT693 Salon Principal','Zapopan','Jalisco',
      v_date,'20:00',4,'quoted','si','salon_mediano','no',6000,7000,v_ev,100);
  END;

  PERFORM set_config('request.jwt.claims', json_build_object('sub',v_client::text,'role','authenticated')::text, true);
  PERFORM set_config('role','authenticated',true);
  v_d := public.client_get_event_dashboard(v_ev);
  ASSERT (v_d->>'ok')::boolean, 'dashboard falló: ' || v_d::text;

  -- ══ [4] La cotización pendiente aparece y NO cuenta como contratada ═══════
  SELECT i INTO v_svc FROM jsonb_array_elements(v_d->'services') i WHERE i->>'kind' = 'quote';
  ASSERT v_svc IS NOT NULL, '[4] no apareció la cotización pendiente';
  ASSERT (v_svc->>'counts_as_contracted')::boolean = false, '[4] la cotización no debe contar como contratada';
  ASSERT (v_svc->>'paid_amount')::numeric = 0, '[4] una cotización no puede tener pagado';

  -- ══ Totales MXN ═══════════════════════════════════════════════════════════
  -- contratado = 10000 + 8000 + 20000 + 4000 + 1000 = 43000   (99000 cancelada FUERA)
  -- pagado     = 10000 +     0 +  5000 + 4000 +    0 = 19000   (anticipo solo 5000)
  -- pendiente  = 24000
  SELECT t INTO v_t FROM jsonb_array_elements(v_d->'totals_by_currency') t WHERE t->>'currency_code' = 'MXN';
  ASSERT v_t IS NOT NULL, 'falta el bloque MXN';
  ASSERT (v_t->>'contracted')::numeric = 43000,
    '[5/6/7/8/9] contratado MXN esperado 43000, llegó ' || (v_t->>'contracted');
  ASSERT (v_t->>'paid')::numeric = 19000,
    '[7/10] pagado MXN esperado 19000 (el anticipo cuenta solo 5000), llegó ' || (v_t->>'paid');
  ASSERT (v_t->>'pending')::numeric = 24000,
    'pendiente MXN esperado 24000, llegó ' || (v_t->>'pending');
  ASSERT (v_t->>'active_count')::int = 5, 'activas MXN esperado 5, llegó ' || (v_t->>'active_count');

  -- ══ [11] Segunda moneda, independiente ════════════════════════════════════
  SELECT t INTO v_t FROM jsonb_array_elements(v_d->'totals_by_currency') t WHERE t->>'currency_code' = 'USD';
  ASSERT v_t IS NOT NULL, '[11] falta el bloque USD';
  ASSERT (v_t->>'contracted')::numeric = 300, '[11] contratado USD';
  ASSERT (v_t->>'paid')::numeric = 300,       '[11] pagado USD';
  ASSERT (v_t->>'pending')::numeric = 0,      '[11] pendiente USD';
  ASSERT (v_t->'budget_max') = 'null'::jsonb, '[11] el presupuesto en MXN no debe aparecer en el bloque USD';
  ASSERT jsonb_array_length(v_d->'totals_by_currency') = 2, '[11] debería haber exactamente 2 monedas';

  -- ══ [8] La cancelada no cuenta, pero SÍ se muestra ════════════════════════
  SELECT i INTO v_svc FROM jsonb_array_elements(v_d->'services') i
   WHERE i->>'group_name' = 'RT693 Cancelado';
  ASSERT v_svc IS NOT NULL, '[8] la cancelada debería seguir visible en la lista';
  ASSERT (v_svc->>'counts_as_contracted')::boolean = false, '[8] la cancelada no debe contar';

  -- ══ [9] La completada sí cuenta ═══════════════════════════════════════════
  SELECT i INTO v_svc FROM jsonb_array_elements(v_d->'services') i
   WHERE i->>'group_name' = 'RT693 Completado';
  ASSERT (v_svc->>'counts_as_contracted')::boolean = true,
    '[9] completed DEBE contar como contratado (no usar estados_que_ocupan)';

  -- ══ [7] El anticipo, fila por fila ════════════════════════════════════════
  SELECT i INTO v_svc FROM jsonb_array_elements(v_d->'services') i
   WHERE i->>'group_name' = 'RT693 Comida';
  ASSERT (v_svc->>'total_price')::numeric = 20000, '[7] total de la fila del anticipo';
  ASSERT (v_svc->>'paid_amount')::numeric = 5000,
    '[7] la fila del anticipo debe reportar 5000 pagados, no 20000';

  -- ══ [14]+[15] Misma categoría dos veces y género compuesto ════════════════
  SELECT count(*) INTO v_n FROM jsonb_array_elements(v_d->'services') i
   WHERE i->>'category_key' = 'grupo';
  ASSERT v_n >= 3, '[14] esperaba al menos 3 servicios de categoría grupo, hubo ' || v_n::text;
  SELECT i INTO v_svc FROM jsonb_array_elements(v_d->'services') i
   WHERE i->>'group_genre' = 'Norteño/Sierreño';
  ASSERT v_svc->>'category_key' = 'grupo',
    '[15] el género compuesto debería clasificar como grupo, llegó ' || COALESCE(v_svc->>'category_key','NULL');
  SELECT i INTO v_svc FROM jsonb_array_elements(v_d->'services') i
   WHERE i->>'group_name' = 'RT693 Comida';
  ASSERT v_svc->>'category_key' = 'comida', '[15] categoría de comida';

  -- ══ [12] Presupuesto rebasado: informa, NO bloquea ════════════════════════
  RESET role;
  UPDATE public.events SET budget_max = 20000 WHERE id = v_ev;   -- contratado MXN es 43000
  PERFORM set_config('request.jwt.claims', json_build_object('sub',v_client::text,'role','authenticated')::text, true);
  PERFORM set_config('role','authenticated',true);
  v_d := public.client_get_event_dashboard(v_ev);
  v_b := v_d->'budget';
  ASSERT (v_b->>'over_budget')::boolean = true, '[12] debería marcar over_budget';
  ASSERT (v_b->>'remaining')::numeric = -23000, '[12] remaining negativo esperado -23000, llegó ' || (v_b->>'remaining');
  -- y aun así se puede seguir contratando: el dashboard es de lectura, no bloquea.
  -- OJO: tiene que ser un grupo NUEVO. Reusar uno ya reservado a una hora que se
  -- encima lo rechaza enforce_group_availability con 'time_overlap' — regla real
  -- del proyecto (el calendario propio del grupo), ajena al límite de 20.
  RESET role;
  DECLARE v_gextra UUID;
  BEGIN
    INSERT INTO public.groups (id,owner_id,name,genre,country_id)
    VALUES (gen_random_uuid(),v_owner,'RT693 Extra','Cumbia',v_mx) RETURNING id INTO v_gextra;
    INSERT INTO public.reservations (id,client_id,group_id,event_id,event_date,event_time,address,
      total_price,status,payment_status,currency_code,hours_count)
    VALUES (gen_random_uuid(),v_client,v_gextra,v_ev,v_date,'20:00',
      'RT693 Salon Principal',500,'accepted','unpaid','MXN',3);
  END;
  PERFORM set_config('request.jwt.claims', json_build_object('sub',v_client::text,'role','authenticated')::text, true);
  PERFORM set_config('role','authenticated',true);
  v_d := public.client_get_event_dashboard(v_ev);
  SELECT t INTO v_t FROM jsonb_array_elements(v_d->'totals_by_currency') t WHERE t->>'currency_code'='MXN';
  ASSERT (v_t->>'contracted')::numeric = 43500,
    '[12] rebasar el presupuesto no debe impedir contratar; esperaba 43500, llegó ' || (v_t->>'contracted');

  -- ══ [13] provider_count coincide con el criterio del candado ══════════════
  ASSERT (v_d->>'provider_count')::int = (
    SELECT COUNT(DISTINCT group_id) FROM public.reservations
    WHERE event_id = v_ev AND status = ANY (public.estados_que_ocupan())),
    '[13] provider_count no coincide con el criterio real del candado';
  ASSERT (v_d->>'provider_limit')::int = 20, '[13] provider_limit';

  -- ══ [10] payment_status que no son dinero entrado ═════════════════════════
  DECLARE v_ev3 UUID; v_gx UUID; v_st TEXT;
  BEGIN
    RESET role;
    INSERT INTO public.events (client_id,event_date,event_time,address,status)
    VALUES (v_client, CURRENT_DATE+501, '18:00', 'RT693 Estados de pago', 'active') RETURNING id INTO v_ev3;
    -- UN GRUPO POR FILA: cuatro reservas del mismo grupo a la misma hora las
    -- rechaza enforce_group_availability con 'time_overlap' (regla real del
    -- calendario propio del grupo, ajena a este dashboard).
    FOREACH v_st IN ARRAY ARRAY['refunded','paid_blocked','payment_failed','unpaid'] LOOP
      INSERT INTO public.groups (id,owner_id,name,genre,country_id)
      VALUES (gen_random_uuid(),v_owner,'RT693 EstadosPago '||v_st,'Banda',v_mx) RETURNING id INTO v_gx;
      INSERT INTO public.reservations (id,client_id,group_id,event_id,event_date,event_time,address,
        total_price,status,payment_status,currency_code,hours_count)
      VALUES (gen_random_uuid(),v_client,v_gx,v_ev3,CURRENT_DATE+501,'18:00','RT693 Estados de pago',
        1000,'accepted',v_st,'MXN',3);
    END LOOP;

    PERFORM set_config('request.jwt.claims', json_build_object('sub',v_client::text,'role','authenticated')::text, true);
    PERFORM set_config('role','authenticated',true);
    v_d := public.client_get_event_dashboard(v_ev3);
    SELECT t INTO v_t FROM jsonb_array_elements(v_d->'totals_by_currency') t WHERE t->>'currency_code'='MXN';
    ASSERT (v_t->>'contracted')::numeric = 4000, '[10] contratado esperado 4000';
    ASSERT (v_t->>'paid')::numeric = 0,
      '[10] refunded/paid_blocked/payment_failed/unpaid NO son dinero entrado; llegó ' || (v_t->>'paid');
    ASSERT (v_t->>'pending')::numeric = 4000, '[10] pendiente';
  END;

  -- ══ [16] Cotización que ya tiene reserva no se duplica ════════════════════
  DECLARE v_ev4 UUID; v_gy UUID; v_q UUID;
  BEGIN
    RESET role;
    INSERT INTO public.events (client_id,event_date,event_time,address,status)
    VALUES (v_client, CURRENT_DATE+502, '18:00', 'RT693 Sin duplicar', 'active') RETURNING id INTO v_ev4;
    INSERT INTO public.groups (id,owner_id,name,genre,country_id)
    VALUES (gen_random_uuid(),v_owner,'RT693 SinDuplicar','Banda',v_mx) RETURNING id INTO v_gy;
    INSERT INTO public.quotes (id,group_id,client_id,event_type,event_address,event_municipio,
      event_estado,event_date,event_time,duration_hours,status,venue_covered,venue_size,
      needs_sound,base_price,total_amount,event_id,num_personas)
    VALUES (gen_random_uuid(),v_gy,v_client,'boda','RT693 Sin duplicar','Zapopan','Jalisco',
      CURRENT_DATE+502,'18:00',4,'quoted','si','salon_mediano','no',900,1100,v_ev4,40)
    RETURNING id INTO v_q;
    INSERT INTO public.reservations (id,client_id,group_id,event_id,event_date,event_time,address,
      total_price,status,payment_status,currency_code,hours_count,quote_id)
    VALUES (gen_random_uuid(),v_client,v_gy,v_ev4,CURRENT_DATE+502,'18:00','RT693 Sin duplicar',
      1100,'accepted','unpaid','MXN',3,v_q);

    PERFORM set_config('request.jwt.claims', json_build_object('sub',v_client::text,'role','authenticated')::text, true);
    PERFORM set_config('role','authenticated',true);
    v_d := public.client_get_event_dashboard(v_ev4);
    ASSERT jsonb_array_length(v_d->'services') = 1,
      '[16] la cotización con reserva no debe duplicarse; servicios = ' || jsonb_array_length(v_d->'services')::text;
    SELECT i INTO v_svc FROM jsonb_array_elements(v_d->'services') i LIMIT 1;
    ASSERT v_svc->>'kind' = 'reservation', '[16] debería quedar la reserva, no la cotización';
  END;

  -- ══ [17] events.total_price intacto y sin usarse ═══════════════════════════
  RESET role;
  ASSERT (SELECT COALESCE(total_price,0) FROM public.events WHERE id = v_ev) = 0,
    '[17] el dashboard escribió events.total_price';

  -- ══ [18] Sin overloads ════════════════════════════════════════════════════
  SELECT count(*) INTO v_n FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
   WHERE n.nspname='public' AND p.proname='client_get_event_dashboard';
  ASSERT v_n = 1, '[18] overload: ' || v_n::text;

  RAISE EXCEPTION 'TEST_REPORT sql/693: TODO PASÓ (18/18) — sin sesión/ajeno/inexistente rechazados sin filtrar datos; evento vacío con listas vacías; presupuesto declarado sin reservas; cotización pendiente visible y sin contar como contratada; contratado MXN 43000 excluyendo la cancelada de 99000; pagado 19000 con el ANTICIPO contando solo 5000; completed SÍ cuenta; refunded/paid_blocked/payment_failed/unpaid NO son dinero entrado; dos monedas en bloques independientes jamás sumadas y el presupuesto MXN sin aparecer en USD; presupuesto rebasado informa over_budget y remaining negativo SIN bloquear nuevas reservas; provider_count coincide con el criterio real del candado y provider_limit 20; misma categoría repetida; género compuesto clasificado como grupo; cotización con reserva sin duplicar; events.total_price intacto; sin overloads';
END
$suite$;

ROLLBACK;
