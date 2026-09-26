-- ============================================================================
-- 681 — Categoría "Terrazas y Salones" + Canadá en `countries`
-- ============================================================================
-- Petición real (2026-09-23): "que pueda subir las terrazas como si fuera
-- grupo igual un video" y "estaba pensando que será bueno que se registren
-- solos" (aprobar una por una "será un caos si son muchos").
--
-- DECISIÓN DE DISEÑO: una terraza es una fila de `groups` con
-- genre = 'Terraza', NO una tabla nueva. Razón verificada en la BD, no
-- supuesta — `groups` ya tiene TODO lo que una terraza necesita:
--   · profile_image, promo_video, video_url, video_status  → el video que pidió
--   · category_details jsonb (sql/623)                     → capacidad, incluye, etc.
--   · concierge_mode (sql/648)                             → el admin cotiza por ella
--   · country/state/city + service_cities                  → ubicación
--   · is_plus_active / admin_highlight / Destacado          → cobrar por aparecer
-- Y `admin_approve_provider_application` (el auto-registro que ya existe)
-- ya crea usuario + grupo con concierge_mode=true y acepta CUALQUIER género,
-- así que las terrazas se auto-registran hoy sin tocar ese flujo.
-- Una tabla aparte duplicaría reservas, wallet, retiros, disputas y reseñas.
--
-- `groups.genre` NO tiene CHECK constraint (verificado), así que el valor
-- 'Terraza' no requiere migrar nada. `categories` tampoco se toca: el
-- Explorador filtra en JS por los `genres` de PROVIDER_CATEGORIES
-- (HomeScreen), no por esa tabla.
--
-- Lo que SÍ hay que decirle a la BD es de qué NO es una terraza:
--   1. no toca por tandas  → sin temporizador de descansos
--   2. no se traslada      → no choca de horario con los demás proveedores
--   3. no es Express       → nadie renta un salón en 3 horas
--
-- BUG REAL ENCONTRADO DE PASO (no pedido, pero es del mismo flujo):
-- `admin_approve_provider_application` resuelve country_id con
-- "(v_cc='US' AND currency='USD') OR (v_cc='MX' AND currency='MXN')" —
-- Canadá NO está, así que CUALQUIER proveedor canadiense aprobado hoy
-- queda con country_id NULL. Además `countries` no tiene fila de Canadá.
-- Y el LIMIT 1 no tiene ORDER BY, con filas duplicadas activas/inactivas
-- ('MX' activa vs 'MXN' inactiva) — por eso 14 grupos reales quedaron
-- apuntando a la fila INACTIVA. Se corrige eligiendo por código de 2
-- letras y prefiriendo is_active, sin tocar las filas ya existentes
-- (migrar los 14 grupos es otra decisión, aparte de esto).
-- ============================================================================

BEGIN;

-- ── 1. Canadá existe como país ──────────────────────────────────────────────
INSERT INTO public.countries (
  code, name, currency_code, currency_symbol, payment_provider,
  timezone, is_active, commission_rate, default_commission
)
SELECT 'CA', 'Canadá', 'CAD', '$', 'stripe',
       'America/Toronto', true, 7.00, 7.0
WHERE NOT EXISTS (SELECT 1 FROM public.countries WHERE code = 'CA');

-- ── 2. 'Terraza' es su propia categoría ─────────────────────────────────────
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
    -- NUEVO (2026-09-23): el lugar del evento. Un solo valor sombrilla, igual
    -- que 'Sonido / Iluminación' — el cliente ya elige la terraza que quiera,
    -- no hace falta partirla en subtipos.
    WHEN p_genre = 'Terraza' THEN 'terraza'
    ELSE NULL
  END;
$$;

-- ── 3. Sin temporizador de tandas ───────────────────────────────────────────
-- 'D' = sin descansos (trabaja corrido). Una terraza está disponible todo el
-- evento; el temporizador de tandas/descansos no le aplica.
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
      'Fotografía', 'Drones', 'Cabina 360', 'Cabina fotográfica',
      'Terraza'
    ]) THEN 'D'
    ELSE NULL
  END
  FROM public.groups g WHERE g.id = p_group_id;
$$;

-- ── 4. No choca de horario con los demás proveedores ────────────────────────
-- El aviso de "otro proveedor ya tiene esa hora" existe para que dos actos en
-- vivo no se pisen. La terraza ES la sede: está desde antes y hasta después,
-- así que nunca debe aparecer como conflicto (mismo criterio que ya se usa
-- para comida/brincolines/mesas).
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
      'Renta de mesas', 'Renta de sillas',
      'Terraza'
    ]);

  RETURN jsonb_build_object('ok', true, 'ranges', v_ranges);
END;
$$;

-- ── 5. Nunca se reparte por Express ─────────────────────────────────────────
-- Hoy ya sería casi imposible (el chip de Express en el Explorador solo
-- aparece para grupo/luzSonido/Barra de mixología, y genre_matches exige que
-- el género pedido sea 'Terraza'), pero el candado va del lado del servidor
-- igual: nadie renta un salón con 3 horas de aviso.
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
  SELECT * INTO v_request
  FROM public.event_requests
  WHERE id = p_request_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'request_not_found');
  END IF;

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
      -- Una sede nunca es Express (2026-09-23)
      AND public.genre_category_key(g.genre) IS DISTINCT FROM 'terraza'
      AND NOT EXISTS (
        SELECT 1 FROM public.express_dispatches ed
        WHERE ed.request_id = p_request_id
          AND ed.group_id   = g.id
      )
      AND NOT EXISTS (
        SELECT 1 FROM public.group_unavailability gu
        WHERE gu.group_id = g.id
          AND gu.date = (NOW() AT TIME ZONE 'America/Mexico_City')::date
      )
      AND NOT EXISTS (
        SELECT 1 FROM public.reservations r
        WHERE r.group_id = g.id
          AND r.status = 'in_progress'
      )
    ORDER BY
      (lower(trim(g.city)) = lower(trim(v_request.location_city))) DESC,
      g.is_verified DESC,
      g.rating DESC NULLS LAST
    LIMIT v_max_groups
  LOOP
    INSERT INTO public.express_dispatches (
      request_id, group_id, status, expires_at
    )
    VALUES (
      p_request_id,
      v_group_row.group_id,
      'pending_broadcast',
      NOW() + (v_window_minutes || ' minutes')::interval
    )
    ON CONFLICT DO NOTHING;

    v_dispatched := v_dispatched + 1;
  END LOOP;

  IF v_dispatched > 0 THEN
    UPDATE public.event_requests
    SET express_window_until = NOW() + (v_window_minutes || ' minutes')::interval
    WHERE id = p_request_id;
  END IF;

  RETURN jsonb_build_object(
    'ok',         true,
    'dispatched', v_dispatched,
    'request_id', p_request_id,
    'window_min', v_window_minutes
  );
END;
$$;

-- ── 6. Fix: Canadá ya no queda sin country_id al aprobar ────────────────────
-- ÚNICO cambio respecto a la versión anterior: el bloque que resuelve
-- v_country_id. Todo lo demás (creación de auth.users, perfil, grupo con
-- concierge_mode=true, marcado de la solicitud) queda byte-idéntico.
CREATE OR REPLACE FUNCTION public.admin_approve_provider_application(
  p_application_id uuid,
  p_email text,
  p_genre text,
  p_temp_password text DEFAULT NULL::text
)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = 'public', 'extensions'
AS $$
DECLARE
  v_caller_role TEXT;
  v_app         RECORD;
  v_user_id     UUID;
  v_group_id    UUID;
  v_password    TEXT;
  v_country_id  UUID;
  v_cc          TEXT;
  v_description TEXT;
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
    '00000000-0000-0000-0000-000000000000',
    gen_random_uuid(),
    'authenticated',
    'authenticated',
    trim(p_email),
    extensions.crypt(v_password, extensions.gen_salt('bf')),
    NOW(), NOW(), NOW(),
    '{"provider":"email","providers":["email"]}',
    jsonb_build_object('full_name', v_app.full_name, 'role', 'group'),
    '', '', '', ''
  ) RETURNING id INTO v_user_id;

  UPDATE public.profiles SET
    full_name         = v_app.full_name,
    phone             = v_app.phone,
    role              = 'group',
    terms_accepted_at = NOW()
  WHERE id = v_user_id;

  v_cc := public.country_code_of(v_app.country);
  -- Antes: solo US y MX, y LIMIT 1 sin ORDER BY (con filas duplicadas
  -- activa/inactiva podía tocarle la inactiva). Ahora: por código de 2
  -- letras, prefiriendo la fila activa, y Canadá incluida.
  SELECT c.id INTO v_country_id
  FROM public.countries c
  WHERE c.code = v_cc
  ORDER BY c.is_active DESC NULLS LAST, c.created_at
  LIMIT 1;

  -- Respaldo por moneda si algún día llega un país sin fila de código de 2
  -- letras — mejor eso que dejar country_id en NULL como pasaba con Canadá.
  IF v_country_id IS NULL THEN
    SELECT c.id INTO v_country_id
    FROM public.countries c
    WHERE c.currency_code = CASE v_cc WHEN 'US' THEN 'USD' WHEN 'CA' THEN 'CAD' ELSE 'MXN' END
    ORDER BY c.is_active DESC NULLS LAST, c.created_at
    LIMIT 1;
  END IF;

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
    status = 'approved',
    linked_group_id = v_group_id,
    reviewed_by = auth.uid(),
    reviewed_at = NOW()
  WHERE id = p_application_id;

  RETURN jsonb_build_object('ok', true, 'user_id', v_user_id, 'group_id', v_group_id, 'email', trim(p_email), 'temp_password', v_password);
END;
$$;

GRANT EXECUTE ON FUNCTION public.admin_approve_provider_application(uuid, text, text, text) TO authenticated;
REVOKE EXECUTE ON FUNCTION public.admin_approve_provider_application(uuid, text, text, text) FROM PUBLIC, anon;

COMMIT;
