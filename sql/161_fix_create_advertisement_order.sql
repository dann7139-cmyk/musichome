-- ════════════════════════════════════════════════════════════════════════════
-- 161_fix_create_advertisement_order.sql
-- Alinea la firma de create_advertisement_order con lo que envía el frontend.
--
-- Parámetros que el frontend envía (CreateAdvertisementScreen handlePay):
--   p_type, p_title, p_subtitle, p_button_text,
--   p_media_url, p_media_type,
--   p_package_id,
--   p_link_type, p_link_id,
--   p_location_type, p_locations (JSONB),
--   p_duration_seconds, p_youtube_url,
--   p_custom_days,
--   p_total_price   ← precio final calculado por calcFinalPrice() en UI
--
-- El DB NO recalcula el precio: usa p_total_price directamente como
-- effective_price para que la edge function create-ad-payment lo lea.
-- ════════════════════════════════════════════════════════════════════════════

-- ── 1. Columnas adicionales en advertisements ─────────────────────────────────

ALTER TABLE public.advertisements
  ADD COLUMN IF NOT EXISTS location_type        TEXT    DEFAULT 'national',
  ADD COLUMN IF NOT EXISTS locations            JSONB,          -- ciudades seleccionadas
  ADD COLUMN IF NOT EXISTS duration_seconds     INT,            -- duración de video
  ADD COLUMN IF NOT EXISTS youtube_url          TEXT,
  ADD COLUMN IF NOT EXISTS custom_days          INT,
  ADD COLUMN IF NOT EXISTS custom_price_per_day NUMERIC(10,2),  -- reservado, no usado por v161
  ADD COLUMN IF NOT EXISTS total_price          NUMERIC(10,2);  -- precio final enviado por UI

-- ── 2. Drop todas las firmas previas de la función ───────────────────────────
-- Necesario porque PostgreSQL diferencia por tipos de parámetros.

-- sql/119
DROP FUNCTION IF EXISTS public.create_advertisement_order(TEXT,TEXT,TEXT,TEXT,TEXT,TEXT,UUID,UUID,TEXT,TEXT,TEXT);
DROP FUNCTION IF EXISTS public.create_advertisement_order(TEXT,TEXT,TEXT,TEXT,TEXT,TEXT,UUID,UUID,TEXT,TEXT);
-- sql/124
DROP FUNCTION IF EXISTS public.create_advertisement_order(TEXT,TEXT,TEXT,TEXT,TEXT,TEXT,UUID,TEXT,TEXT,JSONB,INT,TEXT,INT,NUMERIC);
-- sql/140: p_type,p_title,p_subtitle,p_button_text,p_media_url,p_media_type,
--          p_package_id,p_target_group_id,p_link_type,p_link_url,p_button_url,
--          p_location_type,p_locations,p_custom_days,p_custom_price_per_day,
--          p_duration_seconds,p_youtube_url
DROP FUNCTION IF EXISTS public.create_advertisement_order(TEXT,TEXT,TEXT,TEXT,TEXT,TEXT,UUID,UUID,TEXT,TEXT,TEXT,TEXT,JSONB,INT,NUMERIC,INT,TEXT);

-- ── 3. Función actualizada ────────────────────────────────────────────────────
-- Firma: TEXT×7, UUID×2, TEXT, JSONB, INT, TEXT, INT, NUMERIC
-- El último parámetro pasó de p_custom_price_per_day a p_total_price.
-- CREATE OR REPLACE funciona porque la firma de tipos es idéntica.

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
  p_total_price      NUMERIC  DEFAULT NULL   -- precio final calculado en UI, sin recalcular
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
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_type');
  END IF;

  -- Validar paquete si se especifica
  IF p_package_id IS NOT NULL THEN
    SELECT * INTO v_pkg FROM public.ad_packages
    WHERE id = p_package_id AND is_active = true;
    IF NOT FOUND THEN
      RETURN jsonb_build_object('ok', false, 'error', 'package_not_found');
    END IF;
    IF v_pkg.type != p_type THEN
      RETURN jsonb_build_object('ok', false, 'error', 'package_type_mismatch');
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

  -- ── Precio: usar exactamente lo que calculó el frontend ──────────────────
  -- NO se recalcula. effective_price = p_total_price.
  v_total := COALESCE(p_total_price, 0);

  -- ── Duración: del paquete o de los días personalizados ──────────────────
  IF v_pkg.id IS NOT NULL THEN
    v_dur_days := COALESCE(v_pkg.duration_days, 7);
  ELSIF p_custom_days IS NOT NULL THEN
    v_dur_days := p_custom_days;
  ELSE
    v_dur_days := 7;
  END IF;

  RAISE NOTICE '[create_advertisement_order] type=% pkg=% custom_days=% total_price(UI)=% dur_days=%',
    p_type, p_package_id, p_custom_days, v_total, v_dur_days;

  -- ── Insertar anuncio ─────────────────────────────────────────────────────
  -- effective_price = v_total  →  leído por create-ad-payment edge function sin recalcular
  INSERT INTO public.advertisements (
    advertiser_id, package_id, type,
    title, subtitle, button_text,
    media_url, media_type,
    link_type, link_id,
    location_type, locations,
    duration_seconds, youtube_url,
    custom_days, total_price, effective_price,
    status
  ) VALUES (
    v_user_id,
    p_package_id,
    p_type,
    p_title,
    p_subtitle,
    COALESCE(p_button_text, 'Contratar'),
    p_media_url,
    COALESCE(p_media_type, 'none'),
    CASE WHEN p_type = 'sponsored_group' THEN 'group' ELSE COALESCE(p_link_type, 'none') END,
    CASE WHEN p_type = 'sponsored_group' THEN v_group_id ELSE p_link_id END,
    COALESCE(p_location_type, 'national'),
    p_locations,
    p_duration_seconds,
    p_youtube_url,
    p_custom_days,
    v_total,   -- total_price
    v_total,   -- effective_price: leído por create-ad-payment
    'pending_review'
  )
  RETURNING id INTO v_ad_id;

  -- Para sponsored_group: crear registro en sponsored_groups (inactivo hasta aprobar)
  IF p_type = 'sponsored_group' AND v_group_id IS NOT NULL AND v_dur_days > 0 THEN
    INSERT INTO public.sponsored_groups (
      group_id, advertiser_id, package_id,
      starts_at, ends_at, is_active
    ) VALUES (
      v_group_id, v_user_id, p_package_id,
      now(), now() + (v_dur_days || ' days')::INTERVAL,
      false
    );
  END IF;

  RETURN jsonb_build_object(
    'ok',       true,
    'ad_id',    v_ad_id,
    'amount',   v_total,
    'type',     p_type,
    'group_id', v_group_id
  );
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

SELECT '161_fix_create_advertisement_order.sql ejecutado ✅' AS status;
