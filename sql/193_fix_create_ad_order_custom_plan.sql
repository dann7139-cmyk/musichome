-- ════════════════════════════════════════════════════════════════════
-- 193_fix_create_ad_order_custom_plan.sql
--
-- Fix: create_advertisement_order lanzaba "record v_pkg is not assigned yet"
-- cuando p_package_id IS NULL (plan personalizado), porque las líneas
--   v_total    := COALESCE(p_total_price, v_pkg.price, 0);
--   v_dur_days := COALESCE(v_pkg.duration_days, p_custom_days, 7);
-- acceden a v_pkg sin verificar si fue asignado.
-- ════════════════════════════════════════════════════════════════════

DROP FUNCTION IF EXISTS public.create_advertisement_order(TEXT,TEXT,TEXT,TEXT,TEXT,TEXT,UUID,TEXT,UUID,TEXT,JSONB,INT,TEXT,INT,NUMERIC,TEXT,TEXT[]);

CREATE OR REPLACE FUNCTION public.create_advertisement_order(
  p_type             TEXT,
  p_title            TEXT,
  p_subtitle         TEXT     DEFAULT NULL,
  p_button_text      TEXT     DEFAULT 'Contratar',
  p_media_url        TEXT     DEFAULT NULL,
  p_media_type       TEXT     DEFAULT 'none',
  p_package_id       UUID     DEFAULT NULL,
  p_link_type        TEXT     DEFAULT 'none',
  p_link_id          UUID     DEFAULT NULL,
  p_location_type    TEXT     DEFAULT 'national',
  p_locations        JSONB    DEFAULT NULL,
  p_duration_seconds INT      DEFAULT NULL,
  p_youtube_url      TEXT     DEFAULT NULL,
  p_custom_days      INT      DEFAULT NULL,
  p_total_price      NUMERIC  DEFAULT NULL,
  p_target_state     TEXT     DEFAULT NULL,
  p_target_states    TEXT[]   DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_user_id     UUID := auth.uid();
  v_ad_id       UUID;
  v_group_id    UUID;
  v_group_state TEXT;
  v_pkg         RECORD;
  v_total       NUMERIC;
  v_dur_days    INT;
  v_state_norm  TEXT;
  v_states_arr  TEXT[];
BEGIN
  IF v_user_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'no_session');
  END IF;

  IF p_type NOT IN ('banner_home', 'sponsored_group', 'profile_ad') THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_type: ' || COALESCE(p_type, 'null'));
  END IF;

  IF p_package_id IS NOT NULL THEN
    SELECT * INTO v_pkg FROM public.ad_packages
    WHERE id = p_package_id AND is_active = true;
    IF NOT FOUND THEN
      RETURN jsonb_build_object('ok', false, 'error', 'package_not_found');
    END IF;
  END IF;

  -- Resolver grupo + estado del anunciante
  SELECT id, state INTO v_group_id, v_group_state
  FROM   public.groups
  WHERE  owner_id = v_user_id
  LIMIT  1;

  -- target_state (single, backward compat)
  IF p_type = 'sponsored_group' THEN
    v_state_norm := normalize_state_name(v_group_state);
  ELSE
    v_state_norm := normalize_state_name(
      COALESCE(NULLIF(TRIM(COALESCE(p_target_state, '')), ''), v_group_state)
    );
  END IF;

  -- target_states (array, solo banner/profile)
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

  -- ── FIX: solo acceder a v_pkg si p_package_id IS NOT NULL ──────────
  IF p_package_id IS NOT NULL THEN
    v_total    := COALESCE(p_total_price, v_pkg.price, 0);
    v_dur_days := COALESCE(v_pkg.duration_days, p_custom_days, 7);
  ELSE
    v_total    := COALESCE(p_total_price, 0);
    v_dur_days := COALESCE(p_custom_days, 7);
  END IF;

  INSERT INTO public.advertisements (
    advertiser_id, package_id, type, title, subtitle, button_text,
    media_url, media_type, link_type, link_id,
    target_location_type, target_locations, target_state, target_states,
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
$$;

GRANT EXECUTE ON FUNCTION public.create_advertisement_order(
  TEXT,TEXT,TEXT,TEXT,TEXT,TEXT,UUID,TEXT,UUID,TEXT,JSONB,INT,TEXT,INT,NUMERIC,TEXT,TEXT[]
) TO authenticated;
