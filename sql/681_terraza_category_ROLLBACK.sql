-- ============================================================================
-- ROLLBACK de 681 — NO CORRER salvo emergencia deliberada
-- ============================================================================
-- Devuelve las 4 funciones a su definición previa a sql/681 y desactiva la
-- fila de Canadá.
--
-- OJO antes de correrlo:
--  · Si ya hay terrazas registradas (groups con genre='Terraza'), al revertir
--    genre_category_key quedan SIN categoría (genre_category_key → NULL):
--    desaparecen del Explorador y vuelven a entrar al temporizador de tandas
--    y al aviso de choque de horarios. Revisa primero:
--      SELECT count(*) FROM groups WHERE genre_in_list(genre, ARRAY['Terraza']);
--  · La fila de Canadá NO se borra (grupos/proveedores canadienses pueden ya
--    estar apuntando a ella con country_id). Solo se marca is_active=false,
--    que es el estado equivalente al de antes: "Canadá no existe".
-- ============================================================================

BEGIN;

-- 1. Canadá vuelve a estar inactiva (sin borrar: puede tener referencias)
UPDATE public.countries SET is_active = false WHERE code = 'CA';

-- 2. genre_category_key sin 'Terraza'
CREATE OR REPLACE FUNCTION public.genre_category_key(p_genre text)
RETURNS text
LANGUAGE sql IMMUTABLE SET search_path = public
AS $$
  SELECT CASE
    WHEN p_genre = ANY(ARRAY[
      'Norteño','Sierreño','Norteño-Banda','Versátil','Banda','Mariachi','Rock',
      'Bachata','Balada','Blues','Bolero','Conjunto','Country','Cuartetos','Cumbia',
      'Danzón','Electrónica','Folklore','Gospel','Hip Hop','Jazz','Marimba','Merengue',
      'Pop','R&B','Reggaeton','Salsa','Sextetos','Son Jarocho','Tango','Tríos',
      'Tropical','Trova','Vallenato',
      'Americana','Appalachian','Bluegrass','Cajun','Classical','Dance','Disco','Folk',
      'Funk','Indie','Klezmer','Metal','Motown','Punk','Soul','Southern Rock','Swing','Zydeco'
    ]) THEN 'grupo'
    WHEN p_genre = 'Solistas' THEN 'solista'
    WHEN p_genre = 'DJ' THEN 'dj'
    WHEN p_genre = 'Comediante' THEN 'comediante'
    WHEN p_genre = 'Maestro de Ceremonias' THEN 'mc'
    WHEN p_genre = ANY(ARRAY['Espectáculo','Payasos','Mago','Personajes','Animación']) THEN 'espectaculo'
    WHEN p_genre = 'Sonido / Iluminación' THEN 'luzSonido'
    WHEN p_genre = ANY(ARRAY['Comida','Barra de mixología','Snacks y botanas','Café y postres']) THEN 'comida'
    WHEN p_genre = ANY(ARRAY[
      'Escenarios','Generadores eléctricos','Inflables acuáticos','Plantas de luz',
      'Renta de brincolines','Renta de mesas','Renta de sillas','Renta de toldos','Tarimas'
    ]) THEN 'renta'
    WHEN p_genre = ANY(ARRAY['Fotografía','Drones','Cabina 360','Cabina fotográfica']) THEN 'fotografos'
    ELSE NULL
  END;
$$;

-- 3. group_default_break_type sin 'Terraza'
CREATE OR REPLACE FUNCTION public.group_default_break_type(p_group_id uuid)
RETURNS text
LANGUAGE sql STABLE SET search_path = public
AS $$
  SELECT CASE
    WHEN public.genre_in_list(g.genre, ARRAY[
      'Comediante', 'Comida', 'Barra de mixología', 'Snacks y botanas', 'Café y postres',
      'Maestro de Ceremonias',
      'Renta de brincolines', 'Inflables acuáticos',
      'Renta de mesas', 'Renta de sillas',
      'Fotografía', 'Drones', 'Cabina 360', 'Cabina fotográfica'
    ]) THEN 'D'
    ELSE NULL
  END
  FROM public.groups g WHERE g.id = p_group_id;
$$;

-- 4. client_get_event_time_conflicts sin 'Terraza'
CREATE OR REPLACE FUNCTION public.client_get_event_time_conflicts(
  p_event_id uuid,
  p_exclude_group_id uuid DEFAULT NULL::uuid
)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_client_id UUID;
  v_ranges    jsonb;
BEGIN
  IF auth.uid() IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_authenticated');
  END IF;

  SELECT client_id INTO v_client_id FROM public.events WHERE id = p_event_id;
  IF v_client_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'event_not_found');
  END IF;
  IF v_client_id <> auth.uid() THEN
    RETURN jsonb_build_object('ok', false, 'error', 'event_not_owned_by_client');
  END IF;

  SELECT COALESCE(jsonb_agg(jsonb_build_object(
           'group_name', g.name,
           'time',       q.event_time,
           'hours',      q.duration_hours
         ) ORDER BY q.event_time), '[]'::jsonb)
    INTO v_ranges
  FROM public.quotes q
  JOIN public.groups g ON g.id = q.group_id
  WHERE q.event_id = p_event_id
    AND q.status IN ('pending', 'accepted')
    AND q.event_time IS NOT NULL
    AND (p_exclude_group_id IS NULL OR q.group_id <> p_exclude_group_id)
    AND NOT public.genre_in_list(g.genre, ARRAY[
      'Comida', 'Barra de mixología', 'Snacks y botanas', 'Café y postres',
      'Renta de brincolines', 'Inflables acuáticos',
      'Renta de mesas', 'Renta de sillas'
    ]);

  RETURN jsonb_build_object('ok', true, 'ranges', v_ranges);
END;
$$;

-- 5. dispatch_express_request sin el candado de terraza
--    (se deja tal cual quedó en sql/674: el gate de 'comida' SÍ se conserva)
CREATE OR REPLACE FUNCTION public.dispatch_express_request(p_request_id uuid)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_request         public.event_requests%ROWTYPE;
  v_group_row       RECORD;
  v_dispatched      int := 0;
  v_window_minutes  int := 180;
  v_max_groups      int := 10;
BEGIN
  SELECT * INTO v_request FROM public.event_requests WHERE id = p_request_id FOR UPDATE;
  IF NOT FOUND THEN RETURN jsonb_build_object('ok', false, 'error', 'request_not_found'); END IF;
  IF v_request.status <> 'open' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'request_not_open', 'status', v_request.status);
  END IF;

  FOR v_group_row IN
    SELECT g.id AS group_id
    FROM public.groups g
    WHERE
      public.genre_matches(g.genre, v_request.genre)
      AND (
        lower(trim(g.city))  = lower(trim(v_request.location_city))
        OR lower(trim(g.state)) = lower(trim(v_request.location_estado))
      )
      AND g.is_active = true
      AND g.suspended_at IS NULL
      AND COALESCE(g.availability, 'available') = 'available'
      AND (
        public.genre_category_key(g.genre) IS DISTINCT FROM 'comida'
        OR g.express_enabled = true
      )
      AND NOT EXISTS (
        SELECT 1 FROM public.express_dispatches ed
        WHERE ed.request_id = p_request_id AND ed.group_id = g.id
      )
      AND NOT EXISTS (
        SELECT 1 FROM public.group_unavailability gu
        WHERE gu.group_id = g.id
          AND gu.date = (NOW() AT TIME ZONE 'America/Mexico_City')::date
      )
      AND NOT EXISTS (
        SELECT 1 FROM public.reservations r
        WHERE r.group_id = g.id AND r.status = 'in_progress'
      )
    ORDER BY
      (lower(trim(g.city)) = lower(trim(v_request.location_city))) DESC,
      g.is_verified DESC,
      g.rating DESC NULLS LAST
    LIMIT v_max_groups
  LOOP
    INSERT INTO public.express_dispatches (request_id, group_id, status, expires_at)
    VALUES (p_request_id, v_group_row.group_id, 'pending_broadcast',
            NOW() + (v_window_minutes || ' minutes')::interval)
    ON CONFLICT DO NOTHING;
    v_dispatched := v_dispatched + 1;
  END LOOP;

  IF v_dispatched > 0 THEN
    UPDATE public.event_requests
    SET express_window_until = NOW() + (v_window_minutes || ' minutes')::interval
    WHERE id = p_request_id;
  END IF;

  RETURN jsonb_build_object('ok', true, 'dispatched', v_dispatched,
                            'request_id', p_request_id, 'window_min', v_window_minutes);
END;
$$;

-- 6. admin_approve_provider_application con el lookup viejo (Canadá → NULL)
CREATE OR REPLACE FUNCTION public.admin_approve_provider_application(
  p_application_id uuid, p_email text, p_genre text, p_temp_password text DEFAULT NULL::text
)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = 'public', 'extensions'
AS $$
DECLARE
  v_caller_role TEXT; v_app RECORD; v_user_id UUID; v_group_id UUID;
  v_password TEXT; v_country_id UUID; v_cc TEXT; v_description TEXT;
BEGIN
  SELECT role INTO v_caller_role FROM public.profiles WHERE id = auth.uid();
  IF v_caller_role NOT IN ('admin', 'admin_ops') THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_admin');
  END IF;
  IF p_email IS NULL OR trim(p_email) = '' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'missing_email');
  END IF;
  IF p_genre IS NULL OR trim(p_genre) = '' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'missing_genre');
  END IF;

  SELECT * INTO v_app FROM public.provider_applications WHERE id = p_application_id FOR UPDATE;
  IF NOT FOUND THEN RETURN jsonb_build_object('ok', false, 'error', 'application_not_found'); END IF;
  IF v_app.status = 'approved' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'already_approved', 'linked_group_id', v_app.linked_group_id);
  END IF;
  IF v_app.status = 'rejected' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'already_rejected');
  END IF;
  IF v_caller_role = 'admin_ops'
     AND public.country_code_of(v_app.country) <> public.admin_ops_country() THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_admin');
  END IF;
  IF EXISTS (SELECT 1 FROM auth.users WHERE lower(email) = lower(trim(p_email))) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'email_already_used');
  END IF;

  v_password := COALESCE(NULLIF(trim(p_temp_password), ''), substr(md5(random()::text || clock_timestamp()::text), 1, 10));

  INSERT INTO auth.users (
    instance_id, id, aud, role, email, encrypted_password,
    email_confirmed_at, created_at, updated_at,
    raw_app_meta_data, raw_user_meta_data,
    confirmation_token, email_change, email_change_token_new, recovery_token
  ) VALUES (
    '00000000-0000-0000-0000-000000000000', gen_random_uuid(), 'authenticated', 'authenticated',
    trim(p_email), extensions.crypt(v_password, extensions.gen_salt('bf')),
    NOW(), NOW(), NOW(),
    '{"provider":"email","providers":["email"]}',
    jsonb_build_object('full_name', v_app.full_name, 'role', 'group'),
    '', '', '', ''
  ) RETURNING id INTO v_user_id;

  UPDATE public.profiles SET
    full_name = v_app.full_name, phone = v_app.phone,
    role = 'group', terms_accepted_at = NOW()
  WHERE id = v_user_id;

  v_cc := public.country_code_of(v_app.country);
  SELECT c.id INTO v_country_id FROM public.countries c
  WHERE (v_cc = 'US' AND c.currency_code = 'USD')
     OR (v_cc = 'MX' AND c.currency_code = 'MXN')
  LIMIT 1;

  v_description := trim(
    COALESCE(v_app.years_experience::text || ' años de trayectoria.', '') ||
    CASE WHEN v_app.min_hours IS NOT NULL THEN ' Contratación mínima: ' || v_app.min_hours::text || ' horas.' ELSE '' END
  );

  INSERT INTO public.groups (
    id, owner_id, name, genre, description,
    country_id, country, state, city, concierge_mode
  ) VALUES (
    gen_random_uuid(), v_user_id, v_app.full_name, p_genre, NULLIF(v_description, ''),
    v_country_id, v_app.country, v_app.state, v_app.city, true
  ) RETURNING id INTO v_group_id;

  UPDATE public.provider_applications SET
    status = 'approved', linked_group_id = v_group_id,
    reviewed_by = auth.uid(), reviewed_at = NOW()
  WHERE id = p_application_id;

  RETURN jsonb_build_object('ok', true, 'user_id', v_user_id, 'group_id', v_group_id,
                            'email', trim(p_email), 'temp_password', v_password);
END;
$$;

COMMIT;
