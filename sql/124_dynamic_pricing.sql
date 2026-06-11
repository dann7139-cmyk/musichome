-- ════════════════════════════════════════════════════════════════════════════
-- 124_dynamic_pricing.sql
-- Sistema de precios dinámicos por demanda.
--
--   1. effective_price en advertisements   — precio final cobrado
--   2. get_demand_info(p_city)             — score, nivel, multiplicador
--   3. create_advertisement_order()        — calcula effective_price al crear
--
-- Lógica de demanda por ciudad:
--   demand_score = ads_activos + sponsored_activos×2 + boosts_activos
--
--   score 0-2  → baja  → ×1.0  → "Precio especial disponible"
--   score 3-7  → media → ×1.5  → ""  (precio normal)
--   score ≥8   → alta  → ×2.0  → "Alta demanda en tu zona"
--
-- Compatibilidad: anuncios existentes mantienen effective_price = NULL
-- (el pago usa el precio del paquete como antes).
--
-- Ejecutar DESPUÉS de 123_ad_location_targeting.sql
-- ════════════════════════════════════════════════════════════════════════════


-- ── 1. effective_price en advertisements ─────────────────────────────────────

ALTER TABLE public.advertisements
  ADD COLUMN IF NOT EXISTS effective_price NUMERIC(10,2);

-- NULL = sin precio dinámico (anuncios existentes), usa pkg.price como antes


-- ── 2. get_demand_info ────────────────────────────────────────────────────────
-- Devuelve el nivel de demanda y multiplicador de precio para una ciudad.
-- Si p_city es NULL calcula demanda global (todos los anuncios).

DROP FUNCTION IF EXISTS public.get_demand_info(TEXT);
CREATE OR REPLACE FUNCTION public.get_demand_info(p_city TEXT DEFAULT NULL)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER STABLE
SET search_path = public
AS $$
DECLARE
  v_active_ads      INT := 0;
  v_active_sponsored INT := 0;
  v_active_boosts   INT := 0;
  v_demand_score    INT;
  v_demand_level    TEXT;
  v_multiplier      NUMERIC;
  v_message         TEXT;
BEGIN
  -- Anuncios banner/profile activos en esta ciudad
  SELECT COUNT(*) INTO v_active_ads
  FROM   public.advertisements a
  WHERE  a.status = 'active'
    AND  a.type   IN ('banner_home', 'profile_ad')
    AND  (
      a.target_location_type IS NULL
      OR a.target_location_type = 'national'
      OR p_city IS NULL
      OR (a.target_locations IS NOT NULL
          AND a.target_locations @> jsonb_build_array(p_city))
    );

  -- Grupos patrocinados activos en la ciudad
  SELECT COUNT(*) INTO v_active_sponsored
  FROM   public.sponsored_groups sg
  JOIN   public.groups           g ON g.id = sg.group_id
  WHERE  sg.is_active = true
    AND  sg.ends_at   > now()
    AND  (p_city IS NULL OR g.city ILIKE p_city);

  -- Grupos con boost activo en la ciudad
  SELECT COUNT(*) INTO v_active_boosts
  FROM   public.groups g
  WHERE  g.boost_score > 0
    AND  g.boost_ends_at > now()
    AND  (p_city IS NULL OR g.city ILIKE p_city);

  -- Calcular score compuesto
  v_demand_score := v_active_ads + (v_active_sponsored * 2) + v_active_boosts;

  -- Determinar nivel y multiplicador
  IF v_demand_score >= 8 THEN
    v_demand_level := 'high';
    v_multiplier   := 2.0;
    v_message      := 'Alta demanda en tu zona';
  ELSIF v_demand_score >= 3 THEN
    v_demand_level := 'medium';
    v_multiplier   := 1.5;
    v_message      := '';
  ELSE
    v_demand_level := 'low';
    v_multiplier   := 1.0;
    v_message      := 'Precio especial disponible';
  END IF;

  RETURN jsonb_build_object(
    'demand_score',      v_demand_score,
    'demand_level',      v_demand_level,
    'multiplier',        v_multiplier,
    'message',           v_message,
    'active_ads',        v_active_ads,
    'active_sponsored',  v_active_sponsored,
    'active_boosts',     v_active_boosts
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.get_demand_info(TEXT) TO anon, authenticated;


-- ── 3. create_advertisement_order — calcula effective_price ──────────────────
-- La función ya acepta p_location_type y p_locations (123).
-- Aquí la reemplazamos para añadir el cálculo de effective_price.
-- El precio se calcula basado en la primera ciudad de p_locations (o global).

DROP FUNCTION IF EXISTS public.create_advertisement_order(TEXT,TEXT,TEXT,TEXT,TEXT,TEXT,UUID,UUID,TEXT,TEXT,TEXT,TEXT,JSONB);
CREATE OR REPLACE FUNCTION public.create_advertisement_order(
  p_type              TEXT,
  p_title             TEXT,
  p_subtitle          TEXT         DEFAULT NULL,
  p_button_text       TEXT         DEFAULT 'Contactar',
  p_media_url         TEXT         DEFAULT NULL,
  p_media_type        TEXT         DEFAULT 'none',
  p_package_id        UUID         DEFAULT NULL,
  p_target_group_id   UUID         DEFAULT NULL,
  p_link_type         TEXT         DEFAULT 'none',
  p_link_url          TEXT         DEFAULT NULL,
  p_button_url        TEXT         DEFAULT NULL,
  p_location_type     TEXT         DEFAULT 'national',
  p_locations         JSONB        DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_user_id        UUID    := auth.uid();
  v_ad_id          UUID;
  v_group_id       UUID;
  v_pkg            RECORD;
  v_loc_type       TEXT;
  v_demand_city    TEXT;
  v_demand         JSONB;
  v_multiplier     NUMERIC := 1.0;
  v_effective_price NUMERIC;
BEGIN
  IF v_user_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'no_session');
  END IF;

  IF p_type NOT IN ('banner_home', 'sponsored_group', 'profile_ad') THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_type');
  END IF;

  v_loc_type := COALESCE(NULLIF(p_location_type, ''), 'national');

  -- Validar paquete
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

  -- Para sponsored_group: resolver grupo del anunciante
  IF p_type = 'sponsored_group' THEN
    SELECT id INTO v_group_id FROM public.groups
    WHERE owner_id = v_user_id LIMIT 1;
    IF NOT FOUND THEN
      RETURN jsonb_build_object('ok', false, 'error', 'group_not_found');
    END IF;
  END IF;

  -- ── Precio dinámico ───────────────────────────────────────────────────────
  -- Extraer la ciudad principal para calcular demanda
  IF v_loc_type IN ('city', 'multi_city') AND p_locations IS NOT NULL THEN
    v_demand_city := p_locations ->> 0;
  END IF;
  -- v_demand_city = NULL para 'national' → get_demand_info devuelve demanda global

  IF v_pkg.price IS NOT NULL THEN
    SELECT public.get_demand_info(v_demand_city) INTO v_demand;
    v_multiplier      := COALESCE((v_demand->>'multiplier')::NUMERIC, 1.0);
    v_effective_price := CEIL(v_pkg.price * v_multiplier);
  END IF;

  -- Insertar anuncio
  INSERT INTO public.advertisements (
    advertiser_id, package_id, type,
    title, subtitle, button_text, button_url,
    media_url, media_type,
    link_type, link_id, link_url,
    target_group_id,
    target_location_type, target_locations,
    effective_price,
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
    v_effective_price,
    'pending_review'
  )
  RETURNING id INTO v_ad_id;

  -- Para sponsored_group: crear registro en sponsored_groups (inactivo hasta aprobar)
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
    'amount',         COALESCE(v_effective_price, v_pkg.price, 0),
    'base_price',     COALESCE(v_pkg.price, 0),
    'multiplier',     v_multiplier,
    'type',           p_type,
    'group_id',       v_group_id,
    'location_type',  v_loc_type,
    'demand_level',   COALESCE(v_demand->>'demand_level', 'low')
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.create_advertisement_order(TEXT,TEXT,TEXT,TEXT,TEXT,TEXT,UUID,UUID,TEXT,TEXT,TEXT,TEXT,JSONB) TO authenticated;


SELECT '124_dynamic_pricing.sql ejecutado ✅' AS status;
SELECT 'effective_price almacenado en cada nuevo anuncio según demanda de la ciudad' AS note;
SELECT 'RPC: get_demand_info(p_city) → demand_level, multiplier, message' AS rpc;
SELECT 'Multiplicadores: low=1.0 | medium=1.5 | high=2.0' AS levels;
