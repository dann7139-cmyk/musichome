-- ============================================================
-- sql/338_button_text_nullable.sql
--
-- Permite crear anuncios sin botón de acción.
-- El admin puede elegir "Sin botón" y button_text quedará NULL.
-- El explorador solo muestra el botón cuando button_text IS NOT NULL.
-- ============================================================

ALTER TABLE public.advertisements
  ALTER COLUMN button_text DROP NOT NULL;

-- Actualiza create_free_ad para que NULL en p_button_text
-- se inserte como NULL (sin el COALESCE que forzaba 'Ver más').
DROP FUNCTION IF EXISTS public.create_free_ad(TEXT,TEXT,TEXT,TEXT,TEXT,TEXT,TEXT,INT,TEXT,TEXT,INT,INT,TEXT);

CREATE OR REPLACE FUNCTION public.create_free_ad(
  p_type                TEXT,
  p_title               TEXT,
  p_subtitle            TEXT    DEFAULT NULL,
  p_button_text         TEXT    DEFAULT NULL,   -- NULL = sin botón
  p_media_url           TEXT    DEFAULT NULL,
  p_media_type          TEXT    DEFAULT NULL,
  p_target_state        TEXT    DEFAULT NULL,
  p_duration_days       INT     DEFAULT 30,
  p_tag                 TEXT    DEFAULT NULL,
  p_link_url            TEXT    DEFAULT NULL,
  p_duration_seconds    INT     DEFAULT NULL,
  p_video_start_seconds INT     DEFAULT 0,
  p_target_country      TEXT    DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public
AS $$
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
    p_type,
    TRIM(p_title),
    NULLIF(TRIM(COALESCE(p_subtitle, '')), ''),
    v_button_text,                               -- NULL si el admin eligió "Sin botón"
    NULLIF(TRIM(COALESCE(p_media_url, '')), ''),
    NULLIF(p_media_type, ''),
    CASE WHEN v_link_url IS NOT NULL THEN 'url' ELSE 'none' END,
    v_link_url,
    normalize_state_name(p_target_state),
    v_target_country,
    'active',
    TRUE,
    NOW(),
    v_ends_at,
    NULLIF(TRIM(COALESCE(p_tag, '')), ''),
    v_user_id,
    NULLIF(p_duration_seconds, 0),
    COALESCE(p_video_start_seconds, 0)
  )
  RETURNING id INTO v_ad_id;

  RETURN jsonb_build_object(
    'ok',                   true,
    'ad_id',                v_ad_id,
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
$$;

GRANT EXECUTE ON FUNCTION public.create_free_ad(TEXT,TEXT,TEXT,TEXT,TEXT,TEXT,TEXT,INT,TEXT,TEXT,INT,INT,TEXT)
  TO authenticated;

DO $$
BEGIN
  RAISE NOTICE '[338] advertisements.button_text ahora es nullable ✅';
  RAISE NOTICE '[338] create_free_ad: NULL button_text = sin botón en el explorador ✅';
END;
$$;

SELECT '338_button_text_nullable.sql ejecutado ✅' AS status;
