-- ROLLBACK de sql/610_recomendado_destacado_por_categoria.sql
-- Solo correr en emergencia deliberada. Regresa Recomendado y Destacado
-- a un cupo compartido (10) entre todas las categorías, como estaba
-- antes. No borra group_category_key (queda sin uso, inofensiva) ni
-- check_sponsored_availability (queda sin uso, inofensiva) — solo por
-- si algo más llegó a depender de ellas; bórralas a mano si estás seguro
-- de que nada las usa.

BEGIN;

CREATE OR REPLACE FUNCTION public.check_recommendation_availability(p_group_id uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public' AS $function$
DECLARE
  v_state TEXT;
  v_used  INT;
  v_limit INT := 10;
BEGIN
  SELECT normalize_state_name(state) INTO v_state
  FROM groups WHERE id = p_group_id;

  SELECT COUNT(DISTINCT ro.group_id) INTO v_used
  FROM recommendation_orders ro
  WHERE ro.status = 'paid'
    AND ro.ends_at IS NOT NULL AND ro.ends_at > NOW()
    AND ro.group_id <> p_group_id
    AND (
      v_state IS NULL
      OR ro.state IS NULL
      OR ro.state = v_state
    );

  IF v_used >= v_limit THEN
    RETURN jsonb_build_object('ok', false, 'error', 'no_capacity',
      'scope', 'recommendation', 'state', v_state,
      'used', v_used, 'limit', v_limit);
  END IF;

  RETURN jsonb_build_object('ok', true, 'used', v_used, 'limit', v_limit, 'state', v_state);
END;
$function$;

CREATE OR REPLACE FUNCTION public.create_advertisement_order(p_type text, p_title text, p_subtitle text DEFAULT NULL::text, p_button_text text DEFAULT 'Contratar'::text, p_media_url text DEFAULT NULL::text, p_media_type text DEFAULT 'none'::text, p_package_id uuid DEFAULT NULL::uuid, p_link_type text DEFAULT 'none'::text, p_link_id uuid DEFAULT NULL::uuid, p_location_type text DEFAULT 'national'::text, p_locations jsonb DEFAULT NULL::jsonb, p_duration_seconds integer DEFAULT NULL::integer, p_youtube_url text DEFAULT NULL::text, p_custom_days integer DEFAULT NULL::integer, p_total_price numeric DEFAULT NULL::numeric, p_target_state text DEFAULT NULL::text, p_target_states text[] DEFAULT NULL::text[], p_target_country text DEFAULT NULL::text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $function$
DECLARE
  v_user_id     UUID := auth.uid();
  v_user_role   TEXT;
  v_ad_id       UUID;
  v_group_id    UUID;
  v_group_state TEXT;
  v_pkg         RECORD;
  v_total       NUMERIC;
  v_floor       NUMERIC;
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
  v_avail := check_ad_availability(p_type, v_check_states);
  IF NOT COALESCE((v_avail->>'ok')::BOOLEAN, false) THEN
    RETURN v_avail;
  END IF;

  IF p_package_id IS NOT NULL THEN
    v_total    := COALESCE(p_total_price, v_pkg.price, 0);
    v_dur_days := COALESCE(v_pkg.duration_days, p_custom_days, 7);
  ELSE
    v_total    := COALESCE(p_total_price, 0);
    v_dur_days := COALESCE(p_custom_days, 7);
  END IF;

  v_floor := ad_price_floor(p_type, p_package_id, p_custom_days);
  IF v_total < v_floor THEN
    RETURN jsonb_build_object('ok', false, 'error', 'price_below_minimum', 'minimum', v_floor);
  END IF;

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

COMMIT;
