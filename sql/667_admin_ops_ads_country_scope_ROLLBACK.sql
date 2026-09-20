-- ROLLBACK de sql/667 — regresa las 6 funciones a admin-only y quita la
-- política/helper nuevos. Deja a admin_ops sin poder tocar anuncios,
-- como estaba antes.

DROP POLICY IF EXISTS ads_select_admin_ops ON public.advertisements;
DROP FUNCTION IF EXISTS public.admin_ops_scope_country_lc();

CREATE OR REPLACE FUNCTION public.create_free_ad(p_type text, p_title text, p_subtitle text DEFAULT NULL::text, p_button_text text DEFAULT NULL::text, p_media_url text DEFAULT NULL::text, p_media_type text DEFAULT NULL::text, p_target_state text DEFAULT NULL::text, p_duration_days integer DEFAULT 30, p_tag text DEFAULT NULL::text, p_link_url text DEFAULT NULL::text, p_duration_seconds integer DEFAULT NULL::integer, p_video_start_seconds integer DEFAULT 0, p_target_country text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_user_id        UUID := auth.uid();
  v_role           TEXT;
  v_ad_id          UUID;
  v_ends_at        TIMESTAMPTZ;
  v_link_url       TEXT := NULLIF(LOWER(TRIM(COALESCE(p_link_url, ''))), '');
  v_target_country TEXT := NULLIF(LOWER(TRIM(COALESCE(p_target_country, ''))), '');
  v_button_text    TEXT := NULLIF(TRIM(COALESCE(p_button_text, '')), '');
BEGIN
  SELECT role INTO v_role FROM public.profiles WHERE id = v_user_id;
  IF v_role IS DISTINCT FROM 'admin' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'unauthorized');
  END IF;

  IF p_type NOT IN ('banner_home', 'profile_ad', 'sponsored_group') THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_type',
      'allowed', '["banner_home","profile_ad","sponsored_group"]'::JSONB);
  END IF;

  IF p_title IS NULL OR TRIM(p_title) = '' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'title_required');
  END IF;

  IF v_link_url IS NOT NULL AND v_link_url !~* '^https?://' THEN
    v_link_url := 'https://' || v_link_url;
  END IF;

  v_ends_at := CASE
    WHEN p_duration_days IS NOT NULL AND p_duration_days > 0
    THEN NOW() + (p_duration_days || ' days')::INTERVAL
    ELSE NULL
  END;

  INSERT INTO public.advertisements (
    type, title, subtitle, button_text,
    media_url, media_type,
    link_type, link_url,
    target_state, target_country,
    status, is_free,
    starts_at, ends_at, tag,
    advertiser_id,
    duration_seconds, video_start_seconds
  )
  VALUES (
    p_type, TRIM(p_title), NULLIF(TRIM(COALESCE(p_subtitle, '')), ''), v_button_text,
    NULLIF(TRIM(COALESCE(p_media_url, '')), ''), NULLIF(p_media_type, ''),
    CASE WHEN v_link_url IS NOT NULL THEN 'url' ELSE 'none' END, v_link_url,
    normalize_state_name(p_target_state), v_target_country,
    'active', TRUE, NOW(), v_ends_at, NULLIF(TRIM(COALESCE(p_tag, '')), ''),
    v_user_id, NULLIF(p_duration_seconds, 0), COALESCE(p_video_start_seconds, 0)
  )
  RETURNING id INTO v_ad_id;

  RETURN jsonb_build_object(
    'ok', true, 'ad_id', v_ad_id, 'type', p_type, 'button_text', v_button_text,
    'target_country', v_target_country, 'target_state', normalize_state_name(p_target_state),
    'link_url', v_link_url, 'ends_at', v_ends_at,
    'duration_seconds', p_duration_seconds, 'video_start_seconds', p_video_start_seconds
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.update_free_ad(p_id uuid, p_type text, p_title text, p_subtitle text DEFAULT NULL::text, p_button_text text DEFAULT NULL::text, p_media_url text DEFAULT NULL::text, p_media_type text DEFAULT NULL::text, p_target_state text DEFAULT NULL::text, p_duration_days integer DEFAULT 30, p_tag text DEFAULT NULL::text, p_link_url text DEFAULT NULL::text, p_duration_seconds integer DEFAULT NULL::integer, p_video_start_seconds integer DEFAULT 0, p_target_country text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_user_id        UUID := auth.uid();
  v_role           TEXT;
  v_starts_at      TIMESTAMPTZ;
  v_old_status     TEXT;
  v_old_ends_at    TIMESTAMPTZ;
  v_ends_at        TIMESTAMPTZ;
  v_link_url       TEXT := NULLIF(LOWER(TRIM(COALESCE(p_link_url, ''))), '');
  v_target_country TEXT := NULLIF(LOWER(TRIM(COALESCE(p_target_country, ''))), '');
  v_button_text    TEXT := NULLIF(TRIM(COALESCE(p_button_text, '')), '');
BEGIN
  SELECT role INTO v_role FROM public.profiles WHERE id = v_user_id;
  IF v_role IS DISTINCT FROM 'admin' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'unauthorized');
  END IF;

  SELECT starts_at, status, ends_at INTO v_starts_at, v_old_status, v_old_ends_at
  FROM public.advertisements WHERE id = p_id AND is_free = TRUE;
  IF v_starts_at IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'ad_not_found_or_not_free');
  END IF;

  IF v_old_status = 'expired' OR (v_old_ends_at IS NOT NULL AND v_old_ends_at <= NOW()) THEN
    v_starts_at := NOW();
  END IF;

  IF p_type NOT IN ('banner_home', 'profile_ad', 'sponsored_group') THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_type',
      'allowed', '["banner_home","profile_ad","sponsored_group"]'::JSONB);
  END IF;

  IF p_title IS NULL OR TRIM(p_title) = '' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'title_required');
  END IF;

  IF v_link_url IS NOT NULL AND v_link_url !~* '^https?://' THEN
    v_link_url := 'https://' || v_link_url;
  END IF;

  v_ends_at := CASE
    WHEN p_duration_days IS NOT NULL AND p_duration_days > 0
    THEN v_starts_at + (p_duration_days || ' days')::INTERVAL
    ELSE NULL
  END;

  UPDATE public.advertisements SET
    type = p_type, title = TRIM(p_title), subtitle = NULLIF(TRIM(COALESCE(p_subtitle, '')), ''),
    button_text = v_button_text, media_url = NULLIF(TRIM(COALESCE(p_media_url, '')), ''),
    media_type = COALESCE(NULLIF(p_media_type, ''), 'none'),
    link_type = CASE WHEN v_link_url IS NOT NULL THEN 'url' ELSE 'none' END, link_url = v_link_url,
    target_state = normalize_state_name(p_target_state), target_country = v_target_country,
    starts_at = v_starts_at, ends_at = v_ends_at, status = 'active',
    tag = NULLIF(TRIM(COALESCE(p_tag, '')), ''), duration_seconds = NULLIF(p_duration_seconds, 0),
    video_start_seconds = COALESCE(p_video_start_seconds, 0), updated_at = NOW()
  WHERE id = p_id AND is_free = TRUE;

  RETURN jsonb_build_object(
    'ok', true, 'ad_id', p_id, 'type', p_type, 'button_text', v_button_text,
    'target_country', v_target_country, 'target_state', normalize_state_name(p_target_state),
    'link_url', v_link_url, 'starts_at', v_starts_at, 'ends_at', v_ends_at,
    'duration_seconds', p_duration_seconds, 'video_start_seconds', p_video_start_seconds
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.approve_ad(p_id uuid, p_duration_days integer DEFAULT NULL::integer)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_ad     public.advertisements%ROWTYPE;
  v_days   INT;
  v_states TEXT[];
  v_st     TEXT;
  v_cnt    INT;
  v_limit  INT;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.profiles WHERE id = auth.uid() AND role = 'admin') THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_admin');
  END IF;

  SELECT * INTO v_ad FROM public.advertisements WHERE id = p_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_found');
  END IF;

  IF v_ad.status = 'pending_payment' AND COALESCE(v_ad.is_free, false) = false THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_paid_yet');
  END IF;

  v_days := COALESCE(
    p_duration_days,
    NULLIF(GREATEST(EXTRACT(DAY FROM (v_ad.ends_at - v_ad.created_at))::INT, 0), 0),
    CASE v_ad.type WHEN 'banner_home' THEN 7 WHEN 'sponsored_group' THEN 30 WHEN 'profile_ad' THEN 14 ELSE 7 END
  );

  v_states := COALESCE(v_ad.target_states,
    CASE WHEN v_ad.target_state IS NOT NULL THEN ARRAY[v_ad.target_state] ELSE NULL END);

  IF v_states IS NULL THEN
    v_limit := ad_global_limit(v_ad.type);
    SELECT COUNT(*) INTO v_cnt FROM public.advertisements a
    WHERE a.type = v_ad.type AND a.status = 'active' AND a.id <> p_id
      AND (a.ends_at IS NULL OR a.ends_at > NOW())
      AND a.target_states IS NULL AND a.target_state IS NULL;
    IF v_cnt >= v_limit THEN
      RETURN jsonb_build_object('ok', false, 'error', 'limit_reached', 'scope', 'global', 'count', v_cnt, 'limit', v_limit);
    END IF;
  ELSE
    v_limit := ad_state_limit(v_ad.type);
    FOREACH v_st IN ARRAY v_states LOOP
      SELECT COUNT(*) INTO v_cnt FROM public.advertisements a
      WHERE a.type = v_ad.type AND a.status = 'active' AND a.id <> p_id
        AND (a.ends_at IS NULL OR a.ends_at > NOW())
        AND (
          (a.target_states IS NULL AND a.target_state IS NULL)
          OR (a.target_states IS NOT NULL AND v_st = ANY(a.target_states))
          OR (a.target_states IS NULL AND a.target_state = v_st)
        );
      IF v_cnt >= v_limit THEN
        RETURN jsonb_build_object('ok', false, 'error', 'limit_reached', 'scope', 'state', 'state', v_st, 'count', v_cnt, 'limit', v_limit);
      END IF;
    END LOOP;
  END IF;

  UPDATE public.advertisements
  SET status = 'active', starts_at = NOW(), ends_at = NOW() + (v_days || ' days')::INTERVAL, updated_at = NOW()
  WHERE id = p_id;

  IF v_ad.type = 'sponsored_group' THEN
    UPDATE public.sponsored_groups
    SET is_active = true, ends_at = NOW() + (v_days || ' days')::INTERVAL
    WHERE id = (
      SELECT id FROM public.sponsored_groups
      WHERE advertiser_id = v_ad.advertiser_id AND is_active = false
      ORDER BY created_at DESC LIMIT 1
    );
  END IF;

  RETURN jsonb_build_object('ok', true, 'days', v_days);
END;
$function$;

CREATE OR REPLACE FUNCTION public.reject_ad(p_id uuid, p_reason text DEFAULT NULL::text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_ad RECORD;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.profiles WHERE id = auth.uid() AND role = 'admin') THEN
    RAISE EXCEPTION 'Unauthorized';
  END IF;

  SELECT * INTO v_ad FROM public.advertisements WHERE id = p_id;
  IF NOT FOUND THEN RETURN; END IF;

  UPDATE public.advertisements
  SET status = 'rejected', rejection_reason = p_reason, updated_at = now()
  WHERE id = p_id;

  IF v_ad.type = 'sponsored_group' AND v_ad.link_id IS NOT NULL THEN
    UPDATE public.sponsored_groups SET is_active = false
    WHERE group_id = v_ad.link_id AND advertiser_id = v_ad.advertiser_id;
  END IF;

  INSERT INTO public.notifications (user_id, type, title, body, data, is_read)
  VALUES (
    v_ad.advertiser_id, 'ad_rejected',
    CASE v_ad.type WHEN 'sponsored_group' THEN '❌ Anuncio de grupo no aprobado' WHEN 'banner_home' THEN '❌ Banner no aprobado' ELSE '❌ Anuncio no aprobado' END,
    CASE WHEN p_reason IS NOT NULL AND p_reason <> '' THEN 'Tu anuncio no fue aprobado. Motivo: ' || p_reason ELSE 'Tu anuncio no fue aprobado. Contáctanos para más información.' END,
    jsonb_build_object('ad_id', p_id, 'type', v_ad.type, 'reason', p_reason), false
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.toggle_ad(p_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_ad         RECORD;
  v_new_status TEXT;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.profiles WHERE id = auth.uid() AND role = 'admin') THEN
    RETURN jsonb_build_object('ok', false, 'error', 'Unauthorized');
  END IF;

  SELECT id, title, status, type, advertiser_id, package_id
  INTO v_ad FROM public.advertisements WHERE id = p_id;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'ad_not_found');
  END IF;

  v_new_status := CASE WHEN v_ad.status = 'active' THEN 'paused' ELSE 'active' END;

  UPDATE public.advertisements SET status = v_new_status, updated_at = now() WHERE id = p_id;

  IF v_ad.type = 'sponsored_group' THEN
    UPDATE public.sponsored_groups SET is_active = (v_new_status = 'active')
    WHERE advertiser_id = v_ad.advertiser_id AND package_id = v_ad.package_id;
  END IF;

  INSERT INTO public.ad_audit_log (ad_id, action, performed_by, details)
  VALUES (p_id, CASE WHEN v_new_status = 'paused' THEN 'paused' ELSE 'resumed' END, auth.uid(),
    jsonb_build_object('title', v_ad.title, 'new_status', v_new_status));

  RETURN jsonb_build_object('ok', true, 'status', v_new_status);
END;
$function$;

CREATE OR REPLACE FUNCTION public.delete_ad(p_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_title      TEXT;
  v_type       TEXT;
  v_advertiser UUID;
  v_link_id    UUID;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.profiles WHERE id = auth.uid() AND role = 'admin') THEN
    RETURN jsonb_build_object('ok', false, 'error', 'Unauthorized');
  END IF;

  SELECT title, type, advertiser_id, link_id
  INTO v_title, v_type, v_advertiser, v_link_id
  FROM public.advertisements WHERE id = p_id;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'ad_not_found');
  END IF;

  INSERT INTO public.ad_audit_log (ad_id, action, performed_by, details)
  VALUES (p_id, 'deleted', auth.uid(), jsonb_build_object('title', v_title, 'type', v_type, 'advertiser_id', v_advertiser));

  IF v_type = 'sponsored_group' AND v_link_id IS NOT NULL THEN
    UPDATE public.sponsored_groups SET is_active = false
    WHERE group_id = v_link_id AND advertiser_id = v_advertiser;
  END IF;

  DELETE FROM public.advertisements WHERE id = p_id;

  RETURN jsonb_build_object('ok', true);
END;
$function$;
