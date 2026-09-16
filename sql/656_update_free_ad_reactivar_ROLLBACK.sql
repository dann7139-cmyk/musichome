-- ============================================================================
-- ROLLBACK sql/656_update_free_ad_reactivar.sql
-- Regresa a que editar un anuncio gratis NUNCA lo reactive (status y
-- starts_at se quedan como estaban) — ⚠️ NO correr salvo emergencia
-- deliberada, revive el bug real de banners que ya no vuelven a aparecer.
-- ============================================================================

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
  v_ends_at        TIMESTAMPTZ;
  v_link_url       TEXT := NULLIF(LOWER(TRIM(COALESCE(p_link_url, ''))), '');
  v_target_country TEXT := NULLIF(LOWER(TRIM(COALESCE(p_target_country, ''))), '');
  v_button_text    TEXT := NULLIF(TRIM(COALESCE(p_button_text, '')), '');
BEGIN
  SELECT role INTO v_role FROM public.profiles WHERE id = v_user_id;
  IF v_role IS DISTINCT FROM 'admin' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'unauthorized');
  END IF;

  SELECT starts_at INTO v_starts_at
  FROM public.advertisements WHERE id = p_id AND is_free = TRUE;
  IF v_starts_at IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'ad_not_found_or_not_free');
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
    type                 = p_type,
    title                = TRIM(p_title),
    subtitle             = NULLIF(TRIM(COALESCE(p_subtitle, '')), ''),
    button_text          = v_button_text,
    media_url            = NULLIF(TRIM(COALESCE(p_media_url, '')), ''),
    media_type           = COALESCE(NULLIF(p_media_type, ''), 'none'),
    link_type            = CASE WHEN v_link_url IS NOT NULL THEN 'url' ELSE 'none' END,
    link_url             = v_link_url,
    target_state         = normalize_state_name(p_target_state),
    target_country       = v_target_country,
    ends_at              = v_ends_at,
    tag                  = NULLIF(TRIM(COALESCE(p_tag, '')), ''),
    duration_seconds     = NULLIF(p_duration_seconds, 0),
    video_start_seconds  = COALESCE(p_video_start_seconds, 0),
    updated_at           = NOW()
  WHERE id = p_id AND is_free = TRUE;

  RETURN jsonb_build_object(
    'ok',                   true,
    'ad_id',                p_id,
    'type',                 p_type,
    'button_text',          v_button_text,
    'target_country',       v_target_country,
    'target_state',         normalize_state_name(p_target_state),
    'link_url',             v_link_url,
    'ends_at',              v_ends_at,
    'duration_seconds',     p_duration_seconds,
    'video_start_seconds',  p_video_start_seconds
  );
END;
$function$;
