-- ============================================================
-- sql/602_regression_suite_notifications_referrals.sql
-- SUITE DE REGRESIÓN — ✅ CORRIÓ 41/41 PASS 2026-09-14. No aplica nada,
-- solo prueba. Correr esto ANTES y
-- DESPUÉS de tocar cualquier función relacionada con notificaciones,
-- referidos, o el choque de horarios entre proveedores. Si algo de esto
-- alguna vez vuelve a fallar, este archivo lo va a detectar en segundos
-- en vez de descubrirse semanas después con un usuario real afectado.
--
-- PETICIÓN REAL DEL USUARIO (2026-09-03): "asegura cada cosa que ya
-- funcione" — preocupación real de que un cambio futuro, sin querer,
-- deshaga una corrección ya hecha (ej. si algún día hay que tocar
-- queue_push_notification() por otra razón y sin querer se pierde el
-- guard contra user_id NULL).
--
-- 100% SEGURO DE CORRER en cualquier momento: todo pasa dentro de
-- BEGIN...ROLLBACK, no modifica NADA de la base real. Reusa cuentas
-- reales existentes (Lala, dueños de grupo reales) solo como FK válidas
-- dentro de la transacción que se revierte — nunca les manda nada real.
--
-- CUBRE (con el número de sql/ donde se corrigió cada cosa):
--   1. notify_break_transitions()      — sql/600
--   2. queue_push_notification()       — sql/601 (guard NULL)
--   3. notify_today_events()           — sql/601 (fecha + body/data)
--   4. notify_inactive_groups()        — sql/601 (owner NULL)
--   5. notify_weekend_groups()         — sql/601 (owner NULL)
--   6. notifications_type_check        — sql/601 (4 tipos nuevos)
--   7. trg_referral_reward_on_payment  — sql/597 (moneda MXN/USD)
--   8. get_referral_stats              — sql/598 (moneda MXN/USD)
--   9. apply_referral_client_discount  — sql/599 (descuento sin tocar al grupo)
--  10. client_get_event_time_conflicts — sql/596 (comida/renta exentos)
--  11. group_default_break_type        — sql/603 (sin temporizador para
--      Comediante/Comida/renta de mesas-sillas-brincolines-inflables;
--      banda/solista/dj/luz y sonido sí conservan tandas). Payasos YA NO
--      está aquí (sql/625, 2026-09-05) — se fusionó con Shows y ahora
--      elige libremente, verificado también en este mismo check [11]
--  12. group_default_break_type (foto)  — sql/604 (Fotografía/Drones/
--      Cabina 360/Cabina fotográfica también sin temporizador)
--  13. create_advertisement_order       — sql/608 (clientes bloqueados,
--      números de teléfono bloqueados en título/subtítulo)
--  14. get_profile_ads                  — sql/607+609 (anuncio de perfil
--      solo se muestra en el perfil de una categoría DISTINTA a la del
--      anunciante — un músico nunca ve el anuncio de otro músico, correcto
--      incluso si el anunciante tiene varios grupos propios)
--  15. check_sponsored_availability /
--      check_recommendation_availability — sql/610 (cupo de 5 Destacado y
--      5 Recomendado POR CATEGORÍA por estado, ya no compartido entre
--      todas las categorías — Comida lleno no bloquea a Banda)
--  16. create_advertisement_order / place_recommendation_order — sql/612
--      (calculate_ad_price() es la única fuente de verdad; un precio
--      falso mandado por el cliente ya NO se usa — se recalcula siempre
--      server-side; Recomendado cuesta más que Destacado a propósito)
--  17. admin_activate_bidding / admin_deactivate_group('bidding') —
--      sql/613+614 (la función SIEMPRE tronaba por falta de user_id en
--      bid_orders — nunca había insertado una fila con éxito; y aunque
--      insertara, nunca actualizaba groups.bid_amount/bid_ends_at, que es
--      lo único que el Explorador lee para el ranking/insignia real —
--      "regalar Bidding" nunca se había visto reflejado en la app)
--  18. get_group_ranking_position — sql/615 (rankea por ESTADO, no por
--      ciudad — mismo criterio que Destacado/Recomendado; dos grupos de
--      distinta ciudad del mismo estado ahora compiten entre sí de verdad)
--  19. confirm_gift_payment (screen) — sql/616 (TODOS los regalos/propinas
--      abren GiftRevealScreen, no solo "Otro monto" — insignia primero,
--      monto después, para que se emocionen igual con cualquier regalo)
--  20. confirm_gift_payment (notif admin) — sql/617 (la notificación de
--      "Regalo grande enviado" decía "Trofeo" incluso cuando en realidad
--      era un monto personalizado que reutiliza el gift_id de Trofeo)
--  21. groups.show_gifts_to_members — sql/618 (nace en false; el dueño lo
--      prende para que sus músicos integrantes vean en su propia Wallet
--      los regalos/dinero del grupo — transparencia contra el encargado)
--  22. delete_group_invitation — sql/619 (notifica al integrante removido,
--      no puede sacarse "en silencio" solo del membership)
--  23. trg_notify_gift_visibility_off — sql/620 (avisa a los integrantes
--      actuales si el dueño apaga el interruptor de sql/618; no dispara
--      en false->false ni cuando nunca hubo integrantes viéndolo)
--  24. event_break_boundaries — matemática exacta tipo A+extras, debe
--      coincidir siempre con generateBreakSchedule (calculations.ts) para
--      que el timer del grupo y las notificaciones del servidor no se
--      desincronicen (auditoría 2026-09-05)
--  25. complete_event — candado de duración mínima + idempotencia
--      (auditoría 2026-09-05, sin cambios, ya funcionaba bien)
--  26. auto_finalize_stuck_events — sql/621 (columna event_request_id
--      inexistente en job_invitations hacía que la función SIEMPRE
--      tronara al intentar cerrar un evento realmente atorado — la red de
--      seguridad para cuando el grupo cierra la app nunca había cerrado
--      un solo evento)
--  27. group_default_break_type (Espectáculo/MC) — sql/622
--  28. category_details jsonb (groups + quotes) — sql/623 (Comida/Renta/
--      Payasos/Fotógrafos guardan y leen sus propias preguntas tal cual;
--      filas viejas sin el campo nacen en '{}', nunca NULL)
--  29. get_category_field_values — sql/624 (lista de opciones que crece
--      sola por categoría, sin tabla nueva; dedup y aislada por categoría)
--  30. group_category_key (Shows + MC) — sql/625 (Espectáculo/Payasos/
--      Mago/Personajes/Animación clasifican como 'espectaculo', Maestro
--      de Ceremonias como 'mc' — nunca se habían agregado desde sql/622,
--      devolvía NULL para ambos)
--  31. send_event_reminders_2h — sql/643 (recordatorio de "2 horas antes"
--      ahora usa reservations.event_tz, la zona horaria REAL del evento
--      [sql/514], en vez de asumir siempre 'America/Mexico_City'. Antes
--      de esto, un evento en EE.UU./Canadá o en un estado fronterizo de
--      México podía recibir el recordatorio hasta ±4 horas fuera de
--      tiempo)
--  32. notify_quote_request (grupo normal) — sql/648 (un grupo que NO
--      está en modo conserjería sigue notificando al dueño exactamente
--      igual que siempre — cero cambio de comportamiento — y esa
--      cotización no le llega de más al admin/admin_ops)
--  33. notify_quote_request + admin_respond_quote (modo conserjería,
--      EE.UU.) — sql/648 (un grupo en modo conserjería NO notifica al
--      dueño; notifica al admin completo [respetando su mute de país] y
--      al admin_ops de ese país; admin_ops puede poner precio y el
--      cliente recibe la cotización normal, como si el grupo mismo
--      hubiera respondido) + markup 20% sobre base+traslado (sql/648 fix)
--      + precio de hora extra opcional (sql/650)
--  34. admin_respond_quote rechaza grupo sin modo conserjería — sql/648
--      (un admin no puede "ayudar" a un grupo que ya maneja su propia
--      cuenta — la cotización se queda intacta en 'pending')
--  35. submit_provider_application — sql/649 (anon puede mandar solicitud,
--      queda pending y notifica al admin/admin_ops correcto; categoría
--      inválida se rechaza)
--  36. admin_get_provider_applications — sql/649 (aislamiento por país:
--      admin_ops de EE.UU. no ve una solicitud de México)
--  37. admin_approve_provider_application — sql/649 (crea auth.users +
--      profiles + groups de verdad, concierge_mode=true por default,
--      bloquea re-aprobar — evita crear una 2a cuenta por error)
--  38. admin_reject_provider_application — sql/649 (guarda el motivo,
--      bloquea re-procesar una solicitud ya resuelta)
--  39. admin_propose_extra_hours + admin_get_concierge_live_reservations —
--      sql/651 (el admin puede proponerle horas extra al cliente en
--      nombre de un grupo en conserjería mientras el evento está en
--      curso, aislado por país, usa el precio ya negociado si no se
--      manda uno nuevo, rechaza sin precio disponible y rechaza si el
--      evento ya no está en curso)
--  40. approve_extra_hour_payment_atomic + confirm_extra_hour_stripe_payment
--      avisan al admin (modo conserjería) cuando se paga una hora extra
--      (saldo o tarjeta) + negotiated_1h/2h/3h visible en
--      admin_get_concierge_live_reservations — sql/652/653
--  41. admin_respond_quote + admin_propose_extra_hours con paquetes
--      independientes por número de horas (descuento por volumen, NO un
--      precio por hora multiplicado) — sql/653
--
-- Cómo leer el resultado: si TODO pasa, ves un solo error final que dice
-- literalmente "REGRESSION_SUITE: TODO PASÓ" — ES EL RESULTADO ESPERADO
-- (el ROLLBACK necesita un RAISE EXCEPTION para dispararse a propósito,
-- mismo patrón usado en toda esta sesión). Si algo de verdad falla, el
-- mensaje de error identifica EXACTAMENTE cuál prueba fue.
-- ============================================================

BEGIN;

DO $suite$
DECLARE
  v_owner       UUID := '929ba9ba-1dfd-4b76-abf1-18168b1ac1ba'; -- real, reusado solo como FK válida
  v_owner2      UUID := '6f924da5-54b1-46cc-a8bd-33e8b0f7f2fa'; -- real, reusado solo como FK válida
  v_client      UUID := '889e7168-a30a-49c5-a32a-cbeb320d00f8'; -- Lala, real
  v_talent      UUID := '0246810b-c8ba-484e-84d1-68b1e28fb550'; -- real, reusado solo como FK válida
  v_country_mx  UUID;
  v_country_us  UUID;
  v_group       UUID;
  v_group_us    UUID;
  v_group_cheap UUID;
  v_res_id      UUID;
  v_quote_id    UUID;
  v_result      jsonb;
  v_res         RECORD;
  v_ref         RECORD;
BEGIN
  SELECT id INTO v_country_mx FROM public.countries WHERE currency_code='MXN' LIMIT 1;
  SELECT id INTO v_country_us FROM public.countries WHERE currency_code='USD' LIMIT 1;

  -- ══ 1. notify_break_transitions — las 4 notificaciones + no duplica ══
  INSERT INTO public.groups (id, owner_id, name, genre, country_id)
    VALUES (gen_random_uuid(), v_owner, 'RT602 Timer', 'Banda', v_country_mx) RETURNING id INTO v_group;
  INSERT INTO public.job_invitations (id, group_id, invited_user_id, status, invitation_type)
    VALUES (gen_random_uuid(), v_group, v_talent, 'accepted', 'membership');
  INSERT INTO public.reservations (id, client_id, group_id, event_date, event_time, address, total_price, status, break_type, hours_count, event_started_at)
    VALUES (gen_random_uuid(), v_client, v_group, CURRENT_DATE, '18:00', 'Dir', 9000, 'in_progress', 'B', 3, NOW() - INTERVAL '90 minutes')
    RETURNING id INTO v_res_id;
  PERFORM public.notify_break_transitions();
  ASSERT EXISTS(SELECT 1 FROM notifications WHERE user_id=v_client AND type='break_started' AND data->>'reservation_id'=v_res_id::text),
    '[1] REGRESIÓN: notify_break_transitions no notificó al cliente — revisar sql/600';
  ASSERT EXISTS(SELECT 1 FROM notifications WHERE user_id=v_talent AND type='break_started' AND data->>'reservation_id'=v_res_id::text),
    '[1] REGRESIÓN: notify_break_transitions no notificó al talento — revisar sql/600 (¿volvió ji.event_request_id?)';
  PERFORM public.notify_break_transitions();
  ASSERT (SELECT count(*) FROM notifications WHERE user_id=v_client AND type='break_started' AND data->>'reservation_id'=v_res_id::text) = 1,
    '[1] REGRESIÓN: notify_break_transitions duplicó al correr 2 veces';

  -- ══ 2. queue_push_notification — guard contra user_id NULL ══════════
  BEGIN
    PERFORM public.queue_push_notification(NULL, 'system', 't', 'b', '{}');
  EXCEPTION WHEN OTHERS THEN
    RAISE EXCEPTION '[2] REGRESIÓN: queue_push_notification volvió a tronar con user_id NULL — revisar sql/601';
  END;

  -- ══ 3. notify_today_events — fecha real + body/data pobladas ═══════
  -- (grupo NUEVO y separado del [1] — mismo group_id con 2 reservas hoy
  -- chocaría con el trigger real de disponibilidad, que sí debe seguir
  -- bloqueando eso; no es parte de lo que esta prueba busca cubrir)
  -- ⚠️ Usa la fecha de HOY en México (no CURRENT_DATE del servidor, que
  -- corre en UTC) — notify_today_events compara contra el "hoy" de la
  -- zona horaria del evento (sql/643); durante la ventana nocturna en que
  -- UTC ya cambió de día pero México no, CURRENT_DATE(UTC) queda un día
  -- adelantado y esta prueba fallaba en falso (hallazgo real 2026-09-14 —
  -- no era un bug de la función, era la prueba comparando mal).
  DECLARE
    v_group3 UUID;
    v_today_mx DATE := (NOW() AT TIME ZONE 'America/Mexico_City')::date;
  BEGIN
    INSERT INTO public.groups (id, owner_id, name, genre, country_id)
      VALUES (gen_random_uuid(), v_owner, 'RT602 HoyEvento', 'Banda', v_country_mx) RETURNING id INTO v_group3;
    INSERT INTO public.reservations (id, client_id, group_id, event_date, event_time, address, total_price, status)
      VALUES (gen_random_uuid(), v_client, v_group3, v_today_mx, '20:00', 'Dir', 9000, 'confirmed')
      RETURNING id INTO v_res_id;
  END;
  PERFORM public.notify_today_events();
  ASSERT EXISTS(SELECT 1 FROM notifications WHERE user_id=v_client AND type='event_reminder_24h' AND data->>'reservation_id'=v_res_id::text AND body <> ''),
    '[3] REGRESIÓN: notify_today_events no notificó o volvió el body vacío — revisar sql/601 (¿volvió CURRENT_DATE::text?)';

  -- ══ 4/5. notify_inactive_groups y notify_weekend_groups sobreviven owner NULL ══
  INSERT INTO public.groups (id, owner_id, name, genre, country_id, is_active)
    VALUES (gen_random_uuid(), NULL, 'RT602 SinDueno', 'Banda', v_country_mx, true);
  BEGIN
    PERFORM public.notify_inactive_groups(9999);
  EXCEPTION WHEN OTHERS THEN
    RAISE EXCEPTION '[4] REGRESIÓN: notify_inactive_groups volvió a tronar con un grupo sin dueño — revisar sql/601';
  END;
  BEGIN
    PERFORM public.notify_weekend_groups();
  EXCEPTION WHEN OTHERS THEN
    RAISE EXCEPTION '[5] REGRESIÓN: notify_weekend_groups volvió a tronar con un grupo sin dueño — revisar sql/601';
  END;

  -- ══ 6. notifications_type_check — los 4 tipos de engagement ═════════
  BEGIN
    INSERT INTO public.notifications (user_id, type, title, body, data) VALUES (v_owner, 'engagement_inactive_group', 't', 'b', '{}');
    INSERT INTO public.notifications (user_id, type, title, body, data) VALUES (v_owner, 'engagement_groups_available', 't', 'b', '{}');
    INSERT INTO public.notifications (user_id, type, title, body, data) VALUES (v_owner, 'engagement_weekend_reminder', 't', 'b', '{}');
    INSERT INTO public.notifications (user_id, type, title, body, data) VALUES (v_owner, 'engagement_activate_now', 't', 'b', '{}');
  EXCEPTION WHEN OTHERS THEN
    RAISE EXCEPTION '[6] REGRESIÓN: falta alguno de los 4 tipos de engagement en notifications_type_check — revisar sql/601';
  END;

  -- ══ 7/8. Bono de referido — moneda MXN vs USD, y stats ══════════════
  INSERT INTO public.groups (id, owner_id, name, genre, country_id, referral_code)
    VALUES (gen_random_uuid(), v_owner, 'RT602 Grupo MX', 'Banda', v_country_mx, 'RT602MX') RETURNING id INTO v_group;
  INSERT INTO public.groups (id, owner_id, name, genre, country_id, referral_code)
    VALUES (gen_random_uuid(), v_owner2, 'RT602 Grupo US', 'Banda', v_country_us, 'RT602US') RETURNING id INTO v_group_us;
  INSERT INTO public.referral_events (group_id, client_id, referral_code) VALUES (v_group, v_client, 'RT602MX');
  INSERT INTO public.referral_events (group_id, client_id, referral_code) VALUES (v_group_us, v_talent, 'RT602US');

  INSERT INTO public.reservations (id, client_id, group_id, event_date, event_time, address, total_price, status, payment_status)
    VALUES (gen_random_uuid(), v_client, v_group, CURRENT_DATE + 5, '18:00', 'Dir', 1000, 'pending', 'unpaid') RETURNING id INTO v_res_id;
  UPDATE public.reservations SET payment_status = 'fully_paid' WHERE id = v_res_id;
  SELECT * INTO v_res FROM public.wallet_transactions WHERE reservation_id = v_res_id AND description = 'Bono por referido convertido';
  ASSERT v_res.amount = 100 AND v_res.currency_code = 'MXN',
    '[7] REGRESIÓN: bono de referido MX ya no da 100 MXN — revisar sql/597';

  INSERT INTO public.reservations (id, client_id, group_id, event_date, event_time, address, total_price, status, payment_status)
    VALUES (gen_random_uuid(), v_talent, v_group_us, CURRENT_DATE + 5, '18:00', 'Dir', 1000, 'pending', 'unpaid') RETURNING id INTO v_res_id;
  UPDATE public.reservations SET payment_status = 'fully_paid' WHERE id = v_res_id;
  SELECT * INTO v_res FROM public.wallet_transactions WHERE reservation_id = v_res_id AND description = 'Bono por referido convertido';
  ASSERT v_res.amount = 5 AND v_res.currency_code = 'USD',
    '[7] REGRESIÓN: bono de referido US ya no da 5 USD — revisar sql/597 (¿volvió a dar 100 mal etiquetado?)';

  RESET role;
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_owner::text, 'role','authenticated')::text, true);
  PERFORM set_config('role','authenticated', true);
  v_result := public.get_referral_stats(v_group);
  ASSERT v_result->>'currency_code' = 'MXN', '[8] REGRESIÓN: get_referral_stats dejó de devolver currency_code — revisar sql/598';
  RESET role;

  -- ══ 9. Descuento al cliente referido — sin tocar al grupo, tope de comisión ══
  INSERT INTO public.groups (id, owner_id, name, genre, country_id, referral_code)
    VALUES (gen_random_uuid(), v_owner, 'RT602 Grupo Barato', 'Banda', v_country_mx, 'RT602CH') RETURNING id INTO v_group_cheap;
  INSERT INTO public.referral_events (group_id, client_id, referral_code) VALUES (v_group_cheap, v_owner2, 'RT602CH');
  INSERT INTO public.quotes (id, group_id, client_id, event_date, event_time, duration_hours, status,
    event_type, event_address, event_municipio, event_estado, venue_covered, venue_size, needs_sound,
    base_price, commission_amount, total_amount, group_earnings)
    VALUES (gen_random_uuid(), v_group_cheap, v_owner2, CURRENT_DATE + 6, '18:00', 3, 'pending',
      'boda', 'Dir', 'Muni', 'Edo', 'si', 'salon_mediano', 'no_group_brings', 200, 40, 240, 200)
    RETURNING id INTO v_quote_id;
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_owner2::text, 'role','authenticated')::text, true);
  PERFORM set_config('role','authenticated', true);
  v_result := public.client_accept_quote(v_quote_id, NULL, NULL);
  RESET role;
  SELECT * INTO v_res FROM public.reservations WHERE id = (v_result->>'reservation_id')::uuid;
  ASSERT v_res.base_price = 200, '[9] REGRESIÓN: el descuento al cliente afectó lo que gana el grupo — revisar sql/599';
  ASSERT v_res.platform_commission = 0, '[9] REGRESIÓN: el descuento dejó la comisión de Daricefy en negativo — revisar sql/599';

  -- ══ 10. Choque de horarios — comida exenta, choque real detectado ═══
  INSERT INTO public.groups (id, owner_id, name, genre, country_id)
    VALUES (gen_random_uuid(), v_owner, 'RT602 Banda', 'Banda', v_country_mx) RETURNING id INTO v_group;
  DECLARE
    v_group_comida UUID; v_event UUID;
  BEGIN
    INSERT INTO public.groups (id, owner_id, name, genre, country_id)
      VALUES (gen_random_uuid(), v_owner, 'RT602 Comida', 'Comida', v_country_mx) RETURNING id INTO v_group_comida;
    INSERT INTO public.events (id, client_id, event_date, event_time, address, status)
      VALUES (gen_random_uuid(), v_client, CURRENT_DATE + 7, '13:00', 'Dir', 'active') RETURNING id INTO v_event;
    INSERT INTO public.quotes (id, group_id, client_id, event_id, event_date, event_time, duration_hours, status,
      event_type, event_address, event_municipio, event_estado, venue_covered, venue_size, needs_sound)
      VALUES (gen_random_uuid(), v_group, v_client, v_event, CURRENT_DATE + 7, '13:00', 3, 'pending',
        'boda', 'Dir', 'Muni', 'Edo', 'si', 'salon_mediano', 'no_group_brings');
    INSERT INTO public.quotes (id, group_id, client_id, event_id, event_date, event_time, duration_hours, status,
      event_type, event_address, event_municipio, event_estado, venue_covered, venue_size, needs_sound)
      VALUES (gen_random_uuid(), v_group_comida, v_client, v_event, CURRENT_DATE + 7, '13:00', 3, 'pending',
        'boda', 'Dir', 'Muni', 'Edo', 'si', 'salon_mediano', 'no_group_brings');

    RESET role;
    PERFORM set_config('request.jwt.claims', json_build_object('sub', v_client::text, 'role','authenticated')::text, true);
    PERFORM set_config('role','authenticated', true);
    v_result := public.client_get_event_time_conflicts(v_event, NULL);
    RESET role;
    ASSERT jsonb_array_length(v_result->'ranges') = 1,
      '[10] REGRESIÓN: client_get_event_time_conflicts ya no excluye a Comida, o dejó de detectar el choque real — revisar sql/596';
  END;

  -- ══ 11. Sin temporizador de descansos para categorías sin performance ══
  -- 2026-09-05 (sql/625): Payasos se fusionó con Espectáculo ("Shows") y
  -- DEJÓ de estar forzado a 'D' a propósito (ahora elige libremente, igual
  -- que Espectáculo/Banda) — se reemplaza el ejemplo de "sí forzado" por
  -- Comediante (que SÍ sigue forzado) y se agrega un caso explícito
  -- confirmando que Payasos ahora es NULL (cambio intencional, no bug).
  DECLARE
    v_group_banda UUID; v_group_comediante UUID; v_group_payaso UUID;
  BEGIN
    INSERT INTO public.groups (id, owner_id, name, genre, country_id)
      VALUES (gen_random_uuid(), v_owner, 'RT602 Banda11', 'Banda', v_country_mx) RETURNING id INTO v_group_banda;
    INSERT INTO public.groups (id, owner_id, name, genre, country_id)
      VALUES (gen_random_uuid(), v_owner, 'RT602 Comediante11', 'Comediante', v_country_mx) RETURNING id INTO v_group_comediante;
    INSERT INTO public.groups (id, owner_id, name, genre, country_id)
      VALUES (gen_random_uuid(), v_owner, 'RT602 Payaso11', 'Payasos', v_country_mx) RETURNING id INTO v_group_payaso;

    INSERT INTO public.quotes (id, group_id, client_id, event_date, event_time, duration_hours, status,
      event_type, event_address, event_municipio, event_estado, venue_covered, venue_size, needs_sound,
      base_price, commission_amount, total_amount, group_earnings)
      VALUES (gen_random_uuid(), v_group_banda, v_client, CURRENT_DATE + 8, '18:00', 3, 'pending',
        'boda', 'Dir', 'Muni', 'Edo', 'si', 'salon_mediano', 'no_group_brings', 9000, 1800, 10800, 9000)
      RETURNING id INTO v_quote_id;
    RESET role;
    PERFORM set_config('request.jwt.claims', json_build_object('sub', v_client::text, 'role','authenticated')::text, true);
    PERFORM set_config('role','authenticated', true);
    v_result := public.client_accept_quote(v_quote_id, NULL, NULL);
    RESET role;
    SELECT * INTO v_res FROM public.reservations WHERE id = (v_result->>'reservation_id')::uuid;
    ASSERT v_res.break_type IS NULL,
      '[11] REGRESIÓN: una banda musical ya no debería traer break_type forzado (grupo elige después) — revisar sql/603';

    INSERT INTO public.quotes (id, group_id, client_id, event_date, event_time, duration_hours, status,
      event_type, event_address, event_municipio, event_estado, venue_covered, venue_size, needs_sound,
      base_price, commission_amount, total_amount, group_earnings)
      VALUES (gen_random_uuid(), v_group_comediante, v_client, CURRENT_DATE + 8, '18:00', 3, 'pending',
        'boda', 'Dir', 'Muni', 'Edo', 'si', 'salon_mediano', 'no_group_brings', 3000, 600, 3600, 3000)
      RETURNING id INTO v_quote_id;
    RESET role;
    PERFORM set_config('request.jwt.claims', json_build_object('sub', v_client::text, 'role','authenticated')::text, true);
    PERFORM set_config('role','authenticated', true);
    v_result := public.client_accept_quote(v_quote_id, NULL, NULL);
    RESET role;
    SELECT * INTO v_res FROM public.reservations WHERE id = (v_result->>'reservation_id')::uuid;
    ASSERT v_res.break_type = 'D',
      '[11] REGRESIÓN: Comediante ya no trae break_type=D automático (volvería a pedirle tandas/descansos que no aplican) — revisar sql/603';

    INSERT INTO public.quotes (id, group_id, client_id, event_date, event_time, duration_hours, status,
      event_type, event_address, event_municipio, event_estado, venue_covered, venue_size, needs_sound,
      base_price, commission_amount, total_amount, group_earnings)
      VALUES (gen_random_uuid(), v_group_payaso, v_client, CURRENT_DATE + 8, '18:00', 3, 'pending',
        'boda', 'Dir', 'Muni', 'Edo', 'si', 'salon_mediano', 'no_group_brings', 3000, 600, 3600, 3000)
      RETURNING id INTO v_quote_id;
    RESET role;
    PERFORM set_config('request.jwt.claims', json_build_object('sub', v_client::text, 'role','authenticated')::text, true);
    PERFORM set_config('role','authenticated', true);
    v_result := public.client_accept_quote(v_quote_id, NULL, NULL);
    RESET role;
    SELECT * INTO v_res FROM public.reservations WHERE id = (v_result->>'reservation_id')::uuid;
    ASSERT v_res.break_type IS NULL,
      '[11] REGRESIÓN: Payasos ya no debería estar forzado a D — ahora se fusionó con Shows y elige libremente — revisar sql/625';
  END;

  -- ══ 12. Fotógrafos (Fotografía/Drones/Cabina 360/Cabina fotográfica) ══
  -- sin temporizador de descansos, mismo mecanismo que 11 — sql/604
  DECLARE
    v_group_foto UUID;
  BEGIN
    INSERT INTO public.groups (id, owner_id, name, genre, country_id)
      VALUES (gen_random_uuid(), v_owner, 'RT602 Foto12', 'Fotografía', v_country_mx) RETURNING id INTO v_group_foto;

    INSERT INTO public.quotes (id, group_id, client_id, event_date, event_time, duration_hours, status,
      event_type, event_address, event_municipio, event_estado, venue_covered, venue_size, needs_sound,
      base_price, commission_amount, total_amount, group_earnings)
      VALUES (gen_random_uuid(), v_group_foto, v_client, CURRENT_DATE + 9, '18:00', 3, 'pending',
        'boda', 'Dir', 'Muni', 'Edo', 'si', 'salon_mediano', 'no_group_brings', 4000, 800, 4800, 4000)
      RETURNING id INTO v_quote_id;
    RESET role;
    PERFORM set_config('request.jwt.claims', json_build_object('sub', v_client::text, 'role','authenticated')::text, true);
    PERFORM set_config('role','authenticated', true);
    v_result := public.client_accept_quote(v_quote_id, NULL, NULL);
    RESET role;
    SELECT * INTO v_res FROM public.reservations WHERE id = (v_result->>'reservation_id')::uuid;
    ASSERT v_res.break_type = 'D',
      '[12] REGRESIÓN: Fotografía ya no trae break_type=D automático — revisar sql/604';
  END;

  -- ══ 13. create_advertisement_order — cliente bloqueado, teléfono bloqueado ══
  DECLARE v_adres JSONB;
  BEGIN
    RESET role;
    PERFORM set_config('request.jwt.claims', json_build_object('sub', v_client::text, 'role','authenticated')::text, true);
    PERFORM set_config('role','authenticated', true);
    v_adres := public.create_advertisement_order('banner_home', 'Anuncio de cliente', NULL, 'Ver', NULL, 'none', NULL, 'none', NULL, 'national', NULL, NULL, NULL, 7, 500, NULL, NULL, NULL);
    RESET role;
    ASSERT (v_adres->>'ok')::boolean = false AND v_adres->>'error' = 'clients_cannot_advertise',
      '[13] REGRESIÓN: un cliente SÍ pudo comprar publicidad — revisar sql/608: ' || v_adres::text;

    RESET role;
    PERFORM set_config('request.jwt.claims', json_build_object('sub', v_owner::text, 'role','authenticated')::text, true);
    PERFORM set_config('role','authenticated', true);
    v_adres := public.create_advertisement_order('banner_home', 'Contáctanos al 5512345678', NULL, 'Ver', NULL, 'none', NULL, 'none', NULL, 'national', NULL, NULL, NULL, 7, 500, NULL, NULL, NULL);
    RESET role;
    ASSERT (v_adres->>'ok')::boolean = false AND v_adres->>'error' = 'phone_number_not_allowed',
      '[13] REGRESIÓN: un título con teléfono SÍ pasó — revisar sql/608: ' || v_adres::text;
  END;

  -- ══ 14. get_profile_ads — solo categoría distinta a la del anunciante,
  -- INCLUSO si el anunciante tiene varios grupos propios (hallazgo real
  -- corriendo esta misma suite — sql/609). Usa v_talent como anunciante
  -- (nunca es owner_id de ningún grupo en el resto de esta suite) para
  -- que el caso quede aislado — v_owner ya acumuló grupos Payasos/
  -- Fotografía en checks anteriores [11][12], y de verdad SÍ debe quedar
  -- excluido de anunciarse en OTRO perfil Payasos por esos (correcto,
  -- no es lo que este check puntual quiere aislar). ══
  DECLARE
    v_ad_banda UUID; v_g_banda2 UUID; v_g_mariachi2 UUID;
    v_g_mariachi_viewed UUID; v_g_payaso_viewed UUID;
    v_adres2 JSONB; v_rows2 INT;
  BEGIN
    -- El anunciante (v_talent, dueño limpio) tiene DOS grupos, ambos músicos
    INSERT INTO public.groups (id, owner_id, name, genre, country_id, state)
      VALUES (gen_random_uuid(), v_talent, 'RT602 Banda14', 'Banda', v_country_mx, 'Jalisco') RETURNING id INTO v_g_banda2;
    INSERT INTO public.groups (id, owner_id, name, genre, country_id, state)
      VALUES (gen_random_uuid(), v_talent, 'RT602 Mariachi14', 'Mariachi', v_country_mx, 'Jalisco') RETURNING id INTO v_g_mariachi2;
    -- Perfiles de OTRO dueño (v_owner2) donde se revisa si aparece el anuncio
    INSERT INTO public.groups (id, owner_id, name, genre, country_id, state)
      VALUES (gen_random_uuid(), v_owner2, 'RT602 Mariachi14 Visto', 'Mariachi', v_country_mx, 'Jalisco') RETURNING id INTO v_g_mariachi_viewed;
    INSERT INTO public.groups (id, owner_id, name, genre, country_id, state)
      VALUES (gen_random_uuid(), v_owner2, 'RT602 Payaso14 Visto', 'Payasos', v_country_mx, 'Jalisco') RETURNING id INTO v_g_payaso_viewed;

    RESET role;
    PERFORM set_config('request.jwt.claims', json_build_object('sub', v_talent::text, 'role','authenticated')::text, true);
    PERFORM set_config('role','authenticated', true);
    v_adres2 := public.create_advertisement_order('profile_ad', 'Banda anuncia', NULL, 'Ver', NULL, 'none', NULL, 'none', NULL, 'national', NULL, NULL, NULL, 7, 350, NULL, NULL, NULL);
    RESET role;
    ASSERT (v_adres2->>'ok')::boolean = true, '[14] REGRESIÓN: una Banda ya no pudo comprar profile_ad — revisar sql/607: ' || v_adres2::text;
    v_ad_banda := (v_adres2->>'ad_id')::uuid;
    UPDATE public.advertisements SET status='active' WHERE id = v_ad_banda;

    SELECT count(*) INTO v_rows2 FROM public.get_profile_ads(v_g_mariachi_viewed, NULL, 'Jalisco') WHERE id = v_ad_banda;
    ASSERT v_rows2 = 0, '[14] REGRESIÓN: el anuncio (dueño con 2 grupos músicos) SÍ apareció en perfil músico de otro dueño — revisar sql/609';

    SELECT count(*) INTO v_rows2 FROM public.get_profile_ads(v_g_payaso_viewed, NULL, 'Jalisco') WHERE id = v_ad_banda;
    ASSERT v_rows2 = 1, '[14] REGRESIÓN: el anuncio NO apareció en perfil de Payaso de otro dueño (categoría distinta) — revisar sql/607/609';
  END;

  -- ══ 15. Cupo de Destacado/Recomendado POR CATEGORÍA — sql/610 ═══════
  -- Estado ficticio único para no mezclar con anuncios reales activos.
  DECLARE
    v_state15 TEXT := 'RT602 EstadoTest15';
    v_g15     UUID;
    v_res15   JSONB;
    j INT;
  BEGIN
    -- Llena las 5 plazas de Destacado para Comida en ese estado
    FOR j IN 1..5 LOOP
      INSERT INTO public.groups (id, owner_id, name, genre, country_id, state)
        VALUES (gen_random_uuid(), v_owner, 'RT602 Comida15-'||j, 'Comida', v_country_mx, v_state15)
        RETURNING id INTO v_g15;
      INSERT INTO public.sponsored_groups (group_id, advertiser_id, starts_at, ends_at, is_active)
        VALUES (v_g15, v_owner, NOW(), NOW() + interval '5 days', true);
    END LOOP;

    -- 6to grupo de Comida en el MISMO estado: cupo lleno, debe rechazarse
    INSERT INTO public.groups (id, owner_id, name, genre, country_id, state)
      VALUES (gen_random_uuid(), v_owner, 'RT602 Comida15-6', 'Comida', v_country_mx, v_state15)
      RETURNING id INTO v_g15;
    v_res15 := public.check_sponsored_availability(v_g15);
    ASSERT (v_res15->>'ok')::boolean = false,
      '[15] REGRESIÓN: 6to grupo de Comida SÍ obtuvo cupo de Destacado (ya no hay tope de 5 por categoría) — revisar sql/610: ' || v_res15::text;

    -- Grupo de Banda en el MISMO estado: categoría distinta, cupo propio, debe aceptarse
    INSERT INTO public.groups (id, owner_id, name, genre, country_id, state)
      VALUES (gen_random_uuid(), v_owner, 'RT602 Banda15', 'Banda', v_country_mx, v_state15)
      RETURNING id INTO v_g15;
    v_res15 := public.check_sponsored_availability(v_g15);
    ASSERT (v_res15->>'ok')::boolean = true,
      '[15] REGRESIÓN: Banda quedó bloqueada por el cupo lleno de Comida (el cupo de Destacado volvió a ser compartido, no por categoría) — revisar sql/610: ' || v_res15::text;

    -- Mismo patrón para Recomendado (recommendation_orders en vez de sponsored_groups)
    FOR j IN 1..5 LOOP
      INSERT INTO public.groups (id, owner_id, name, genre, country_id, state)
        VALUES (gen_random_uuid(), v_owner, 'RT602 Payaso15-'||j, 'Payasos', v_country_mx, v_state15)
        RETURNING id INTO v_g15;
      INSERT INTO public.recommendation_orders (group_id, status, state, starts_at, ends_at, duration_days, amount, price_per_day, is_free)
        VALUES (v_g15, 'paid', normalize_state_name(v_state15), NOW(), NOW() + interval '5 days', 5, 100, 20, false);
    END LOOP;

    INSERT INTO public.groups (id, owner_id, name, genre, country_id, state)
      VALUES (gen_random_uuid(), v_owner, 'RT602 Payaso15-6', 'Payasos', v_country_mx, v_state15)
      RETURNING id INTO v_g15;
    v_res15 := public.check_recommendation_availability(v_g15);
    ASSERT (v_res15->>'ok')::boolean = false,
      '[15] REGRESIÓN: 6to grupo de Payasos SÍ obtuvo cupo de Recomendado — revisar sql/610: ' || v_res15::text;

    INSERT INTO public.groups (id, owner_id, name, genre, country_id, state)
      VALUES (gen_random_uuid(), v_owner, 'RT602 Fotografo15', 'Fotografía', v_country_mx, v_state15)
      RETURNING id INTO v_g15;
    v_res15 := public.check_recommendation_availability(v_g15);
    ASSERT (v_res15->>'ok')::boolean = true,
      '[15] REGRESIÓN: Fotografía quedó bloqueada por el cupo lleno de Payasos en Recomendado — revisar sql/610: ' || v_res15::text;
  END;

  -- ══ 16. Precio de publicidad server-side — sql/612 ══════════════════
  -- El cliente ya NO puede inflar/deflactar el precio; siempre se
  -- recalcula con calculate_ad_price(). Recomendado > Destacado a la
  -- misma duración, a propósito (decisión real del usuario 2026-09-05).
  DECLARE
    v_adres3 JSONB; v_rec3 JSONB; v_g16 UUID;
  BEGIN
    RESET role;
    PERFORM set_config('request.jwt.claims', json_build_object('sub', v_owner::text, 'role','authenticated')::text, true);
    PERFORM set_config('role','authenticated', true);
    -- Perfil, 3 días, el cliente manda $1 a propósito — debe cobrar $129
    v_adres3 := public.create_advertisement_order('profile_ad', 'RT602 Precio16', NULL, 'Ver', NULL, 'image', NULL, 'none', NULL, 'city', NULL, NULL, NULL, 3, 1, NULL, NULL, NULL, false);
    RESET role;
    ASSERT (v_adres3->>'ok')::boolean = true, '[16] REGRESIÓN: falló la orden: ' || v_adres3::text;
    ASSERT (v_adres3->>'total')::numeric = 129, '[16] REGRESIÓN: el precio falso del cliente ($1) SÍ se usó — revisar sql/612: total=' || (v_adres3->>'total');

    -- Banner Home, 7 días, video — debe llevar +35% ($399 -> $538.65)
    RESET role;
    PERFORM set_config('request.jwt.claims', json_build_object('sub', v_owner::text, 'role','authenticated')::text, true);
    PERFORM set_config('role','authenticated', true);
    v_adres3 := public.create_advertisement_order('banner_home', 'RT602 Video16', NULL, 'Ver', NULL, 'video', NULL, 'none', NULL, 'city', NULL, NULL, NULL, 7, NULL, NULL, NULL, NULL, true);
    RESET role;
    ASSERT (v_adres3->>'total')::numeric = 538.65, '[16] REGRESIÓN: video ya no lleva el +35% en Banner Home — revisar sql/612: total=' || (v_adres3->>'total');

    -- Recomendado 7 días ($349) debe ser MAYOR que Destacado 7 días ($299)
    INSERT INTO public.groups (id, owner_id, name, genre, country_id, state)
      VALUES (gen_random_uuid(), v_owner, 'RT602 Rec16', 'Banda', v_country_mx, 'RT602 Estado16') RETURNING id INTO v_g16;
    RESET role;
    PERFORM set_config('request.jwt.claims', json_build_object('sub', v_owner::text, 'role','authenticated')::text, true);
    PERFORM set_config('role','authenticated', true);
    v_rec3 := public.place_recommendation_order(v_g16, 7);
    RESET role;
    ASSERT (v_rec3->>'ok')::boolean = true, '[16] REGRESIÓN: place_recommendation_order falló: ' || v_rec3::text;
    ASSERT (v_rec3->>'amount')::numeric = 349, '[16] REGRESIÓN: Recomendado 7 días ya no da $349 — revisar sql/612: ' || (v_rec3->>'amount');
    ASSERT (v_rec3->>'amount')::numeric > 299, '[16] REGRESIÓN: Recomendado ya no cuesta más que Destacado — revisar sql/612';
  END;

  -- ══ 17. admin_activate_bidding / admin_deactivate_group('bidding') — sql/613+614 ══
  DECLARE
    v_admin  UUID;
    v_g17    UUID;
    v_res17  JSONB;
    v_row17  RECORD;
  BEGIN
    SELECT id INTO v_admin FROM public.profiles WHERE role='admin' LIMIT 1;
    INSERT INTO public.groups (id, owner_id, name, genre, country_id, state)
      VALUES (gen_random_uuid(), v_owner, 'RT602 Bid17', 'Banda', v_country_mx, 'RT602 Estado17') RETURNING id INTO v_g17;

    RESET role;
    PERFORM set_config('request.jwt.claims', json_build_object('sub', v_admin::text, 'role','authenticated')::text, true);
    PERFORM set_config('role','authenticated', true);
    v_res17 := public.admin_activate_bidding(v_g17, 250, 15);
    RESET role;
    ASSERT (v_res17->>'ok')::boolean = true, '[17] REGRESIÓN: admin_activate_bidding volvió a tronar (¿falta user_id otra vez?) — revisar sql/613: ' || v_res17::text;

    SELECT bid_amount, bid_ends_at INTO v_row17 FROM public.groups WHERE id = v_g17;
    ASSERT v_row17.bid_amount = 250, '[17] REGRESIÓN: admin_activate_bidding ya no actualiza groups.bid_amount — revisar sql/613';
    ASSERT v_row17.bid_ends_at > NOW() + INTERVAL '14 days', '[17] REGRESIÓN: bid_ends_at mal calculado — revisar sql/613';

    RESET role;
    PERFORM set_config('request.jwt.claims', json_build_object('sub', v_admin::text, 'role','authenticated')::text, true);
    PERFORM set_config('role','authenticated', true);
    PERFORM public.admin_deactivate_group(v_g17, 'bidding');
    RESET role;

    SELECT bid_amount, bid_ends_at INTO v_row17 FROM public.groups WHERE id = v_g17;
    ASSERT v_row17.bid_amount = 0 AND v_row17.bid_ends_at IS NULL, '[17] REGRESIÓN: admin_deactivate_group ya no limpia groups.bid_amount/bid_ends_at — revisar sql/614';
  END;

  -- ══ 18. get_group_ranking_position por ESTADO — sql/615 ════════════
  DECLARE
    v_g18a UUID; v_g18b UUID;
    v_res18a JSONB; v_res18b JSONB;
  BEGIN
    INSERT INTO public.groups (id, owner_id, name, genre, country_id, state, city, bid_amount, bid_ends_at, is_active)
      VALUES (gen_random_uuid(), v_owner, 'RT602 RankA18', 'Banda', v_country_mx, 'RT602 EstadoRank18', 'CiudadA18', 300, NOW()+interval '10 days', true)
      RETURNING id INTO v_g18a;
    INSERT INTO public.groups (id, owner_id, name, genre, country_id, state, city, bid_amount, bid_ends_at, is_active)
      VALUES (gen_random_uuid(), v_owner, 'RT602 RankB18', 'Banda', v_country_mx, 'RT602 EstadoRank18', 'CiudadB18', 100, NOW()+interval '10 days', true)
      RETURNING id INTO v_g18b;

    v_res18a := public.get_group_ranking_position(v_g18a, 'CiudadA18');
    v_res18b := public.get_group_ranking_position(v_g18b, 'CiudadB18');

    ASSERT (v_res18a->>'position')::int = 1, '[18] REGRESIÓN: el de mayor puja no salió #1 — revisar sql/615: ' || v_res18a::text;
    ASSERT (v_res18b->>'position')::int = 2, '[18] REGRESIÓN: volvió a rankear por ciudad — un grupo de otra ciudad del mismo estado no compite — revisar sql/615: ' || v_res18b::text;
    ASSERT (v_res18a->>'total')::int = 2, '[18] REGRESIÓN: el total no cuenta a los de otras ciudades del mismo estado — revisar sql/615';
  END;

  -- ══ 19. confirm_gift_payment — TODOS los regalos abren GiftReveal — sql/616 ══
  DECLARE
    v_g19      UUID;
    v_fuego_id UUID;
    v_price19  NUMERIC;
    v_gift19   UUID;
    v_screen19 TEXT;
  BEGIN
    INSERT INTO public.groups (id, owner_id, name, genre, country_id, state)
      VALUES (gen_random_uuid(), v_owner, 'RT602 Gift19', 'Banda', v_country_mx, 'RT602 Estado19') RETURNING id INTO v_g19;
    SELECT id INTO v_fuego_id FROM public.gift_catalog WHERE name = 'Fuego';
    SELECT amount INTO v_price19 FROM public.gift_catalog_prices WHERE gift_id = v_fuego_id AND currency_code = 'MXN';

    INSERT INTO public.group_gifts (group_id, sender_id, gift_id, currency_code, amount, group_amount, platform_amount, payment_provider, status)
      VALUES (v_g19, v_client, v_fuego_id, 'MXN', v_price19, v_price19 * 0.85, v_price19 * 0.15, 'conekta', 'pending')
      RETURNING id INTO v_gift19;

    PERFORM public.confirm_gift_payment(v_gift19, 'RT602_order19');

    SELECT data->>'screen' INTO v_screen19
    FROM notifications WHERE user_id = v_owner AND (data->>'gift_id')::uuid = v_gift19
    ORDER BY created_at DESC LIMIT 1;

    ASSERT v_screen19 = 'GiftReveal', '[19] REGRESIÓN: un regalo de catálogo fijo (Fuego) ya no abre GiftReveal — revisar sql/616: screen=' || COALESCE(v_screen19, 'NULL');
  END;

  -- ══ 20. confirm_gift_payment — notif admin dice "Regalo sorpresa", no "Trofeo" — sql/617 ══
  DECLARE
    v_g20       UUID;
    v_trofeo_id UUID;
    v_price20   NUMERIC;
    v_gift20    UUID;
    v_admin20   UUID;
    v_body20    TEXT;
  BEGIN
    INSERT INTO public.groups (id, owner_id, name, genre, country_id, state)
      VALUES (gen_random_uuid(), v_owner, 'RT602 Gift20', 'Banda', v_country_mx, 'RT602 Estado20') RETURNING id INTO v_g20;
    SELECT id INTO v_trofeo_id FROM public.gift_catalog WHERE name = 'Trofeo';
    SELECT amount INTO v_price20 FROM public.gift_catalog_prices WHERE gift_id = v_trofeo_id AND currency_code = 'MXN';
    v_admin20 := (SELECT id FROM public.profiles WHERE role='admin' LIMIT 1);

    -- El doble del precio de catálogo = "Otro monto" (custom), aunque el
    -- gift_id sea el mismo de Trofeo (mismo criterio que la app real).
    INSERT INTO public.group_gifts (group_id, sender_id, gift_id, currency_code, amount, group_amount, platform_amount, payment_provider, status)
      VALUES (v_g20, v_client, v_trofeo_id, 'MXN', v_price20 * 2, v_price20 * 2 * 0.85, v_price20 * 2 * 0.15, 'conekta', 'pending')
      RETURNING id INTO v_gift20;

    PERFORM public.confirm_gift_payment(v_gift20, 'RT602_order20');

    SELECT body INTO v_body20
    FROM notifications WHERE user_id = v_admin20 AND (data->>'gift_id')::uuid = v_gift20
    ORDER BY created_at DESC LIMIT 1;

    ASSERT v_body20 ILIKE '%Regalo sorpresa%', '[20] REGRESIÓN: la notificación de admin ya no dice "Regalo sorpresa" — revisar sql/617: body=' || COALESCE(v_body20, 'NULL');
    ASSERT v_body20 NOT ILIKE '%Trofeo%', '[20] REGRESIÓN: la notificación de admin volvió a decir "Trofeo" para un monto personalizado — revisar sql/617: body=' || COALESCE(v_body20, 'NULL');
  END;

  -- ══ 21. groups.show_gifts_to_members — default + RLS para el talento — sql/618 ══
  DECLARE
    v_g21     UUID;
    v_default BOOLEAN;
    v_seen    BOOLEAN;
  BEGIN
    INSERT INTO public.groups (id, owner_id, name, genre, country_id)
      VALUES (gen_random_uuid(), v_owner, 'RT602 Gift21', 'Banda', v_country_mx)
      RETURNING id, show_gifts_to_members INTO v_g21, v_default;
    ASSERT v_default = false, '[21] REGRESIÓN: show_gifts_to_members ya no nace en false — revisar sql/618';

    INSERT INTO public.job_invitations (id, group_id, invited_user_id, status, invitation_type)
      VALUES (gen_random_uuid(), v_g21, v_talent, 'accepted', 'membership');
    UPDATE public.groups SET show_gifts_to_members = true WHERE id = v_g21;

    RESET role;
    PERFORM set_config('request.jwt.claims', json_build_object('sub', v_talent::text, 'role','authenticated')::text, true);
    PERFORM set_config('role','authenticated', true);
    SELECT show_gifts_to_members INTO v_seen FROM public.groups WHERE id = v_g21;
    RESET role;
    ASSERT v_seen = true, '[21] REGRESIÓN: el talento integrante ya no puede leer show_gifts_to_members (RLS) — revisar sql/618';
  END;

  -- ══ 22. delete_group_invitation — notifica al integrante removido — sql/619 ══
  DECLARE
    v_g22    UUID;
    v_inv22  UUID;
  BEGIN
    INSERT INTO public.groups (id, owner_id, name, genre, country_id)
      VALUES (gen_random_uuid(), v_owner, 'RT602 Gift22', 'Banda', v_country_mx) RETURNING id INTO v_g22;
    INSERT INTO public.job_invitations (id, group_id, invited_user_id, status, invitation_type)
      VALUES (gen_random_uuid(), v_g22, v_talent, 'accepted', 'membership') RETURNING id INTO v_inv22;

    RESET role;
    PERFORM set_config('request.jwt.claims', json_build_object('sub', v_owner::text, 'role','authenticated')::text, true);
    PERFORM set_config('role','authenticated', true);
    PERFORM public.delete_group_invitation(v_inv22);
    RESET role;

    ASSERT EXISTS(SELECT 1 FROM notifications WHERE user_id = v_talent AND title = '⚠️ Te sacaron de un grupo' AND created_at > NOW() - INTERVAL '1 minute'),
      '[22] REGRESIÓN: al remover a un integrante ya no se le notifica — revisar sql/619';
  END;

  -- ══ 23. trg_notify_gift_visibility_off — avisa a integrantes al desactivar — sql/620 ══
  DECLARE
    v_g23   UUID;
    v_cnt23 INT;
  BEGIN
    INSERT INTO public.groups (id, owner_id, name, genre, country_id, show_gifts_to_members)
      VALUES (gen_random_uuid(), v_owner, 'RT602 Gift23', 'Banda', v_country_mx, true) RETURNING id INTO v_g23;
    INSERT INTO public.job_invitations (id, group_id, invited_user_id, status, invitation_type)
      VALUES (gen_random_uuid(), v_g23, v_talent, 'accepted', 'membership');

    UPDATE public.groups SET show_gifts_to_members = false WHERE id = v_g23;
    ASSERT EXISTS(SELECT 1 FROM notifications WHERE user_id = v_talent AND title ILIKE '%Ya no puedes ver los regalos%' AND created_at > NOW() - INTERVAL '1 minute'),
      '[23] REGRESIÓN: al desactivar el interruptor con integrante activo ya no se notifica — revisar sql/620';

    SELECT count(*) INTO v_cnt23 FROM notifications WHERE user_id = v_talent AND title ILIKE '%Ya no puedes ver los regalos%';
    UPDATE public.groups SET show_gifts_to_members = false WHERE id = v_g23; -- ya estaba false
    ASSERT (SELECT count(*) FROM notifications WHERE user_id = v_talent AND title ILIKE '%Ya no puedes ver los regalos%') = v_cnt23,
      '[23] REGRESIÓN: el trigger disparó de nuevo con false->false (sin cambio real) — revisar sql/620';
  END;

  -- ══ 24. event_break_boundaries — matemática exacta, tipo A, 4h + 1 extra ══
  -- (debe coincidir siempre con generateBreakSchedule en calculations.ts)
  DECLARE
    v_anchor24  TIMESTAMPTZ := '2030-01-01 00:00:00+00';
    v_rows24    RECORD;
    v_offsets24 INT[] := '{}';
  BEGIN
    FOR v_rows24 IN
      SELECT break_index, break_start, break_end FROM event_break_boundaries(v_anchor24, 4, 'A', 1) ORDER BY break_index
    LOOP
      v_offsets24 := v_offsets24 || EXTRACT(EPOCH FROM (v_rows24.break_start - v_anchor24))::int / 60;
      v_offsets24 := v_offsets24 || EXTRACT(EPOCH FROM (v_rows24.break_end   - v_anchor24))::int / 60;
    END LOOP;
    ASSERT v_offsets24 = ARRAY[45,60,105,120,165,180,225,240],
      '[24] REGRESIÓN: event_break_boundaries tipo A cambió su matemática (desincroniza el timer del grupo vs las notificaciones del servidor): ' || v_offsets24::text;
  END;

  -- ══ 25. complete_event — candado de duración mínima + idempotencia — protege el fin de evento ══
  DECLARE
    v_g25 UUID; v_res25 UUID; v_result25 JSONB; v_status25 TEXT;
  BEGIN
    -- Fecha propia y única (+90) para no chocar con enforce_max_groups_per_event
    -- (máx. 3 grupos por evento/fecha del mismo cliente) frente a las demás
    -- reservas de v_client ya creadas más arriba en esta misma suite.
    INSERT INTO public.groups (id, owner_id, name, genre, country_id) VALUES (gen_random_uuid(), v_owner, 'RT602 Timer25', 'Banda', v_country_mx) RETURNING id INTO v_g25;
    INSERT INTO public.reservations (id, client_id, group_id, event_date, event_time, address, total_price, status, hours_count, event_started_at)
      VALUES (gen_random_uuid(), v_client, v_g25, CURRENT_DATE + 90, '18:00', 'Dir', 9000, 'in_progress', 3, NOW() - INTERVAL '30 minutes')
      RETURNING id INTO v_res25;

    RESET role;
    PERFORM set_config('request.jwt.claims', json_build_object('sub', v_owner::text, 'role','authenticated')::text, true);
    PERFORM set_config('role','authenticated', true);
    v_result25 := public.complete_event(v_res25);
    RESET role;
    ASSERT (v_result25->>'ok')::boolean = false, '[25] REGRESIÓN: complete_event dejó terminar un evento que apenas lleva 30 min de 3h contratadas';

    UPDATE public.reservations SET event_started_at = NOW() - INTERVAL '200 minutes' WHERE id = v_res25;
    RESET role;
    PERFORM set_config('request.jwt.claims', json_build_object('sub', v_owner::text, 'role','authenticated')::text, true);
    PERFORM set_config('role','authenticated', true);
    v_result25 := public.complete_event(v_res25);
    RESET role;
    ASSERT (v_result25->>'ok')::boolean = true, '[25] REGRESIÓN: complete_event no dejó terminar un evento que ya cumplió su tiempo: ' || v_result25::text;
    SELECT status INTO v_status25 FROM public.reservations WHERE id = v_res25;
    ASSERT v_status25 = 'completed', '[25] REGRESIÓN: complete_event no marcó status=completed';

    RESET role;
    PERFORM set_config('request.jwt.claims', json_build_object('sub', v_owner::text, 'role','authenticated')::text, true);
    PERFORM set_config('role','authenticated', true);
    v_result25 := public.complete_event(v_res25);
    RESET role;
    ASSERT (v_result25->>'note') = 'already_completed', '[25] REGRESIÓN: complete_event ya no es idempotente en un evento ya finalizado';
  END;

  -- ══ 26. auto_finalize_stuck_events — sql/621 (columna event_request_id
  -- inexistente en job_invitations tronaba la función CADA VEZ que de
  -- verdad intentaba cerrar un evento atorado — nunca se había cerrado uno
  -- por esta vía). No debe tocar eventos aún en su ventana de gracia, sí
  -- debe cerrar los realmente atorados con notificación, y no duplicar. ══
  DECLARE
    v_g26a UUID; v_g26b UUID; v_res26 UUID; v_res26b UUID; v_status26 TEXT;
  BEGIN
    -- Fechas propias y únicas (+91/+92) — mismo motivo que en [25]
    INSERT INTO public.groups (id, owner_id, name, genre, country_id) VALUES (gen_random_uuid(), v_owner, 'RT602 Timer26a', 'Banda', v_country_mx) RETURNING id INTO v_g26a;
    INSERT INTO public.reservations (id, client_id, group_id, event_date, event_time, address, total_price, status, hours_count, event_started_at)
      VALUES (gen_random_uuid(), v_client, v_g26a, CURRENT_DATE + 91, '18:00', 'Dir', 3000, 'in_progress', 1, NOW() - INTERVAL '2 hours')
      RETURNING id INTO v_res26;

    INSERT INTO public.groups (id, owner_id, name, genre, country_id) VALUES (gen_random_uuid(), v_owner, 'RT602 Timer26b', 'Banda', v_country_mx) RETURNING id INTO v_g26b;
    INSERT INTO public.reservations (id, client_id, group_id, event_date, event_time, address, total_price, status, hours_count, event_started_at)
      VALUES (gen_random_uuid(), v_client, v_g26b, CURRENT_DATE + 92, '18:00', 'Dir', 3000, 'in_progress', 1, NOW() - INTERVAL '5 hours')
      RETURNING id INTO v_res26b;

    PERFORM public.auto_finalize_stuck_events();

    SELECT status INTO v_status26 FROM public.reservations WHERE id = v_res26;
    ASSERT v_status26 = 'in_progress', '[26] REGRESIÓN: auto_finalize_stuck_events cerró un evento TODAVÍA en su ventana de gracia — riesgo de cortar un evento real en vivo — revisar sql/621';

    SELECT status INTO v_status26 FROM public.reservations WHERE id = v_res26b;
    ASSERT v_status26 = 'completed', '[26] REGRESIÓN: auto_finalize_stuck_events volvió a no cerrar un evento realmente atorado (¿volvió el bug de event_request_id?) — revisar sql/621';

    ASSERT EXISTS(SELECT 1 FROM notifications WHERE type='event_finalized' AND user_id=v_client AND data->>'reservation_id'=v_res26b::text),
      '[26] REGRESIÓN: no se notificó al cliente al cerrar el evento atorado';
    ASSERT EXISTS(SELECT 1 FROM notifications WHERE type='event_finalized' AND data->>'reservation_id'=v_res26b::text AND user_id = v_owner),
      '[26] REGRESIÓN: no se notificó al dueño del grupo al cerrar el evento atorado';

    PERFORM public.auto_finalize_stuck_events();
    ASSERT (SELECT count(*) FROM notifications WHERE type='event_finalized' AND user_id=v_client AND data->>'reservation_id'=v_res26b::text) = 1,
      '[26] REGRESIÓN: auto_finalize_stuck_events duplicó la notificación en una segunda corrida';
  END;

  -- ══ 27. group_default_break_type — Espectáculo/MC — sql/622 ════════════
  DECLARE
    v_g27a UUID; v_g27b UUID;
  BEGIN
    INSERT INTO public.groups (id, owner_id, name, genre, country_id) VALUES (gen_random_uuid(), v_owner, 'RT602 MC27', 'Maestro de Ceremonias', v_country_mx) RETURNING id INTO v_g27a;
    INSERT INTO public.groups (id, owner_id, name, genre, country_id) VALUES (gen_random_uuid(), v_owner, 'RT602 Show27', 'Espectáculo', v_country_mx) RETURNING id INTO v_g27b;
    ASSERT public.group_default_break_type(v_g27a) = 'D', '[27] REGRESIÓN: Maestro de Ceremonias ya no es sin-temporizador (D) — revisar sql/622';
    ASSERT public.group_default_break_type(v_g27b) IS NULL, '[27] REGRESIÓN: Espectáculo ya no deja elegir tipo de descanso (debería ser NULL) — revisar sql/622';
  END;

  -- ══ 28. category_details jsonb — round-trip en groups y quotes — sql/623 ══
  -- Comida/Renta/Payasos/Fotógrafos guardan sus propias preguntas (nada que
  -- ver con sonido/tarima/LED) en esta columna nueva. Debe: (a) guardarse y
  -- leerse tal cual en AMBAS tablas, (b) una fila vieja sin el campo debe
  -- traer default '{}' y no romper nada aguas abajo.
  DECLARE
    v_g28 UUID; v_q28 UUID;
    v_group_details JSONB := '{"service_type": "buffet", "dietary_notes": "sin nueces"}'::jsonb;
    v_quote_details JSONB := '{"items_needed": ["mesas", "sillas"], "logistics_notes": "acceso por atrás"}'::jsonb;
    v_read_back JSONB;
  BEGIN
    INSERT INTO public.groups (id, owner_id, name, genre, country_id, category_details)
      VALUES (gen_random_uuid(), v_owner, 'RT602 Comida28', 'Comida', v_country_mx, v_group_details)
      RETURNING id INTO v_g28;
    SELECT category_details INTO v_read_back FROM public.groups WHERE id = v_g28;
    ASSERT v_read_back = v_group_details, '[28] REGRESIÓN: category_details de groups no guardó/leyó tal cual — revisar sql/623';

    INSERT INTO public.quotes (id, group_id, client_id, event_date, event_time, duration_hours, status,
      event_type, event_address, event_municipio, event_estado, venue_covered, venue_size, needs_sound,
      base_price, commission_amount, total_amount, group_earnings, category_details)
      VALUES (gen_random_uuid(), v_g28, v_client, CURRENT_DATE + 93, '18:00', 3, 'pending',
        'boda', 'Dir', 'Muni', 'Edo', 'si', 'salon_mediano', 'no_group_brings', 300, 60, 360, 300, v_quote_details)
      RETURNING id INTO v_q28;
    SELECT category_details INTO v_read_back FROM public.quotes WHERE id = v_q28;
    ASSERT v_read_back = v_quote_details, '[28] REGRESIÓN: category_details de quotes no guardó/leyó tal cual — revisar sql/623';

    -- Fila SIN category_details (comportamiento de siempre, ej. Banda) —
    -- debe traer default '{}', nunca NULL, y no romper nada.
    INSERT INTO public.groups (id, owner_id, name, genre, country_id)
      VALUES (gen_random_uuid(), v_owner, 'RT602 Banda28', 'Banda', v_country_mx) RETURNING id INTO v_g28;
    SELECT category_details INTO v_read_back FROM public.groups WHERE id = v_g28;
    ASSERT v_read_back = '{}'::jsonb, '[28] REGRESIÓN: category_details de groups ya no nace en {} por default — revisar sql/623';
  END;

  -- ══ 29. get_category_field_values — lista que crece sola — sql/624 ══
  -- Dos grupos de Comida con service_type distinto (uno de catálogo fijo,
  -- otro texto libre que un proveedor escribió a mano) y uno de Renta con
  -- un multiChips — debe regresar la UNIÓN correcta sin duplicados, y
  -- nunca mezclar categorías (Comida no debe ver valores de Renta).
  DECLARE
    v_g29a UUID; v_g29b UUID; v_g29c UUID;
    v_vals29 TEXT[];
  BEGIN
    INSERT INTO public.groups (id, owner_id, name, genre, country_id, category_details)
      VALUES (gen_random_uuid(), v_owner, 'RT602 Comida29a', 'Comida', v_country_mx, '{"service_type":"buffet"}'::jsonb)
      RETURNING id INTO v_g29a;
    INSERT INTO public.groups (id, owner_id, name, genre, country_id, category_details)
      VALUES (gen_random_uuid(), v_owner, 'RT602 Comida29b', 'Comida', v_country_mx, '{"service_type":"Rosticería"}'::jsonb)
      RETURNING id INTO v_g29b;
    -- Mismo valor "buffet" repetido — no debe duplicarse en el resultado
    INSERT INTO public.groups (id, owner_id, name, genre, country_id, category_details)
      VALUES (gen_random_uuid(), v_owner, 'RT602 Comida29c', 'Comida', v_country_mx, '{"service_type":"buffet"}'::jsonb)
      RETURNING id INTO v_g29c;

    SELECT array_agg(value ORDER BY value) INTO v_vals29 FROM public.get_category_field_values('comida', 'service_type');
    ASSERT v_vals29 @> ARRAY['buffet', 'Rosticería'], '[29] REGRESIÓN: get_category_field_values no trae los valores de service_type (chips) — revisar sql/624: ' || array_to_string(v_vals29, ',');
    ASSERT (SELECT count(*) FROM unnest(v_vals29) x WHERE x = 'buffet') = 1,
      '[29] REGRESIÓN: get_category_field_values duplicó "buffet" en vez de deduplicar — revisar sql/624';

    -- multiChips (Renta) — usa el grupo real "TEST — Renta de Mobiliario"
    -- si existe, o crea uno propio para no depender de datos de prueba externos.
    INSERT INTO public.groups (id, owner_id, name, genre, country_id, category_details)
      VALUES (gen_random_uuid(), v_owner, 'RT602 Renta29', 'Renta de mesas', v_country_mx,
        '{"items_needed":["mesas","brincolines"]}'::jsonb);
    SELECT array_agg(value ORDER BY value) INTO v_vals29 FROM public.get_category_field_values('renta', 'items_needed');
    ASSERT v_vals29 @> ARRAY['brincolines', 'mesas'], '[29] REGRESIÓN: get_category_field_values no trae los valores de items_needed (multiChips) — revisar sql/624: ' || array_to_string(v_vals29, ',');

    -- Aislamiento entre categorías — Renta no debe "contaminar" Comida
    SELECT array_agg(value) INTO v_vals29 FROM public.get_category_field_values('comida', 'service_type');
    ASSERT NOT (v_vals29 @> ARRAY['mesas']), '[29] REGRESIÓN: get_category_field_values mezcló valores de Renta dentro de Comida — revisar group_category_key en sql/624';
  END;

  -- ══ 30. group_category_key — Shows (Espectáculo+Payasos+Mago+Personajes+
  -- Animación) y Maestro de Ceremonias — sql/625 ══════════════════════════
  -- Hallazgo real corrigiendo esta misma función: nunca se había agregado
  -- Espectáculo ni Maestro de Ceremonias desde que existen (sql/622) —
  -- devolvía NULL para ambos. Se corrige aquí y se bloquea que regrese.
  DECLARE
    v_g30a UUID; v_g30b UUID; v_g30c UUID; v_g30d UUID; v_g30e UUID; v_g30f UUID;
  BEGIN
    INSERT INTO public.groups (id, owner_id, name, genre, country_id) VALUES (gen_random_uuid(), v_owner, 'RT602 Show30a', 'Espectáculo', v_country_mx) RETURNING id INTO v_g30a;
    INSERT INTO public.groups (id, owner_id, name, genre, country_id) VALUES (gen_random_uuid(), v_owner, 'RT602 Show30b', 'Payasos', v_country_mx) RETURNING id INTO v_g30b;
    INSERT INTO public.groups (id, owner_id, name, genre, country_id) VALUES (gen_random_uuid(), v_owner, 'RT602 Show30c', 'Mago', v_country_mx) RETURNING id INTO v_g30c;
    INSERT INTO public.groups (id, owner_id, name, genre, country_id) VALUES (gen_random_uuid(), v_owner, 'RT602 Show30d', 'Personajes', v_country_mx) RETURNING id INTO v_g30d;
    INSERT INTO public.groups (id, owner_id, name, genre, country_id) VALUES (gen_random_uuid(), v_owner, 'RT602 Show30e', 'Animación', v_country_mx) RETURNING id INTO v_g30e;
    INSERT INTO public.groups (id, owner_id, name, genre, country_id) VALUES (gen_random_uuid(), v_owner, 'RT602 MC30f', 'Maestro de Ceremonias', v_country_mx) RETURNING id INTO v_g30f;

    ASSERT public.group_category_key(v_g30a) = 'espectaculo', '[30] REGRESIÓN: Espectáculo ya no clasifica como espectaculo — revisar sql/625';
    ASSERT public.group_category_key(v_g30b) = 'espectaculo', '[30] REGRESIÓN: Payasos ya no clasifica dentro de Shows — revisar sql/625';
    ASSERT public.group_category_key(v_g30c) = 'espectaculo', '[30] REGRESIÓN: Mago ya no clasifica dentro de Shows — revisar sql/625';
    ASSERT public.group_category_key(v_g30d) = 'espectaculo', '[30] REGRESIÓN: Personajes ya no clasifica dentro de Shows — revisar sql/625';
    ASSERT public.group_category_key(v_g30e) = 'espectaculo', '[30] REGRESIÓN: Animación ya no clasifica dentro de Shows — revisar sql/625';
    ASSERT public.group_category_key(v_g30f) = 'mc', '[30] REGRESIÓN: Maestro de Ceremonias ya no clasifica como mc — revisar sql/625';
  END;

  -- ══ 31. send_event_reminders_2h honra event_tz (no siempre MX) — sql/643 ══
  DECLARE
    v_g31       UUID;
    v_res31     UUID;
    v_country_us31 UUID;
    v_event_time_ny TEXT;
  BEGIN
    SELECT id INTO v_country_us31 FROM public.countries WHERE currency_code='USD' LIMIT 1;

    INSERT INTO public.groups (id, owner_id, name, genre, country_id, state, country)
      VALUES (gen_random_uuid(), v_owner, 'RT602 NY31', 'Banda', v_country_us31, 'New York', 'Estados Unidos')
      RETURNING id INTO v_g31;

    -- Hora local en Nueva York que corresponde a "ahora + 2 horas" AHÍ MISMO
    v_event_time_ny := to_char((NOW() AT TIME ZONE 'America/New_York') + INTERVAL '2 hours', 'HH24:MI');

    INSERT INTO public.reservations
      (id, client_id, group_id, event_date, event_time, address, total_price, status, hours_count)
    VALUES
      (gen_random_uuid(), v_client, v_g31,
       ((NOW() AT TIME ZONE 'America/New_York') + INTERVAL '2 hours')::date,
       v_event_time_ny::time, 'Dir NY', 5000, 'confirmed', 3)
    RETURNING id INTO v_res31;

    ASSERT (SELECT event_tz FROM public.reservations WHERE id = v_res31) = 'America/New_York',
      '[31] REGRESIÓN: event_tz ya no se autopobla como America/New_York para un grupo de Nueva York — revisar sql/514 (tz_for_event / trg_01_set_busy_range)';

    PERFORM public.send_event_reminders_2h();

    ASSERT EXISTS(
      SELECT 1 FROM notifications WHERE data->>'reservation_id' = v_res31::text AND type='event_reminder_2h'
    ), '[31] REGRESIÓN: send_event_reminders_2h volvió a asumir America/Mexico_City para un evento de Nueva York — revisar sql/643';
  END;

  -- ══ 32. notify_quote_request — grupo normal sigue notificando al dueño igual que siempre — sql/648 ══
  DECLARE
    v_g32 UUID;
    v_q32 UUID;
  BEGIN
    INSERT INTO public.groups (id, owner_id, name, genre, country_id, concierge_mode)
      VALUES (gen_random_uuid(), v_owner, 'RT602 Normal32', 'Banda', v_country_mx, false)
      RETURNING id INTO v_g32;

    INSERT INTO public.quotes
      (id, group_id, client_id, event_type, event_address, event_municipio, event_estado,
       event_date, event_time, duration_hours, venue_covered, venue_size, needs_sound)
    VALUES
      (gen_random_uuid(), v_g32, v_client, 'boda', 'Dir32', 'Municipio32', 'Estado32',
       CURRENT_DATE + 10, '19:00', 4, 'si', 'salon_mediano', 'no_group_brings')
    RETURNING id INTO v_q32;

    RESET role;
    PERFORM set_config('request.jwt.claims', json_build_object('sub', v_client::text, 'role','authenticated')::text, true);
    PERFORM set_config('role','authenticated', true);
    PERFORM public.notify_quote_request(v_q32);
    RESET role;

    ASSERT EXISTS(
      SELECT 1 FROM notifications WHERE user_id = v_owner AND type='new_quote_request' AND data->>'quote_id' = v_q32::text
    ), '[32] REGRESIÓN: notify_quote_request ya no notifica al dueño de un grupo normal — revisar sql/648';

    ASSERT NOT EXISTS(
      SELECT 1 FROM notifications n JOIN public.profiles p ON p.id = n.user_id
      WHERE p.role IN ('admin','admin_ops') AND n.data->>'quote_id' = v_q32::text
    ), '[32] REGRESIÓN: una cotización de un grupo normal le está llegando al admin/admin_ops sin necesidad — revisar sql/648';
  END;

  -- ══ 33. notify_quote_request + admin_respond_quote — grupo en modo conserjería (EE.UU.) — sql/648 ══
  DECLARE
    v_admin33      UUID;
    v_adminops33   UUID;
    v_g33          UUID;
    v_q33          UUID;
    v_q33b         UUID;
    v_resp33       JSONB;
    v_muted_before TEXT[];
  BEGIN
    SELECT id INTO v_admin33 FROM public.profiles WHERE role='admin' LIMIT 1;
    SELECT id INTO v_adminops33 FROM public.profiles WHERE role='admin_ops' AND admin_country_scope='US' LIMIT 1;
    SELECT admin_muted_countries INTO v_muted_before FROM public.profiles WHERE id = v_admin33;

    -- Caso A: admin completo SIN mutear Estados Unidos — debe verla igual que admin_ops
    UPDATE public.profiles SET admin_muted_countries = '{}' WHERE id = v_admin33;

    INSERT INTO public.groups (id, owner_id, name, genre, country_id, country, state, concierge_mode)
      VALUES (gen_random_uuid(), v_owner2, 'RT602 Conserje33', 'Banda', v_country_us, 'Estados Unidos', 'New York', true)
      RETURNING id INTO v_g33;

    INSERT INTO public.quotes
      (id, group_id, client_id, event_type, event_address, event_municipio, event_estado,
       event_date, event_time, duration_hours, venue_covered, venue_size, needs_sound)
    VALUES
      (gen_random_uuid(), v_g33, v_client, 'boda', 'Dir33', 'CiudadNY33', 'New York',
       CURRENT_DATE + 10, '19:00', 4, 'si', 'salon_mediano', 'no_group_brings')
    RETURNING id INTO v_q33;

    RESET role;
    PERFORM set_config('request.jwt.claims', json_build_object('sub', v_client::text, 'role','authenticated')::text, true);
    PERFORM set_config('role','authenticated', true);
    PERFORM public.notify_quote_request(v_q33);
    RESET role;

    ASSERT NOT EXISTS(
      SELECT 1 FROM notifications WHERE user_id = v_owner2 AND data->>'quote_id' = v_q33::text
    ), '[33] REGRESIÓN: un grupo en modo conserjería SÍ le notificó al dueño — se supone que debe pasar por el admin — revisar sql/648';

    ASSERT EXISTS(
      SELECT 1 FROM notifications WHERE user_id = v_admin33 AND type='new_quote_request' AND data->>'quote_id' = v_q33::text
    ), '[33] REGRESIÓN: el admin completo (sin mutear EE.UU.) no recibió el aviso de cotización para llamar — revisar sql/648';

    ASSERT EXISTS(
      SELECT 1 FROM notifications WHERE user_id = v_adminops33 AND type='new_quote_request' AND data->>'quote_id' = v_q33::text
    ), '[33] REGRESIÓN: el admin_ops de EE.UU. no recibió el aviso de cotización para llamar — revisar sql/648';

    -- Caso B: admin completo mutea Estados Unidos — deja de verla, admin_ops la sigue viendo
    UPDATE public.profiles SET admin_muted_countries = ARRAY['US'] WHERE id = v_admin33;

    INSERT INTO public.quotes
      (id, group_id, client_id, event_type, event_address, event_municipio, event_estado,
       event_date, event_time, duration_hours, venue_covered, venue_size, needs_sound)
    VALUES
      (gen_random_uuid(), v_g33, v_client, 'boda', 'Dir33b', 'CiudadNY33b', 'New York',
       CURRENT_DATE + 11, '19:00', 4, 'si', 'salon_mediano', 'no_group_brings')
    RETURNING id INTO v_q33b;

    RESET role;
    PERFORM set_config('request.jwt.claims', json_build_object('sub', v_client::text, 'role','authenticated')::text, true);
    PERFORM set_config('role','authenticated', true);
    PERFORM public.notify_quote_request(v_q33b);
    RESET role;

    ASSERT NOT EXISTS(
      SELECT 1 FROM notifications WHERE user_id = v_admin33 AND data->>'quote_id' = v_q33b::text
    ), '[33] REGRESIÓN: el admin completo ya había muteado Estados Unidos y aun así le llegó el aviso — revisar admin_is_country_muted en sql/648';

    ASSERT EXISTS(
      SELECT 1 FROM notifications WHERE user_id = v_adminops33 AND data->>'quote_id' = v_q33b::text
    ), '[33] REGRESIÓN: el admin_ops de EE.UU. dejó de ver la cotización solo porque el admin completo muteó su país — revisar sql/648';

    UPDATE public.profiles SET admin_muted_countries = v_muted_before WHERE id = v_admin33;

    -- Round-trip: admin_ops pone precio → el cliente recibe la cotización normal
    RESET role;
    PERFORM set_config('request.jwt.claims', json_build_object('sub', v_adminops33::text, 'role','authenticated')::text, true);
    PERFORM set_config('role','authenticated', true);
    v_resp33 := public.admin_respond_quote(v_q33, 8000, 500, 400, 750, 1100, 'Confirmó por teléfono');
    RESET role;

    ASSERT (v_resp33->>'ok')::boolean = true,
      '[33] REGRESIÓN: admin_respond_quote ya no deja responder a admin_ops sobre un grupo de su país en modo conserjería — revisar sql/648: ' || v_resp33::text;

    ASSERT EXISTS(
      SELECT 1 FROM public.quotes WHERE id = v_q33 AND status = 'quoted' AND base_price = 8000
    ), '[33] REGRESIÓN: admin_respond_quote no dejó guardado el precio/estatus de la cotización — revisar sql/648';

    -- El markup 20% debe aplicar sobre base+traslado combinados (8000+500=8500
    -- → total 10200), NO solo sobre base (bug real encontrado y corregido
    -- 2026-09-13: daba 10100, cobrándole de menos al cliente).
    ASSERT (v_resp33->>'total_amount')::numeric = 10200,
      '[33] REGRESIÓN: admin_respond_quote volvió a marcar el traslado sin comisión — revisar sql/648: total_amount=' || (v_resp33->>'total_amount');
    ASSERT EXISTS(
      SELECT 1 FROM public.quotes WHERE id = v_q33 AND commission_amount = 1700 AND group_earnings = 8500
    ), '[33] REGRESIÓN: commission_amount/group_earnings ya no reflejan base+traslado — revisar sql/648';

    -- Precios de horas extra (sql/653) — CADA bundle es independiente
    -- (1h=400, 2h=750 [con descuento, no 800], 3h=1100 [no 1200]) →
    -- 480/900/1320 con markup — mismos campos que lee ExtraHoursScreen
    -- (overtime_Xh_price), nunca un precio por hora multiplicado.
    ASSERT EXISTS(
      SELECT 1 FROM public.quotes WHERE id = v_q33
        AND overtime_1h_price = 480 AND overtime_2h_price = 900 AND overtime_3h_price = 1320
    ), '[33] REGRESIÓN: admin_respond_quote ya no calcula bien los paquetes de hora extra (con descuento por volumen) — revisar sql/653';

    ASSERT EXISTS(
      SELECT 1 FROM notifications WHERE user_id = v_client AND type='quote_received' AND data->>'quote_id' = v_q33::text
    ), '[33] REGRESIÓN: admin_respond_quote no le avisó al cliente que ya tiene precio — revisar sql/648';
  END;

  -- ══ 34. admin_respond_quote rechaza un grupo que NO está en modo conserjería — sql/648 ══
  DECLARE
    v_admin34 UUID;
    v_g34     UUID;
    v_q34     UUID;
    v_resp34  JSONB;
  BEGIN
    SELECT id INTO v_admin34 FROM public.profiles WHERE role='admin' LIMIT 1;

    INSERT INTO public.groups (id, owner_id, name, genre, country_id, concierge_mode)
      VALUES (gen_random_uuid(), v_owner, 'RT602 NoConserje34', 'Banda', v_country_mx, false)
      RETURNING id INTO v_g34;

    INSERT INTO public.quotes
      (id, group_id, client_id, event_type, event_address, event_municipio, event_estado,
       event_date, event_time, duration_hours, venue_covered, venue_size, needs_sound)
    VALUES
      (gen_random_uuid(), v_g34, v_client, 'boda', 'Dir34', 'Municipio34', 'Estado34',
       CURRENT_DATE + 10, '19:00', 4, 'si', 'salon_mediano', 'no_group_brings')
    RETURNING id INTO v_q34;

    RESET role;
    PERFORM set_config('request.jwt.claims', json_build_object('sub', v_admin34::text, 'role','authenticated')::text, true);
    PERFORM set_config('role','authenticated', true);
    v_resp34 := public.admin_respond_quote(v_q34, 8000, 0, NULL, NULL, NULL, NULL);
    RESET role;

    ASSERT (v_resp34->>'ok')::boolean = false AND v_resp34->>'error' = 'group_not_in_concierge_mode',
      '[34] REGRESIÓN: admin_respond_quote dejó poner precio a un grupo que NO está en modo conserjería — revisar sql/648: ' || v_resp34::text;

    ASSERT EXISTS(SELECT 1 FROM public.quotes WHERE id = v_q34 AND status = 'pending'),
      '[34] REGRESIÓN: admin_respond_quote modificó una cotización que debió rechazar — revisar sql/648';
  END;

  -- ══ 35. submit_provider_application (anon) — pending + notifica admin/admin_ops, categoría inválida se rechaza — sql/649 ══
  DECLARE
    v_admin35 UUID;
    v_resp35  JSONB;
    v_app35   UUID;
  BEGIN
    SELECT id INTO v_admin35 FROM public.profiles WHERE role='admin' LIMIT 1;
    UPDATE public.profiles SET admin_muted_countries = '{}' WHERE id = v_admin35;

    RESET role;
    PERFORM set_config('role','anon', true);
    v_resp35 := public.submit_provider_application('RT602 Solicitante35', '3311112222', 'grupo', 4, 2, 'México', 'Jalisco', 'Zapopan', 'nota de prueba');
    RESET role;
    ASSERT (v_resp35->>'ok')::boolean = true, '[35] REGRESIÓN: submit_provider_application falló para un caso válido — revisar sql/649: ' || v_resp35::text;
    v_app35 := (v_resp35->>'application_id')::uuid;

    ASSERT EXISTS(SELECT 1 FROM public.provider_applications WHERE id=v_app35 AND status='pending'),
      '[35] REGRESIÓN: la solicitud no quedó pending — revisar sql/649';
    ASSERT EXISTS(SELECT 1 FROM notifications WHERE user_id=v_admin35 AND type='provider_application' AND data->>'application_id'=v_app35::text),
      '[35] REGRESIÓN: no se notificó al admin de la nueva solicitud — revisar sql/649';

    RESET role;
    PERFORM set_config('role','anon', true);
    v_resp35 := public.submit_provider_application('RT602 Malo35', '3313334444', 'categoria_inexistente');
    RESET role;
    ASSERT (v_resp35->>'ok')::boolean = false AND v_resp35->>'error' = 'invalid_category',
      '[35] REGRESIÓN: submit_provider_application dejó pasar una categoría inválida — revisar sql/649: ' || v_resp35::text;
  END;

  -- ══ 36. admin_get_provider_applications — aislamiento por país (admin_ops de EE.UU. no ve una solicitud de México) — sql/649 ══
  DECLARE
    v_adminops36 UUID;
    v_resp36     JSONB;
    v_resp36b    JSONB;
    v_app36      UUID;
  BEGIN
    SELECT id INTO v_adminops36 FROM public.profiles WHERE role='admin_ops' AND admin_country_scope='US' LIMIT 1;

    RESET role;
    PERFORM set_config('role','anon', true);
    v_resp36 := public.submit_provider_application('RT602 SoloMX36', '3315556666', 'dj', NULL, NULL, 'México', NULL, NULL, NULL);
    RESET role;
    v_app36 := (v_resp36->>'application_id')::uuid;

    RESET role;
    PERFORM set_config('request.jwt.claims', json_build_object('sub', v_adminops36::text, 'role','authenticated')::text, true);
    PERFORM set_config('role','authenticated', true);
    v_resp36b := public.admin_get_provider_applications('pending');
    RESET role;

    ASSERT NOT EXISTS(SELECT 1 FROM jsonb_array_elements(v_resp36b->'items') i WHERE (i->>'id')::uuid = v_app36),
      '[36] REGRESIÓN: el admin_ops de EE.UU. vio una solicitud de México — revisar sql/649';
  END;

  -- ══ 37. admin_approve_provider_application — crea auth.users+profiles+groups (concierge_mode=true), bloquea doble aprobación — sql/649 ══
  DECLARE
    v_admin37 UUID;
    v_resp37  JSONB;
    v_app37   UUID;
    v_user37  UUID;
    v_group37 UUID;
  BEGIN
    SELECT id INTO v_admin37 FROM public.profiles WHERE role='admin' LIMIT 1;

    RESET role;
    PERFORM set_config('role','anon', true);
    v_resp37 := public.submit_provider_application('RT602 Aprobar37', '3317778888', 'dj');
    RESET role;
    v_app37 := (v_resp37->>'application_id')::uuid;

    RESET role;
    PERFORM set_config('request.jwt.claims', json_build_object('sub', v_admin37::text, 'role','authenticated')::text, true);
    PERFORM set_config('role','authenticated', true);
    v_resp37 := public.admin_approve_provider_application(v_app37, 'rt602_37@example.com', 'DJ', 'clave_rt602');
    RESET role;
    ASSERT (v_resp37->>'ok')::boolean = true, '[37] REGRESIÓN: admin_approve_provider_application falló — revisar sql/649: ' || v_resp37::text;
    v_user37  := (v_resp37->>'user_id')::uuid;
    v_group37 := (v_resp37->>'group_id')::uuid;

    ASSERT EXISTS(SELECT 1 FROM auth.users WHERE id=v_user37 AND email='rt602_37@example.com'),
      '[37] REGRESIÓN: no se creó la cuenta real en auth.users — revisar sql/649';
    ASSERT EXISTS(SELECT 1 FROM public.profiles WHERE id=v_user37 AND role='group' AND full_name='RT602 Aprobar37'),
      '[37] REGRESIÓN: profiles no quedó con los datos de la solicitud — revisar sql/649';
    ASSERT EXISTS(SELECT 1 FROM public.groups WHERE id=v_group37 AND genre='DJ' AND concierge_mode=true AND owner_id=v_user37),
      '[37] REGRESIÓN: el grupo no nació en modo conserjería (o el dueño/género quedó mal) — revisar sql/649';
    ASSERT EXISTS(SELECT 1 FROM public.provider_applications WHERE id=v_app37 AND status='approved' AND linked_group_id=v_group37),
      '[37] REGRESIÓN: la solicitud no quedó approved con su linked_group_id — revisar sql/649';

    RESET role;
    PERFORM set_config('request.jwt.claims', json_build_object('sub', v_admin37::text, 'role','authenticated')::text, true);
    PERFORM set_config('role','authenticated', true);
    v_resp37 := public.admin_approve_provider_application(v_app37, 'otro_rt602_37@example.com', 'Banda', NULL);
    RESET role;
    ASSERT (v_resp37->>'ok')::boolean = false AND v_resp37->>'error' = 'already_approved',
      '[37] REGRESIÓN: dejó re-aprobar una solicitud ya aprobada (riesgo: crearía una 2a cuenta) — revisar sql/649';
  END;

  -- ══ 38. admin_reject_provider_application — marca rechazada con motivo, bloquea re-procesar — sql/649 ══
  DECLARE
    v_admin38 UUID;
    v_resp38  JSONB;
    v_app38   UUID;
  BEGIN
    SELECT id INTO v_admin38 FROM public.profiles WHERE role='admin' LIMIT 1;

    RESET role;
    PERFORM set_config('role','anon', true);
    v_resp38 := public.submit_provider_application('RT602 Rechazar38', '3319990000', 'comida');
    RESET role;
    v_app38 := (v_resp38->>'application_id')::uuid;

    RESET role;
    PERFORM set_config('request.jwt.claims', json_build_object('sub', v_admin38::text, 'role','authenticated')::text, true);
    PERFORM set_config('role','authenticated', true);
    v_resp38 := public.admin_reject_provider_application(v_app38, 'RT602 motivo de prueba');
    RESET role;
    ASSERT (v_resp38->>'ok')::boolean = true, '[38] REGRESIÓN: admin_reject_provider_application falló — revisar sql/649: ' || v_resp38::text;
    ASSERT EXISTS(SELECT 1 FROM public.provider_applications WHERE id=v_app38 AND status='rejected' AND admin_notes='RT602 motivo de prueba'),
      '[38] REGRESIÓN: el rechazo no quedó guardado con su motivo — revisar sql/649';

    RESET role;
    PERFORM set_config('request.jwt.claims', json_build_object('sub', v_admin38::text, 'role','authenticated')::text, true);
    PERFORM set_config('role','authenticated', true);
    v_resp38 := public.admin_reject_provider_application(v_app38, 'segundo intento');
    RESET role;
    ASSERT (v_resp38->>'ok')::boolean = false AND v_resp38->>'error' = 'already_resolved',
      '[38] REGRESIÓN: dejó re-procesar una solicitud ya rechazada — revisar sql/649';
  END;

  -- ══ 39. admin_propose_extra_hours + admin_get_concierge_live_reservations — sql/651 ══
  DECLARE
    v_admin39     UUID;
    v_adminops39  UUID;
    v_g39         UUID;
    v_g39_us      UUID;
    v_res39       UUID;
    v_res39_us    UUID;
    v_quote39     UUID;
    v_resp39      JSONB;
  BEGIN
    SELECT id INTO v_admin39 FROM public.profiles WHERE role='admin' LIMIT 1;
    SELECT id INTO v_adminops39 FROM public.profiles WHERE role='admin_ops' AND admin_country_scope='US' LIMIT 1;

    -- Grupo MX en conserjería, evento en curso, con paquete de 1h extra ya negociado (sql/653)
    INSERT INTO public.groups (id, owner_id, name, genre, country_id, concierge_mode)
      VALUES (gen_random_uuid(), v_owner, 'RT602 ExtraMX39', 'Banda', v_country_mx, true) RETURNING id INTO v_g39;
    INSERT INTO public.quotes
      (id, group_id, client_id, event_type, event_address, event_municipio, event_estado,
       event_date, event_time, duration_hours, venue_covered, venue_size, needs_sound, status, overtime_1h_price)
    VALUES (gen_random_uuid(), v_g39, v_client, 'boda', 'D39', 'M39', 'E39', CURRENT_DATE, '18:00', 3, 'si', 'salon_mediano', 'no_group_brings', 'quoted', 360)
    RETURNING id INTO v_quote39;
    INSERT INTO public.reservations (id, client_id, group_id, event_date, event_time, address, total_price, status, hours_count, event_started_at, quote_id)
      VALUES (gen_random_uuid(), v_client, v_g39, CURRENT_DATE, '18:00', 'Dir39', 3000, 'in_progress', 3, NOW() - INTERVAL '2 hours', v_quote39)
      RETURNING id INTO v_res39;

    -- Grupo US en conserjería, evento en curso, SIN paquete de hora extra negociado
    INSERT INTO public.groups (id, owner_id, name, genre, country_id, country, state, concierge_mode)
      VALUES (gen_random_uuid(), v_owner2, 'RT602 ExtraUS39', 'Banda', v_country_us, 'Estados Unidos', 'New York', true) RETURNING id INTO v_g39_us;
    INSERT INTO public.reservations (id, client_id, group_id, event_date, event_time, address, total_price, status, hours_count, event_started_at)
      VALUES (gen_random_uuid(), v_client, v_g39_us, CURRENT_DATE, '18:00', 'Dir US39', 3000, 'in_progress', 3, NOW() - INTERVAL '1 hour')
      RETURNING id INTO v_res39_us;

    RESET role;
    PERFORM set_config('request.jwt.claims', json_build_object('sub', v_admin39::text, 'role','authenticated')::text, true);
    PERFORM set_config('role','authenticated', true);
    v_resp39 := public.admin_get_concierge_live_reservations(500);
    RESET role;
    ASSERT EXISTS(SELECT 1 FROM jsonb_array_elements(v_resp39->'items') i WHERE (i->>'reservation_id')::uuid = v_res39),
      '[39] REGRESIÓN: admin completo no ve el evento en vivo del grupo MX — revisar sql/651';

    RESET role;
    PERFORM set_config('request.jwt.claims', json_build_object('sub', v_adminops39::text, 'role','authenticated')::text, true);
    PERFORM set_config('role','authenticated', true);
    v_resp39 := public.admin_get_concierge_live_reservations(500);
    RESET role;
    ASSERT NOT EXISTS(SELECT 1 FROM jsonb_array_elements(v_resp39->'items') i WHERE (i->>'reservation_id')::uuid = v_res39),
      '[39] REGRESIÓN: el admin_ops de EE.UU. vio un evento en vivo de México — revisar sql/651';
    ASSERT EXISTS(SELECT 1 FROM jsonb_array_elements(v_resp39->'items') i WHERE (i->>'reservation_id')::uuid = v_res39_us),
      '[39] REGRESIÓN: el admin_ops de EE.UU. no ve su propio evento en vivo — revisar sql/651';

    -- Usa el paquete de 1h ya negociado (overtime_1h_price=360) sin mandar uno nuevo
    RESET role;
    PERFORM set_config('request.jwt.claims', json_build_object('sub', v_admin39::text, 'role','authenticated')::text, true);
    PERFORM set_config('role','authenticated', true);
    v_resp39 := public.admin_propose_extra_hours(v_res39, 1, NULL, 'prueba');
    RESET role;
    ASSERT (v_resp39->>'ok')::boolean = true, '[39] REGRESIÓN: admin_propose_extra_hours falló usando el paquete ya negociado — revisar sql/653: ' || v_resp39::text;
    ASSERT (v_resp39->>'total_extra_cost')::numeric = 360,
      '[39] REGRESIÓN: total_extra_cost ya no toma el paquete de 1h ya guardado (360) — revisar sql/653: ' || (v_resp39->>'total_extra_cost');
    ASSERT EXISTS(SELECT 1 FROM notifications WHERE user_id=v_client AND type='extra_hour_proposed' AND data->>'reservation_id'=v_res39::text),
      '[39] REGRESIÓN: no se notificó al cliente la propuesta de hora extra — revisar el trigger trg_notify_extra_hour_proposed';

    -- Sin precio negociado y sin mandar uno → error claro, no adivina
    RESET role;
    PERFORM set_config('request.jwt.claims', json_build_object('sub', v_adminops39::text, 'role','authenticated')::text, true);
    PERFORM set_config('role','authenticated', true);
    v_resp39 := public.admin_propose_extra_hours(v_res39_us, 1, NULL, NULL);
    RESET role;
    ASSERT (v_resp39->>'ok')::boolean = false AND v_resp39->>'error' = 'missing_price',
      '[39] REGRESIÓN: dejó proponer horas extra sin ningún precio disponible — revisar sql/651: ' || v_resp39::text;

    -- No se puede proponer si el evento ya no está en curso
    UPDATE public.reservations SET status = 'confirmed' WHERE id = v_res39;
    RESET role;
    PERFORM set_config('request.jwt.claims', json_build_object('sub', v_admin39::text, 'role','authenticated')::text, true);
    PERFORM set_config('role','authenticated', true);
    v_resp39 := public.admin_propose_extra_hours(v_res39, 1, 300, NULL);
    RESET role;
    ASSERT (v_resp39->>'ok')::boolean = false AND v_resp39->>'error' = 'event_not_in_progress',
      '[39] REGRESIÓN: dejó proponer horas extra sin el evento en curso — revisar sql/651: ' || v_resp39::text;
  END;

  -- ══ 40. Aviso al admin (modo conserjería) cuando se paga una hora extra + precio negociado visible — sql/652 ══
  DECLARE
    v_admin40  UUID;
    v_owner40  UUID := '929ba9ba-1dfd-4b76-abf1-18168b1ac1ba';
    v_g40      UUID;
    v_res40    UUID;
    v_res40b   UUID;
    v_extra40  UUID;
    v_extra40b UUID;
    v_quote40  UUID;
    v_resp40   JSONB;
  BEGIN
    SELECT id INTO v_admin40 FROM public.profiles WHERE role='admin' LIMIT 1;
    UPDATE public.profiles SET admin_muted_countries = '{}' WHERE id = v_admin40;

    INSERT INTO public.groups (id, owner_id, name, genre, country_id, concierge_mode)
      VALUES (gen_random_uuid(), v_owner40, 'RT602 Extra40', 'Banda', v_country_mx, true) RETURNING id INTO v_g40;
    INSERT INTO public.quotes
      (id, group_id, client_id, event_type, event_address, event_municipio, event_estado,
       event_date, event_time, duration_hours, venue_covered, venue_size, needs_sound, status, overtime_1h_price)
    VALUES (gen_random_uuid(), v_g40, v_client, 'boda', 'D40', 'M40', 'E40', CURRENT_DATE, '18:00', 3, 'si', 'salon_mediano', 'no_group_brings', 'quoted', 360)
    RETURNING id INTO v_quote40;

    -- negotiated_1h visible en la cola de eventos en vivo (360 client → 300 neto)
    INSERT INTO public.reservations (id, client_id, group_id, event_date, event_time, address, total_price, status, hours_count, event_started_at, quote_id, client_available_balance, currency_code)
      VALUES (gen_random_uuid(), v_client, v_g40, CURRENT_DATE, '18:00', 'Dir40', 3000, 'in_progress', 3, NOW() - INTERVAL '2 hours', v_quote40, 1000, 'MXN')
      RETURNING id INTO v_res40;

    RESET role;
    PERFORM set_config('request.jwt.claims', json_build_object('sub', v_admin40::text, 'role','authenticated')::text, true);
    PERFORM set_config('role','authenticated', true);
    v_resp40 := public.admin_get_concierge_live_reservations(500);
    RESET role;
    ASSERT EXISTS(
      SELECT 1 FROM jsonb_array_elements(v_resp40->'items') i
      WHERE (i->>'reservation_id')::uuid = v_res40 AND (i->>'negotiated_1h')::numeric = 300
    ), '[40] REGRESIÓN: negotiated_1h ya no viaja en admin_get_concierge_live_reservations — revisar sql/653';

    -- Pago con SALDO — approve_extra_hour_payment_atomic debe avisar al admin
    INSERT INTO public.extra_hours (reservation_id, hours_added, price_per_hour, total_extra_cost, platform_commission, group_extra_earnings, status, is_cash_payment, payment_method, currency_code)
      VALUES (v_res40, 1, 300, 360, 60, 300, 'pending', false, 'balance', 'MXN')
      RETURNING id INTO v_extra40;

    RESET role;
    PERFORM set_config('request.jwt.claims', json_build_object('sub', v_client::text, 'role','authenticated')::text, true);
    PERFORM set_config('role','authenticated', true);
    v_resp40 := public.approve_extra_hour_payment_atomic(v_extra40);
    RESET role;
    ASSERT (v_resp40->>'ok')::boolean = true, '[40] REGRESIÓN: approve_extra_hour_payment_atomic falló — revisar sql/652: ' || v_resp40::text;
    ASSERT EXISTS(SELECT 1 FROM notifications WHERE user_id=v_admin40 AND type='payment' AND data->>'extra_hour_id'=v_extra40::text),
      '[40] REGRESIÓN: no se avisó al admin cuando se pagó una hora extra con saldo (grupo en conserjería) — revisar sql/652';

    -- Pago con TARJETA (Stripe) — confirm_extra_hour_stripe_payment debe avisar al admin igual
    -- (fecha distinta a v_res40 para no chocar con enforce_group_availability)
    INSERT INTO public.reservations (id, client_id, group_id, event_date, event_time, address, total_price, status, hours_count, event_started_at, currency_code)
      VALUES (gen_random_uuid(), v_client, v_g40, CURRENT_DATE + 60, '18:00', 'Dir40b', 3000, 'in_progress', 3, NOW() - INTERVAL '1 hour', 'MXN')
      RETURNING id INTO v_res40b;
    INSERT INTO public.extra_hours (reservation_id, hours_added, price_per_hour, total_extra_cost, platform_commission, group_extra_earnings, status, is_cash_payment, payment_method, currency_code)
      VALUES (v_res40b, 1, 300, 360, 60, 300, 'pending_payment', false, 'stripe', 'MXN')
      RETURNING id INTO v_extra40b;

    v_resp40 := public.confirm_extra_hour_stripe_payment(v_extra40b, 'pi_rt602_40', 360, 'MXN', 15.98);
    ASSERT (v_resp40->>'ok')::boolean = true, '[40] REGRESIÓN: confirm_extra_hour_stripe_payment falló — revisar sql/652: ' || v_resp40::text;
    ASSERT EXISTS(SELECT 1 FROM notifications WHERE user_id=v_admin40 AND type='payment' AND data->>'extra_hour_id'=v_extra40b::text),
      '[40] REGRESIÓN: no se avisó al admin cuando se pagó una hora extra con tarjeta (grupo en conserjería) — revisar sql/652';
  END;

  -- ══ 41. Paquetes de hora extra independientes por número de horas (descuento por volumen) — sql/653 ══
  DECLARE
    v_admin41 UUID;
    v_g41     UUID;
    v_q41     UUID;
    v_res41   UUID;
    v_resp41  JSONB;
  BEGIN
    SELECT id INTO v_admin41 FROM public.profiles WHERE role='admin' LIMIT 1;

    INSERT INTO public.groups (id, owner_id, name, genre, country_id, concierge_mode)
      VALUES (gen_random_uuid(), v_owner, 'RT602 Bundle41', 'Banda', v_country_mx, true) RETURNING id INTO v_g41;
    INSERT INTO public.quotes
      (id, group_id, client_id, event_type, event_address, event_municipio, event_estado,
       event_date, event_time, duration_hours, venue_covered, venue_size, needs_sound)
    VALUES (gen_random_uuid(), v_g41, v_client, 'boda', 'D41', 'M41', 'E41', CURRENT_DATE + 70, '19:00', 4, 'si', 'salon_mediano', 'no_group_brings')
    RETURNING id INTO v_q41;

    -- 1h=$400, 2h=$750 (descuento — NO 800), 3h=$1100 (descuento — NO 1200)
    RESET role;
    PERFORM set_config('request.jwt.claims', json_build_object('sub', v_admin41::text, 'role','authenticated')::text, true);
    PERFORM set_config('role','authenticated', true);
    v_resp41 := public.admin_respond_quote(v_q41, 8000, 0, 400, 750, 1100, NULL);
    RESET role;
    ASSERT (v_resp41->>'ok')::boolean = true, '[41] REGRESIÓN: admin_respond_quote falló — revisar sql/653: ' || v_resp41::text;

    INSERT INTO public.reservations (id, client_id, group_id, event_date, event_time, address, total_price, status, hours_count, event_started_at, quote_id)
      VALUES (gen_random_uuid(), v_client, v_g41, CURRENT_DATE + 70, '19:00', 'Dir41', 9600, 'in_progress', 4, NOW() - INTERVAL '4 hours', v_q41)
      RETURNING id INTO v_res41;

    -- Proponer 2h extra SIN mandar precio — debe usar el bundle de 2h ($900
    -- con markup), NUNCA 2 × precio de 1h ($480 × 2 = $960).
    RESET role;
    PERFORM set_config('request.jwt.claims', json_build_object('sub', v_admin41::text, 'role','authenticated')::text, true);
    PERFORM set_config('role','authenticated', true);
    v_resp41 := public.admin_propose_extra_hours(v_res41, 2, NULL, NULL);
    RESET role;
    ASSERT (v_resp41->>'ok')::boolean = true, '[41] REGRESIÓN: admin_propose_extra_hours falló — revisar sql/653: ' || v_resp41::text;
    ASSERT (v_resp41->>'total_extra_cost')::numeric = 900,
      '[41] REGRESIÓN: admin_propose_extra_hours volvió a multiplicar el precio de 1h en vez de usar el paquete de 2h con descuento — revisar sql/653: ' || (v_resp41->>'total_extra_cost');
    ASSERT (v_resp41->>'group_extra_earnings')::numeric = 750,
      '[41] REGRESIÓN: group_extra_earnings ya no refleja el neto real del paquete de 2h ($750) — revisar sql/653: ' || (v_resp41->>'group_extra_earnings');
  END;

  RAISE EXCEPTION 'REGRESSION_SUITE: TODO PASÓ (41/41) — temporizador, notificaciones de engagement, bono de referido MX/USD, descuento al cliente, choque de horarios, sin-temporizador por categoría (incluye fotógrafos), anuncios (clientes bloqueados, sin teléfonos, solo categoría distinta, correcto con dueños de varios grupos), cupo de Destacado/Recomendado por categoría, precio de publicidad calculado server-side (video +35%, Recomendado > Destacado), regalo/quite de Bidding del admin, ranking de Bidding por estado, TODOS los regalos (no solo Otro monto) abren GiftReveal, la notificación de admin ya no dice "Trofeo" para un monto personalizado, el interruptor de mostrar regalos a los músicos integrantes, notificar al integrante removido, notificar a los integrantes al desactivar el interruptor, la matemática de tandas/descansos, el candado+idempotencia de complete_event, auto_finalize_stuck_events por fin cierra eventos realmente atorados sin tronar, las categorías Espectáculo/Maestro de Ceremonias siguen funcionando, category_details (preguntas por categoría de Comida/Renta/Shows/Fotógrafos) guarda y lee tal cual en groups y quotes, la lista de opciones por categoría que crece sola (get_category_field_values) deduplica y no mezcla categorías, Payasos ahora vive fusionado dentro de Shows (elige descanso libremente, ya no forzado), group_category_key por fin clasifica Espectáculo/Maestro de Ceremonias correctamente, los recordatorios de evento ya respetan la zona horaria real de cada evento (no siempre México), el modo conserjería completo (cotización inicial con paquetes de hora extra INDEPENDIENTES por número de horas — nunca un precio por hora multiplicado — traslado marcado con comisión, proponer horas extra en nombre del grupo durante el evento en vivo, aviso al admin cuando se paga una hora extra por saldo o tarjeta, precio ya negociado visible en la app, todo aislado por país), y las solicitudes de proveedores nuevos (anon puede mandar, categoría inválida se rechaza, aislamiento por país, aprobar crea cuenta real en modo conserjería y bloquea doble aprobación, rechazar guarda motivo y bloquea re-procesar)';
END;
$suite$;

ROLLBACK;
