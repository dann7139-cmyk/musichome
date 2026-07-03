-- ============================================================
-- test_express_dispatches.sql
-- Crea 3 solicitudes express en distintas zonas del área GDL.
-- Ejecutar en: Supabase Dashboard → SQL Editor
-- Borrar con: test_express_dispatches_delete.sql
-- ============================================================

DO $$
DECLARE
  v_owner_id uuid := '929ba9ba-1dfd-4b76-abf1-18168b1ac1ba';
  v_group_id uuid := '83911568-2694-4541-81ae-af1f80bc490e';
  v_req_id   uuid;
BEGIN

  -- 1. Fiesta privada — Tlaquepaque
  INSERT INTO public.event_requests (
    client_id, event_type, genre,
    event_date, event_time, hours, guest_count,
    location_city, location_municipio, location_estado,
    comments, status
  ) VALUES (
    v_owner_id, 'fiesta_privada', 'Norteño',
    CURRENT_DATE + 1, '21:00', 4, 80,
    'Guadalajara', 'Tlaquepaque', 'Jalisco',
    '🧪 Prueba 1 — Tlaquepaque', 'open'
  ) RETURNING id INTO v_req_id;

  INSERT INTO public.express_dispatches (request_id, group_id, status, expires_at)
  VALUES (v_req_id, v_group_id, 'pending_broadcast', NOW() + INTERVAL '15 minutes');

  -- 2. Boda — Tonalá
  INSERT INTO public.event_requests (
    client_id, event_type, genre,
    event_date, event_time, hours, guest_count,
    location_city, location_municipio, location_estado,
    comments, status
  ) VALUES (
    v_owner_id, 'boda', 'Banda',
    CURRENT_DATE + 2, '18:00', 6, 200,
    'Guadalajara', 'Tonalá', 'Jalisco',
    '🧪 Prueba 2 — Tonalá', 'open'
  ) RETURNING id INTO v_req_id;

  INSERT INTO public.express_dispatches (request_id, group_id, status, expires_at)
  VALUES (v_req_id, v_group_id, 'pending_broadcast', NOW() + INTERVAL '15 minutes');

  -- 3. Graduación — Zapopan Norte
  INSERT INTO public.event_requests (
    client_id, event_type, genre,
    event_date, event_time, hours, guest_count,
    location_city, location_municipio, location_estado,
    comments, status
  ) VALUES (
    v_owner_id, 'graduacion', 'Mariachi',
    CURRENT_DATE + 3, '20:00', 5, 150,
    'Zapopan', 'Zapopan', 'Jalisco',
    '🧪 Prueba 3 — Zapopan', 'open'
  ) RETURNING id INTO v_req_id;

  INSERT INTO public.express_dispatches (request_id, group_id, status, expires_at)
  VALUES (v_req_id, v_group_id, 'pending_broadcast', NOW() + INTERVAL '15 minutes');

  RAISE NOTICE '✅ 3 solicitudes express creadas para group_id=%', v_group_id;
END;
$$;
