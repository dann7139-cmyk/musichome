-- ============================================================
-- sql/612_precios_publicidad_unificados.sql
-- Rediseño completo de precios de Banner Home, Anuncio de Perfil,
-- Destacado y Recomendado — petición real del usuario (2026-09-05):
-- "creo que estos no concuerdan... seria mejor bajar el precio...
-- que se vea fácil de entender... recomendados y destacados que...
-- mas caro lo de recomendados... hazlo bien echo."
--
-- PROBLEMA REAL (confirmado con 2 agentes de investigación antes de
-- tocar nada): el precio de un mismo tipo de anuncio vivía duplicado
-- a mano en 6 lugares (ad_packages.price, BANNER_HOME_PRICES en
-- AdvertisingPackagesScreen.tsx, BANNER_TIER_PRICES en
-- CreateAdvertisementScreen.tsx, la fórmula BASE_PER_DAY/LOCATION_MULT
-- del modo "personalizado", ad_price_floor() en la BD con los MISMOS
-- números de banner escritos otra vez, y textos sueltos en
-- PromocionarseScreen.tsx). Encima, create_advertisement_order SOLO
-- validaba un "piso" (70% del precio) — el cliente podía mandar
-- cualquier precio arriba de eso y la BD lo aceptaba tal cual.
--
-- SOLUCIÓN: calculate_ad_price() es ahora la ÚNICA fórmula real.
-- create_advertisement_order YA NO CONFÍA en el precio del cliente —
-- siempre recalcula server-side. ad_price_floor() queda sin uso
-- (se deja viva por si algo más la usa, no se borra).
--
-- Precios nuevos (bajados, imagen, alcance "mi ciudad"):
--   Anuncio de Perfil:  3d $129 · 7d $249  · 15d $449
--   Destacado:          3d $169 · 7d $299  · 15d $549
--   Recomendado:        3d $199 · 7d $349  · 15d $649   (> Destacado, a propósito)
--   Banner Home:        3d $229 · 7d $399  · 15d $749
-- Video (+35%, SOLO Banner Home y Anuncio de Perfil):
--   Anuncio de Perfil (video): 3d $170 · 7d $340 · 15d $610
--   Banner Home (video):       3d $310 · 7d $540 · 15d $1,010
-- El multiplicador de alcance NO cambia (city×1, multi_city×1.5,
-- national×2, international×3.5).
--
-- Simplificaciones incluidas (recomendadas, no pedidas letra por
-- letra, pero sirven directo a "que se vea fácil de entender"):
--   - Misma escala de duración (3/7/15 días) en los 4 tipos.
--   - Se quita la distinción de posición "top_1_3"/"top_4_10" del
--     Banner Home (un solo precio por duración).
--   - Se colapsan los renglones duplicados de ad_packages que solo
--     variaban por nombre/location_scope pero tenían el mismo precio
--     (confirmado con SELECT antes de escribir esto).
--
-- TESTEADO en BEGIN...ROLLBACK antes de aplicar: calculate_ad_price()
-- en los 9 puntos de referencia + video + alcance; create_advertisement_
-- order con un precio falso del cliente ($1 y luego $999999) confirmando
-- que la BD ignora ese valor y cobra el real; place_recommendation_order
-- dando $349 en 7 días (mayor que Destacado $299 en 7 días). Todo pasó.
-- ============================================================

BEGIN;

-- ── 1. calculate_ad_price — única fuente de verdad ──────────────────
CREATE OR REPLACE FUNCTION public.calculate_ad_price(
  p_type text,
  p_duration_days integer,
  p_location_type text DEFAULT 'city',
  p_is_video boolean DEFAULT false
) RETURNS numeric LANGUAGE plpgsql IMMUTABLE AS $function$
DECLARE
  v_price3 NUMERIC; v_price7 NUMERIC; v_price15 NUMERIC;
  v_base NUMERIC; v_loc_mult NUMERIC; v_video_mult NUMERIC := 1.0;
  v_days INT := GREATEST(COALESCE(p_duration_days, 7), 1);
BEGIN
  CASE p_type
    WHEN 'profile_ad'      THEN v_price3 := 129; v_price7 := 249; v_price15 := 449;
    WHEN 'sponsored_group' THEN v_price3 := 169; v_price7 := 299; v_price15 := 549;
    WHEN 'banner_home'     THEN v_price3 := 229; v_price7 := 399; v_price15 := 749;
    ELSE RAISE EXCEPTION 'invalid_ad_type: %', p_type;
  END CASE;

  IF v_days <= 3 THEN v_base := v_days * (v_price3 / 3.0);
  ELSIF v_days <= 7 THEN v_base := v_days * (v_price7 / 7.0);
  ELSE v_base := v_days * (v_price15 / 15.0);
  END IF;

  v_loc_mult := CASE COALESCE(p_location_type, 'city')
    WHEN 'city' THEN 1.0 WHEN 'multi_city' THEN 1.5
    WHEN 'national' THEN 2.0 WHEN 'international' THEN 3.5
    ELSE 1.0
  END;

  IF p_is_video AND p_type IN ('banner_home', 'profile_ad') THEN
    v_video_mult := 1.35;
  END IF;

  RETURN ROUND(v_base * v_loc_mult * v_video_mult, 2);
END;
$function$;

-- ── 2. create_advertisement_order — agrega p_is_video, ya no confía
--      en el precio del cliente. Cambia el número de parámetros, así
--      que hay que tirar la versión vieja explícitamente o Postgres
--      deja las DOS versiones vivas como sobrecarga. ──────────────────
DROP FUNCTION IF EXISTS public.create_advertisement_order(text, text, text, text, text, text, uuid, text, uuid, text, jsonb, integer, text, integer, numeric, text, text[], text);

CREATE OR REPLACE FUNCTION public.create_advertisement_order(p_type text, p_title text, p_subtitle text DEFAULT NULL::text, p_button_text text DEFAULT 'Contratar'::text, p_media_url text DEFAULT NULL::text, p_media_type text DEFAULT 'none'::text, p_package_id uuid DEFAULT NULL::uuid, p_link_type text DEFAULT 'none'::text, p_link_id uuid DEFAULT NULL::uuid, p_location_type text DEFAULT 'national'::text, p_locations jsonb DEFAULT NULL::jsonb, p_duration_seconds integer DEFAULT NULL::integer, p_youtube_url text DEFAULT NULL::text, p_custom_days integer DEFAULT NULL::integer, p_total_price numeric DEFAULT NULL::numeric, p_target_state text DEFAULT NULL::text, p_target_states text[] DEFAULT NULL::text[], p_target_country text DEFAULT NULL::text, p_is_video boolean DEFAULT false)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $function$
DECLARE
  v_user_id     UUID := auth.uid();
  v_user_role   TEXT;
  v_ad_id       UUID;
  v_group_id    UUID;
  v_group_state TEXT;
  v_pkg         RECORD;
  v_total       NUMERIC;
  v_dur_days    INT;
  v_state_norm  TEXT;
  v_states_arr  TEXT[];
  v_check_states TEXT[];
  v_avail       JSONB;
  v_intl        BOOLEAN := COALESCE(p_location_type, 'national') = 'international';
  v_phone_rx    TEXT := '(\d[\s\-.\(\)]?){7,}';
BEGIN
  IF v_user_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'no_session');
  END IF;

  SELECT role INTO v_user_role FROM public.profiles WHERE id = v_user_id;
  IF v_user_role = 'client' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'clients_cannot_advertise');
  END IF;

  IF p_type NOT IN ('banner_home', 'sponsored_group', 'profile_ad') THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_type: ' || COALESCE(p_type, 'null'));
  END IF;

  IF (p_title IS NOT NULL AND p_title ~ v_phone_rx)
     OR (p_subtitle IS NOT NULL AND p_subtitle ~ v_phone_rx) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'phone_number_not_allowed');
  END IF;

  IF p_package_id IS NOT NULL THEN
    SELECT * INTO v_pkg FROM public.ad_packages
    WHERE id = p_package_id AND is_active = true;
    IF NOT FOUND THEN
      RETURN jsonb_build_object('ok', false, 'error', 'package_not_found');
    END IF;
  END IF;

  SELECT id, state INTO v_group_id, v_group_state
  FROM   public.groups
  WHERE  owner_id = v_user_id
  LIMIT  1;

  IF v_intl THEN
    v_state_norm := NULL;
    v_states_arr := NULL;
  ELSE
    IF p_type = 'sponsored_group' THEN
      v_state_norm := normalize_state_name(v_group_state);
    ELSE
      v_state_norm := normalize_state_name(
        COALESCE(NULLIF(TRIM(COALESCE(p_target_state, '')), ''), v_group_state)
      );
    END IF;

    IF p_type IN ('banner_home', 'profile_ad')
       AND p_target_states IS NOT NULL
       AND array_length(p_target_states, 1) > 0
    THEN
      SELECT ARRAY(
        SELECT normalize_state_name(s)
        FROM   unnest(p_target_states) AS s
        WHERE  TRIM(s) <> ''
      ) INTO v_states_arr;
      IF array_length(v_states_arr, 1) IS NULL THEN
        v_states_arr := NULL;
      END IF;
    END IF;
  END IF;

  v_check_states := COALESCE(v_states_arr,
    CASE WHEN v_state_norm IS NOT NULL THEN ARRAY[v_state_norm] ELSE NULL END);

  IF p_type = 'sponsored_group' THEN
    IF v_group_id IS NULL THEN
      RETURN jsonb_build_object('ok', false, 'error', 'group_not_found');
    END IF;
    v_avail := check_sponsored_availability(v_group_id);
  ELSE
    v_avail := check_ad_availability(p_type, v_check_states);
  END IF;
  IF NOT COALESCE((v_avail->>'ok')::BOOLEAN, false) THEN
    RETURN v_avail;
  END IF;

  IF p_package_id IS NOT NULL THEN
    v_dur_days := COALESCE(v_pkg.duration_days, p_custom_days, 7);
  ELSE
    v_dur_days := COALESCE(p_custom_days, 7);
  END IF;

  -- 💰 El precio YA NO viene del cliente — calculate_ad_price() es la
  -- única fuente de verdad, recalculado siempre server-side.
  v_total := calculate_ad_price(p_type, v_dur_days, COALESCE(p_location_type, 'national'), COALESCE(p_is_video, false));

  INSERT INTO public.advertisements (
    advertiser_id, package_id, type, title, subtitle, button_text,
    media_url, media_type, link_type, link_id,
    target_location_type, target_locations, target_state, target_states,
    target_country,
    duration_seconds, youtube_url, custom_days,
    total_price, effective_price,
    status,
    starts_at, ends_at
  ) VALUES (
    v_user_id, p_package_id, p_type, p_title, p_subtitle,
    COALESCE(p_button_text, 'Contratar'),
    p_media_url, COALESCE(p_media_type, 'none'),
    CASE WHEN p_type = 'sponsored_group' THEN 'group'
         ELSE COALESCE(p_link_type, 'none') END,
    CASE WHEN p_type = 'sponsored_group' THEN v_group_id
         ELSE p_link_id END,
    COALESCE(p_location_type, 'national'), p_locations,
    v_state_norm, v_states_arr,
    p_target_country,
    p_duration_seconds,
    CASE WHEN COALESCE(p_link_type, 'none') = 'video' THEN p_youtube_url ELSE NULL END,
    p_custom_days,
    v_total, v_total,
    'pending_payment',
    NOW(),
    NOW() + (v_dur_days || ' days')::INTERVAL
  )
  RETURNING id INTO v_ad_id;

  IF p_type = 'sponsored_group' AND v_group_id IS NOT NULL THEN
    INSERT INTO public.sponsored_groups (group_id, advertiser_id, starts_at, ends_at, is_active)
    VALUES (v_group_id, v_user_id, NOW(), NOW() + (v_dur_days || ' days')::INTERVAL, false)
    ON CONFLICT DO NOTHING;
  END IF;

  RETURN jsonb_build_object(
    'ok',     true,
    'ad_id',  v_ad_id,
    'state',  v_state_norm,
    'states', v_states_arr,
    'total',  v_total
  );
END;
$function$;

-- ── 3. place_recommendation_order — nueva escalera, Recomendado > Destacado ──
CREATE OR REPLACE FUNCTION public.place_recommendation_order(p_group_id uuid, p_duration integer)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $function$
DECLARE
  v_amount   NUMERIC(10,2);
  v_per_day  NUMERIC(10,2);
  v_city     TEXT;
  v_state    TEXT;
  v_country  TEXT;
  v_order_id UUID;
  v_avail    JSONB;
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM public.groups WHERE id = p_group_id AND owner_id = auth.uid()
  ) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'unauthorized');
  END IF;

  v_avail := check_recommendation_availability(p_group_id);
  IF NOT COALESCE((v_avail->>'ok')::BOOLEAN, false) THEN
    RETURN v_avail;
  END IF;

  v_amount := CASE
    WHEN p_duration <= 3 THEN ROUND(p_duration * (199.00/3.0), 2)
    WHEN p_duration <= 7 THEN ROUND(p_duration * (349.00/7.0), 2)
    ELSE ROUND(p_duration * (649.00/15.0), 2)
  END;

  v_per_day := ROUND((v_amount / p_duration)::NUMERIC, 2);

  SELECT city, normalize_state_name(state), country
  INTO   v_city, v_state, v_country
  FROM   public.groups
  WHERE  id = p_group_id;

  INSERT INTO public.recommendation_orders
    (group_id, duration_days, amount, price_per_day, status, city, state, country)
  VALUES
    (p_group_id, p_duration, v_amount, v_per_day, 'pending_payment',
     v_city, v_state, v_country)
  RETURNING id INTO v_order_id;

  RETURN jsonb_build_object(
    'ok',       true,
    'order_id', v_order_id,
    'amount',   v_amount,
    'per_day',  v_per_day,
    'duration', p_duration,
    'city',     v_city,
    'state',    v_state,
    'country',  v_country
  );
END;
$function$;

-- ── 4. ad_packages — desactiva las filas viejas de los 3 tipos (nunca
--      se borran, hay advertisements históricas con package_id apuntando
--      aquí), inserta 9 filas nuevas limpias (3 tipos × 3 duraciones,
--      sin variantes de nombre por alcance ni tier de posición — el
--      alcance y el video se aplican como multiplicador en
--      calculate_ad_price, no como filas distintas). ──────────────────
UPDATE public.ad_packages
SET is_active = false
WHERE type IN ('banner_home', 'profile_ad', 'sponsored_group')
  AND is_active = true;

INSERT INTO public.ad_packages (name, type, duration_days, price, tier, location_scope, is_active) VALUES
  ('Anuncio de Perfil — 3 días',  'profile_ad',      3,  129.00, NULL, NULL, true),
  ('Anuncio de Perfil — 7 días',  'profile_ad',      7,  249.00, NULL, NULL, true),
  ('Anuncio de Perfil — 15 días', 'profile_ad',      15, 449.00, NULL, NULL, true),
  ('Destacado — 3 días',          'sponsored_group', 3,  169.00, NULL, NULL, true),
  ('Destacado — 7 días',          'sponsored_group', 7,  299.00, NULL, NULL, true),
  ('Destacado — 15 días',         'sponsored_group', 15, 549.00, NULL, NULL, true),
  ('Banner Home — 3 días',        'banner_home',     3,  229.00, NULL, NULL, true),
  ('Banner Home — 7 días',        'banner_home',     7,  399.00, NULL, NULL, true),
  ('Banner Home — 15 días',       'banner_home',     15, 749.00, NULL, NULL, true);

COMMIT;
