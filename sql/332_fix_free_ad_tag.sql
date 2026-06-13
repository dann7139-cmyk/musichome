-- ============================================================
-- sql/332_fix_free_ad_tag.sql
--
-- FIX: create_free_ad insertaba NULL explícito en la columna tag
-- cuando no se manda p_tag. Un NULL explícito NO usa el DEFAULT
-- de la tabla ('PUBLICIDAD') y tag es NOT NULL:
--   "null value in column tag violates not-null constraint"
--
-- (Bug heredado de sql/179 y conservado en sql/331.)
-- Única diferencia vs 331: tag con fallback a 'PUBLICIDAD'.
-- ============================================================

CREATE OR REPLACE FUNCTION public.create_free_ad(
  p_type          TEXT,
  p_title         TEXT,
  p_subtitle      TEXT    DEFAULT NULL,
  p_button_text   TEXT    DEFAULT 'Ver más',
  p_media_url     TEXT    DEFAULT NULL,
  p_media_type    TEXT    DEFAULT NULL,   -- 'image' | 'video'
  p_target_state  TEXT    DEFAULT NULL,
  p_duration_days INT     DEFAULT 30,
  p_tag           TEXT    DEFAULT NULL,
  p_link_url      TEXT    DEFAULT NULL    -- enlace que abre el botón
)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_user_id  UUID := auth.uid();
  v_role     TEXT;
  v_ad_id    UUID;
  v_ends_at  TIMESTAMPTZ;
  v_link_url TEXT := NULLIF(TRIM(COALESCE(p_link_url, '')), '');
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
    target_state, status, is_free,
    starts_at, ends_at, tag,
    advertiser_id
  )
  VALUES (
    p_type,
    TRIM(p_title),
    NULLIF(TRIM(COALESCE(p_subtitle, '')), ''),
    COALESCE(NULLIF(TRIM(p_button_text), ''), 'Ver más'),
    NULLIF(TRIM(COALESCE(p_media_url, '')), ''),
    NULLIF(p_media_type, ''),
    CASE WHEN v_link_url IS NOT NULL THEN 'url' ELSE 'none' END,
    v_link_url,
    normalize_state_name(p_target_state),
    'active',
    TRUE,
    NOW(),
    v_ends_at,
    -- FIX: tag es NOT NULL — sin p_tag usar 'PUBLICIDAD'
    COALESCE(NULLIF(TRIM(COALESCE(p_tag, '')), ''), 'PUBLICIDAD'),
    v_user_id
  )
  RETURNING id INTO v_ad_id;

  RETURN jsonb_build_object(
    'ok',       true,
    'ad_id',    v_ad_id,
    'type',     p_type,
    'link_url', v_link_url,
    'ends_at',  v_ends_at
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.create_free_ad(TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, INT, TEXT, TEXT)
  TO authenticated;

SELECT '332_fix_free_ad_tag.sql ejecutado ✅' AS status;
