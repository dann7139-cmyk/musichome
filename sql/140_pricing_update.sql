-- ════════════════════════════════════════════════════════════════════════════
-- 140_pricing_update.sql
-- Actualiza precios de paquetes publicitarios, agrega multiplicador de alcance
-- geográfico al precio dinámico y habilita modo personalizado (sin paquete fijo).
--
--  Fórmula final:
--    effective_price = CEIL(precio_base × demanda × alcance)
--
--  Multiplicadores de alcance:
--    ciudad          → ×1.0
--    varias ciudades → ×1.5
--    nacional        → ×2.0
--
-- Ejecutar DESPUÉS de 139_*.sql (o el último archivo existente)
-- ════════════════════════════════════════════════════════════════════════════


-- ── 1. Actualizar precios de ad_packages ──────────────────────────────────

UPDATE public.ad_packages SET price = 399  WHERE type = 'banner_home'     AND duration_days = 7;
UPDATE public.ad_packages SET price = 699  WHERE type = 'banner_home'     AND duration_days = 14;
UPDATE public.ad_packages SET price = 1199 WHERE type = 'banner_home'     AND duration_days = 30;

UPDATE public.ad_packages SET price = 199  WHERE type = 'sponsored_group' AND duration_days = 3;
UPDATE public.ad_packages SET price = 349  WHERE type = 'sponsored_group' AND duration_days = 7;
UPDATE public.ad_packages SET price = 599  WHERE type = 'sponsored_group' AND duration_days = 15;
UPDATE public.ad_packages SET price = 999  WHERE type = 'sponsored_group' AND duration_days = 30;

UPDATE public.ad_packages SET price = 149  WHERE type = 'profile_ad'      AND duration_days = 7;
UPDATE public.ad_packages SET price = 399  WHERE type = 'profile_ad'      AND duration_days = 30;


-- ── 2. Actualizar bid_packages ────────────────────────────────────────────

UPDATE public.bid_packages SET min_bid = 150 WHERE name = 'Básico';
UPDATE public.bid_packages SET min_bid = 300 WHERE name = 'Medio';
UPDATE public.bid_packages SET min_bid = 600 WHERE name = 'Premium';


-- ── 3. Agregar columna custom_duration_days a advertisements ──────────────
-- Almacena los días cuando el anuncio se crea sin paquete fijo.

ALTER TABLE public.advertisements
  ADD COLUMN IF NOT EXISTS custom_duration_days INT;


-- ── 4. Actualizar place_bid: mínimo absoluto 50 → 100 ────────────────────

DROP FUNCTION IF EXISTS public.place_bid(UUID, NUMERIC, INT);
CREATE OR REPLACE FUNCTION public.place_bid(
  p_package_id    UUID    DEFAULT NULL,
  p_custom_amount NUMERIC DEFAULT NULL,
  p_duration_days INT     DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_user_id  UUID    := auth.uid();
  v_group_id UUID;
  v_pkg      RECORD;
  v_amount   NUMERIC;
  v_days     INT;
  v_ends_at  TIMESTAMPTZ;
BEGIN
  IF v_user_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'no_session');
  END IF;

  SELECT id INTO v_group_id FROM public.groups WHERE owner_id = v_user_id LIMIT 1;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'group_not_found');
  END IF;

  IF p_package_id IS NOT NULL THEN
    SELECT * INTO v_pkg FROM public.bid_packages WHERE id = p_package_id AND is_active = true;
    IF NOT FOUND THEN
      RETURN jsonb_build_object('ok', false, 'error', 'package_not_found');
    END IF;
    v_days   := v_pkg.duration_days;
    v_amount := COALESCE(p_custom_amount, v_pkg.min_bid);
    IF v_amount < v_pkg.min_bid THEN
      RETURN jsonb_build_object('ok', false, 'error', 'bid_below_minimum', 'min_bid', v_pkg.min_bid);
    END IF;
  ELSE
    IF p_custom_amount IS NULL OR p_duration_days IS NULL THEN
      RETURN jsonb_build_object('ok', false, 'error', 'missing_bid_params');
    END IF;
    IF p_custom_amount < 100 THEN                              -- mínimo 100 MXN
      RETURN jsonb_build_object('ok', false, 'error', 'bid_too_low', 'min_bid', 100);
    END IF;
    IF p_duration_days < 1 THEN
      RETURN jsonb_build_object('ok', false, 'error', 'invalid_duration');
    END IF;
    v_amount := p_custom_amount;
    v_days   := p_duration_days;
  END IF;

  v_ends_at := now() + (v_days || ' days')::INTERVAL;

  UPDATE public.groups
  SET
    bid_amount  = CASE
                    WHEN bid_ends_at IS NOT NULL AND bid_ends_at > now()
                    THEN GREATEST(bid_amount, v_amount)
                    ELSE v_amount
                  END,
    bid_ends_at = CASE
                    WHEN bid_ends_at IS NOT NULL AND bid_ends_at > now() AND bid_amount >= v_amount
                    THEN bid_ends_at
                    ELSE v_ends_at
                  END
  WHERE id = v_group_id;

  RETURN jsonb_build_object(
    'ok',            true,
    'group_id',      v_group_id,
    'bid_amount',    v_amount,
    'ends_at',       v_ends_at,
    'duration_days', v_days
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.place_bid(UUID, NUMERIC, INT) TO authenticated;


-- ── 5. Actualizar create_advertisement_order ──────────────────────────────
-- Nuevos parámetros: p_custom_days, p_custom_price_per_day
-- Nueva fórmula:     effective_price = CEIL(base × demanda × alcance)

DROP FUNCTION IF EXISTS public.create_advertisement_order(TEXT,TEXT,TEXT,TEXT,TEXT,TEXT,UUID,UUID,TEXT,TEXT,TEXT,TEXT,JSONB);
DROP FUNCTION IF EXISTS public.create_advertisement_order(TEXT,TEXT,TEXT,TEXT,TEXT,TEXT,UUID,UUID,TEXT,TEXT,TEXT,TEXT,JSONB,INT,NUMERIC);

CREATE OR REPLACE FUNCTION public.create_advertisement_order(
  p_type                 TEXT,
  p_title                TEXT,
  p_subtitle             TEXT         DEFAULT NULL,
  p_button_text          TEXT         DEFAULT 'Contactar',
  p_media_url            TEXT         DEFAULT NULL,
  p_media_type           TEXT         DEFAULT 'none',
  p_package_id           UUID         DEFAULT NULL,
  p_target_group_id      UUID         DEFAULT NULL,
  p_link_type            TEXT         DEFAULT 'none',
  p_link_url             TEXT         DEFAULT NULL,
  p_button_url           TEXT         DEFAULT NULL,
  p_location_type        TEXT         DEFAULT 'national',
  p_locations            JSONB        DEFAULT NULL,
  p_custom_days          INT          DEFAULT NULL,
  p_custom_price_per_day NUMERIC      DEFAULT NULL,
  -- parámetros heredados de versiones anteriores (ignorados, para compatibilidad)
  p_duration_seconds     INT          DEFAULT NULL,
  p_youtube_url          TEXT         DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_user_id         UUID    := auth.uid();
  v_ad_id           UUID;
  v_group_id        UUID;
  v_pkg             RECORD;
  v_loc_type        TEXT;
  v_demand_city     TEXT;
  v_demand          JSONB;
  v_demand_mult     NUMERIC := 1.0;
  v_location_mult   NUMERIC := 1.0;
  v_base_price      NUMERIC;
  v_effective_price NUMERIC;
  v_custom_days_val INT;
BEGIN
  IF v_user_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'no_session');
  END IF;

  IF p_type NOT IN ('banner_home', 'sponsored_group', 'profile_ad') THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_type');
  END IF;

  v_loc_type := COALESCE(NULLIF(p_location_type, ''), 'national');

  -- Multiplicador de alcance geográfico
  v_location_mult := CASE v_loc_type
    WHEN 'city'       THEN 1.0
    WHEN 'multi_city' THEN 1.5
    WHEN 'national'   THEN 2.0
    ELSE 2.0
  END;

  -- Resolver precio base y duración
  IF p_package_id IS NOT NULL THEN
    SELECT * INTO v_pkg FROM public.ad_packages
    WHERE id = p_package_id AND is_active = true;
    IF NOT FOUND THEN
      RETURN jsonb_build_object('ok', false, 'error', 'package_not_found');
    END IF;
    IF v_pkg.type != p_type THEN
      RETURN jsonb_build_object('ok', false, 'error', 'package_type_mismatch');
    END IF;
    v_base_price      := v_pkg.price;
    v_custom_days_val := NULL;

  ELSIF p_custom_days IS NOT NULL AND p_custom_price_per_day IS NOT NULL THEN
    -- Modo personalizado: usuario elige días y precio/día
    IF p_custom_days < 1 THEN
      RETURN jsonb_build_object('ok', false, 'error', 'invalid_custom_days');
    END IF;
    v_base_price      := p_custom_price_per_day * p_custom_days;
    v_custom_days_val := p_custom_days;

  ELSE
    RETURN jsonb_build_object('ok', false, 'error', 'package_or_custom_required');
  END IF;

  -- Para sponsored_group: resolver grupo del anunciante
  IF p_type = 'sponsored_group' THEN
    SELECT id INTO v_group_id FROM public.groups WHERE owner_id = v_user_id LIMIT 1;
    IF NOT FOUND THEN
      RETURN jsonb_build_object('ok', false, 'error', 'group_not_found');
    END IF;
  END IF;

  -- Multiplicador de demanda por ciudad
  IF v_loc_type IN ('city', 'multi_city') AND p_locations IS NOT NULL THEN
    v_demand_city := p_locations ->> 0;
  END IF;
  SELECT public.get_demand_info(v_demand_city) INTO v_demand;
  v_demand_mult     := COALESCE((v_demand->>'multiplier')::NUMERIC, 1.0);
  v_effective_price := CEIL(v_base_price * v_demand_mult * v_location_mult);

  -- Insertar anuncio
  INSERT INTO public.advertisements (
    advertiser_id, package_id, type,
    title, subtitle, button_text, button_url,
    media_url, media_type,
    link_type, link_id, link_url,
    target_group_id,
    target_location_type, target_locations,
    effective_price, custom_duration_days,
    status
  ) VALUES (
    v_user_id, p_package_id, p_type,
    p_title, p_subtitle, p_button_text, p_button_url,
    p_media_url, p_media_type,
    CASE WHEN p_type = 'sponsored_group' THEN 'group' ELSE p_link_type END,
    CASE WHEN p_type = 'sponsored_group' THEN v_group_id ELSE NULL END,
    p_link_url,
    p_target_group_id,
    v_loc_type,
    CASE WHEN v_loc_type = 'national' THEN NULL ELSE p_locations END,
    v_effective_price, v_custom_days_val,
    'pending_review'
  )
  RETURNING id INTO v_ad_id;

  -- Para sponsored_group con paquete: crear entrada en sponsored_groups
  IF p_type = 'sponsored_group' AND v_group_id IS NOT NULL AND v_pkg.duration_days IS NOT NULL THEN
    INSERT INTO public.sponsored_groups (
      group_id, advertiser_id, package_id,
      starts_at, ends_at, is_active
    ) VALUES (
      v_group_id, v_user_id, p_package_id,
      now(), now() + (v_pkg.duration_days || ' days')::INTERVAL,
      false
    ) ON CONFLICT DO NOTHING;
  END IF;

  RETURN jsonb_build_object(
    'ok',             true,
    'ad_id',          v_ad_id,
    'amount',         v_effective_price,
    'base_price',     v_base_price,
    'demand_mult',    v_demand_mult,
    'location_mult',  v_location_mult,
    'type',           p_type,
    'group_id',       v_group_id,
    'location_type',  v_loc_type,
    'demand_level',   COALESCE(v_demand->>'demand_level', 'low')
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.create_advertisement_order(TEXT,TEXT,TEXT,TEXT,TEXT,TEXT,UUID,UUID,TEXT,TEXT,TEXT,TEXT,JSONB,INT,NUMERIC,INT,TEXT) TO authenticated;


-- ── 6. Actualizar approve_ad para usar custom_duration_days ──────────────

DROP FUNCTION IF EXISTS public.approve_ad(UUID, INT);
CREATE OR REPLACE FUNCTION public.approve_ad(
  p_id            UUID,
  p_duration_days INT DEFAULT NULL
)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE v_days INT;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.profiles WHERE id = auth.uid() AND role = 'admin') THEN
    RAISE EXCEPTION 'Unauthorized';
  END IF;

  -- Prioridad: parámetro manual → días custom → días del paquete → 7 por defecto
  SELECT COALESCE(p_duration_days, a.custom_duration_days, ap.duration_days, 7) INTO v_days
  FROM   public.advertisements a
  LEFT JOIN public.ad_packages ap ON ap.id = a.package_id
  WHERE  a.id = p_id;

  UPDATE public.advertisements
  SET    status      = 'active',
         approved_at = now(),
         approved_by = auth.uid(),
         starts_at   = COALESCE(starts_at, now()),
         ends_at     = COALESCE(ends_at,   now() + (v_days || ' days')::INTERVAL),
         updated_at  = now()
  WHERE  id = p_id;
END;
$$;

GRANT EXECUTE ON FUNCTION public.approve_ad(UUID, INT) TO authenticated;


SELECT '140_pricing_update.sql ejecutado ✅' AS status;
SELECT 'ad_packages y bid_packages actualizados con nuevos precios' AS note1;
SELECT 'Fórmula: effective_price = base × demanda × alcance (ciudad×1 / multi×1.5 / nacional×2)' AS note2;
SELECT 'Modo personalizado habilitado: p_custom_days + p_custom_price_per_day' AS note3;
