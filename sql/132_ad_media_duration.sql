-- ════════════════════════════════════════════════════════════════════════════
-- 132_ad_media_duration.sql
-- Añade columna duration_seconds a advertisements para videos.
-- Permite mostrar duración en la UI y aplicar autoplay sólo a videos cortos.
--
-- Ejecutar DESPUÉS de 131_top_recommendation.sql
-- ════════════════════════════════════════════════════════════════════════════

-- ── 1. Columna duration_seconds ──────────────────────────────────────────────
ALTER TABLE public.advertisements
  ADD COLUMN IF NOT EXISTS duration_seconds INT DEFAULT NULL;

COMMENT ON COLUMN public.advertisements.duration_seconds IS
  'Duración en segundos del video. NULL para anuncios de imagen o sin media.';

-- ── 2. Actualizar create_advertisement_order para aceptar duration_seconds ───
CREATE OR REPLACE FUNCTION public.create_advertisement_order(
  p_type             TEXT,
  p_title            TEXT,
  p_package_id       UUID,
  p_subtitle         TEXT        DEFAULT NULL,
  p_button_text      TEXT        DEFAULT 'Contratar',
  p_media_url        TEXT        DEFAULT NULL,
  p_media_type       TEXT        DEFAULT 'none',
  p_link_type        TEXT        DEFAULT 'none',
  p_link_url         TEXT        DEFAULT NULL,
  p_button_url       TEXT        DEFAULT NULL,
  p_location_type    TEXT        DEFAULT 'national',
  p_locations        TEXT[]      DEFAULT NULL,
  p_duration_seconds INT         DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_user_id   UUID := auth.uid();
  v_pkg       RECORD;
  v_ad_id     UUID;
BEGIN
  IF v_user_id IS NULL THEN
    RETURN jsonb_build_object('ok', FALSE, 'error', 'No autenticado');
  END IF;

  -- Verificar paquete
  SELECT * INTO v_pkg FROM public.ad_packages
  WHERE id = p_package_id AND is_active = TRUE;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', FALSE, 'error', 'Paquete no encontrado o inactivo');
  END IF;

  INSERT INTO public.advertisements (
    advertiser_id,
    type,
    title,
    subtitle,
    button_text,
    media_url,
    media_type,
    package_id,
    link_type,
    link_url,
    button_url,
    target_location_type,
    target_locations,
    duration_seconds,
    status
  ) VALUES (
    v_user_id,
    p_type,
    p_title,
    p_subtitle,
    COALESCE(p_button_text, 'Contratar'),
    p_media_url,
    p_media_type,
    p_package_id,
    p_link_type,
    p_link_url,
    p_button_url,
    p_location_type,
    p_locations,
    p_duration_seconds,
    'pending_payment'
  )
  RETURNING id INTO v_ad_id;

  RETURN jsonb_build_object(
    'ok',    TRUE,
    'ad_id', v_ad_id
  );

EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('ok', FALSE, 'error', SQLERRM);
END;
$$;

GRANT EXECUTE ON FUNCTION public.create_advertisement_order(
  TEXT, TEXT, UUID, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT[], INT
) TO authenticated;

-- ── 3. Actualizar get_pending_ads para incluir duration_seconds ──────────────
-- (DROP + CREATE para asegurar la firma actualizada)
DROP FUNCTION IF EXISTS public.get_pending_ads();

CREATE OR REPLACE FUNCTION public.get_pending_ads()
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_result JSONB := '[]'::JSONB;
BEGIN
  SELECT jsonb_agg(
    jsonb_build_object(
      'id',               a.id,
      'status',           a.status,
      'type',             a.type,
      'title',            a.title,
      'subtitle',         a.subtitle,
      'button_text',      a.button_text,
      'button_url',       a.button_url,
      'link_url',         a.link_url,
      'media_url',        a.media_url,
      'media_type',       a.media_type,
      'duration_seconds', a.duration_seconds,
      'package_name',     pkg.name,
      'advertiser_email', u.email,
      'advertiser_name',  COALESCE(p.display_name, p.full_name, u.email),
      'budget',           pkg.price,
      'starts_at',        a.starts_at,
      'ends_at',          a.ends_at,
      'rejection_reason', a.rejection_reason,
      'impressions',      a.impressions,
      'clicks',           a.clicks,
      'created_at',       a.created_at
    )
  )
  INTO v_result
  FROM public.advertisements a
  LEFT JOIN public.ad_packages        pkg ON pkg.id = a.package_id
  LEFT JOIN auth.users                u   ON u.id   = a.advertiser_id
  LEFT JOIN public.profiles           p   ON p.id   = a.advertiser_id
  WHERE a.status != 'pending_payment';  -- excluir sin pago

  RETURN COALESCE(v_result, '[]'::JSONB);

EXCEPTION WHEN OTHERS THEN
  RETURN '[]'::JSONB;
END;
$$;

GRANT EXECUTE ON FUNCTION public.get_pending_ads() TO authenticated;

SELECT '132_ad_media_duration.sql ejecutado ✅' AS status;
SELECT 'Columna: advertisements.duration_seconds' AS info
UNION ALL SELECT 'RPC: create_advertisement_order (acepta p_duration_seconds)'
UNION ALL SELECT 'RPC: get_pending_ads (incluye duration_seconds, advertiser_name, budget)';
