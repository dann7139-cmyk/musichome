-- ════════════════════════════════════════════════════════════════════════════
-- 162_fix_create_ad_order_final.sql
-- Alinea create_advertisement_order con los parámetros exactos que envía
-- CreateAdvertisementScreen.tsx (handlePay).
--
-- Parámetros enviados por la app:
--   p_type, p_title, p_subtitle, p_button_text,
--   p_media_url, p_media_type,
--   p_package_id,
--   p_link_type, p_link_id,
--   p_location_type, p_locations,
--   p_duration_seconds, p_youtube_url,
--   p_custom_days,
--   p_total_price
--
-- Ejecutar DESPUÉS de 161_fix_create_advertisement_order.sql
-- ════════════════════════════════════════════════════════════════════════════

-- ── 1. Columnas extra si no existen ──────────────────────────────────────────

ALTER TABLE public.advertisements
  ADD COLUMN IF NOT EXISTS custom_days  INT,
  ADD COLUMN IF NOT EXISTS total_price  NUMERIC(10,2);

-- ── 2. Drop TODAS las sobrecargas anteriores ──────────────────────────────────

DROP FUNCTION IF EXISTS public.create_advertisement_order(TEXT,TEXT,TEXT,TEXT,TEXT,TEXT,UUID,UUID,TEXT,TEXT,TEXT);
DROP FUNCTION IF EXISTS public.create_advertisement_order(TEXT,TEXT,TEXT,TEXT,TEXT,TEXT,UUID,UUID,TEXT,TEXT);
DROP FUNCTION IF EXISTS public.create_advertisement_order(TEXT,TEXT,TEXT,TEXT,TEXT,TEXT,UUID,TEXT,TEXT,JSONB,INT,TEXT,INT,NUMERIC);
DROP FUNCTION IF EXISTS public.create_advertisement_order(TEXT,TEXT,TEXT,TEXT,TEXT,TEXT,UUID,UUID,TEXT,TEXT,TEXT,TEXT,JSONB,INT,NUMERIC,INT,TEXT);
DROP FUNCTION IF EXISTS public.create_advertisement_order(TEXT,TEXT,UUID,TEXT,TEXT,TEXT,TEXT,TEXT,UUID,TEXT,TEXT[],INT);
DROP FUNCTION IF EXISTS public.create_advertisement_order(TEXT,TEXT,TEXT,TEXT,TEXT,TEXT,UUID,UUID,TEXT,TEXT,TEXT,TEXT[],INT,TEXT);
DROP FUNCTION IF EXISTS public.create_advertisement_order(TEXT,TEXT,TEXT,TEXT,TEXT,TEXT,UUID,TEXT,UUID,TEXT,JSONB,INT,TEXT,INT,NUMERIC);

-- ── 3. Función final ──────────────────────────────────────────────────────────

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
  p_total_price      NUMERIC  DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_user_id  UUID := auth.uid();
  v_ad_id    UUID;
  v_group_id UUID;
  v_pkg      RECORD;
  v_total    NUMERIC;
  v_dur_days INT;
BEGIN
  -- Validar sesión
  IF v_user_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'no_session');
  END IF;

  -- Validar tipo
  IF p_type NOT IN ('banner_home', 'sponsored_group', 'profile_ad') THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_type: ' || COALESCE(p_type, 'null'));
  END IF;

  -- Cargar paquete si se especifica
  IF p_package_id IS NOT NULL THEN
    SELECT * INTO v_pkg FROM public.ad_packages
    WHERE id = p_package_id AND is_active = true;
    IF NOT FOUND THEN
      RETURN jsonb_build_object('ok', false, 'error', 'package_not_found');
    END IF;
  END IF;

  -- Para sponsored_group: resolver el grupo del anunciante
  IF p_type = 'sponsored_group' THEN
    SELECT id INTO v_group_id FROM public.groups
    WHERE owner_id = v_user_id LIMIT 1;
    IF NOT FOUND THEN
      RETURN jsonb_build_object('ok', false, 'error', 'group_not_found');
    END IF;
  END IF;

  -- Precio final = lo que calculó el frontend (no se recalcula en DB)
  v_total := COALESCE(p_total_price, v_pkg.price, 0);

  -- Duración en días: del paquete o de días personalizados
  v_dur_days := COALESCE(v_pkg.duration_days, p_custom_days, 7);

  RAISE NOTICE '[create_advertisement_order] type=% pkg=% custom_days=% total=% dur_days=%',
    p_type, p_package_id, p_custom_days, v_total, v_dur_days;

  -- Insertar anuncio
  INSERT INTO public.advertisements (
    advertiser_id,
    package_id,
    type,
    title,
    subtitle,
    button_text,
    media_url,
    media_type,
    link_type,
    link_id,
    target_location_type,
    target_locations,
    duration_seconds,
    youtube_url,
    custom_days,
    total_price,
    effective_price,
    status,
    starts_at,
    ends_at
  ) VALUES (
    v_user_id,
    p_package_id,
    p_type,
    p_title,
    p_subtitle,
    COALESCE(p_button_text, 'Contratar'),
    p_media_url,
    COALESCE(p_media_type, 'none'),
    CASE WHEN p_type = 'sponsored_group' THEN 'group'
         ELSE COALESCE(p_link_type, 'none') END,
    CASE WHEN p_type = 'sponsored_group' THEN v_group_id
         ELSE p_link_id END,
    COALESCE(p_location_type, 'national'),
    p_locations,
    p_duration_seconds,
    CASE WHEN COALESCE(p_link_type, 'none') = 'video' THEN p_youtube_url ELSE NULL END,
    p_custom_days,
    v_total,
    v_total,   -- effective_price: leído por create-ad-payment edge function
    'pending_review',
    NOW(),
    NOW() + (v_dur_days || ' days')::INTERVAL
  )
  RETURNING id INTO v_ad_id;

  -- Para sponsored_group: registrar en sponsored_groups (inactivo hasta que admin apruebe)
  IF p_type = 'sponsored_group' AND v_group_id IS NOT NULL THEN
    INSERT INTO public.sponsored_groups (
      group_id, advertiser_id, package_id,
      starts_at, ends_at, is_active
    ) VALUES (
      v_group_id, v_user_id, p_package_id,
      NOW(), NOW() + (v_dur_days || ' days')::INTERVAL,
      false
    ) ON CONFLICT DO NOTHING;
  END IF;

  RETURN jsonb_build_object(
    'ok',       true,
    'ad_id',    v_ad_id,
    'amount',   v_total,
    'type',     p_type,
    'group_id', v_group_id
  );

EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$$;

GRANT EXECUTE ON FUNCTION public.create_advertisement_order(
  TEXT,TEXT,TEXT,TEXT,TEXT,TEXT,UUID,TEXT,UUID,TEXT,JSONB,INT,TEXT,INT,NUMERIC
) TO authenticated;

-- ── 4. Verificación ───────────────────────────────────────────────────────────

SELECT proname, pronargs, proargnames
FROM   pg_proc
WHERE  proname = 'create_advertisement_order'
  AND  pronamespace = (SELECT oid FROM pg_namespace WHERE nspname = 'public');

SELECT '162_fix_create_ad_order_final.sql ejecutado ✅' AS status;
