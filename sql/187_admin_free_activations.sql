-- ════════════════════════════════════════════════════════════════════
-- 187_admin_free_activations.sql
--
-- OBJETIVO: Admin puede activar GRATIS sponsored, recommendation
-- y bidding para cualquier grupo — sin formularios, 1 clic.
--
-- Estos NO usan el flujo de advertisements.
-- NO generan wallet_transactions (no afectan métricas de ingresos).
-- El estado es SIEMPRE el del grupo.
--
-- Cambios:
--   1. is_free en bid_orders y recommendation_orders
--   2. admin_activate_sponsored(group_id, days)
--   3. admin_activate_recommendation(group_id, days)
--   4. admin_activate_bidding(group_id, bid_amount, days)
--   5. admin_deactivate_group(group_id, type)
--   6. get_active_recommendations — is_free al final (ORDER BY)
--   7. Anuncios de prueba: 1 banner_home + 1 profile_ad
--
-- Requiere: 186_ads_multi_state.sql
-- ════════════════════════════════════════════════════════════════════


-- ── 1. Columnas is_free ───────────────────────────────────────────────────────

ALTER TABLE public.bid_orders
  ADD COLUMN IF NOT EXISTS is_free BOOLEAN NOT NULL DEFAULT FALSE;

ALTER TABLE public.recommendation_orders
  ADD COLUMN IF NOT EXISTS is_free BOOLEAN NOT NULL DEFAULT FALSE;


-- ── 2. admin_activate_sponsored ──────────────────────────────────────────────
-- Inserta o reactiva en sponsored_groups con is_active=TRUE.

DROP FUNCTION IF EXISTS public.admin_activate_sponsored(UUID, INT);
CREATE OR REPLACE FUNCTION public.admin_activate_sponsored(
  p_group_id UUID,
  p_days     INT DEFAULT 7
)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_role     TEXT := auth.jwt()->'user_metadata'->>'role';
  v_ends_at  TIMESTAMPTZ;
BEGIN
  IF v_role NOT IN ('admin', 'service_role') THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_admin');
  END IF;

  v_ends_at := CASE WHEN p_days > 0
                 THEN NOW() + (p_days || ' days')::INTERVAL
                 ELSE NULL  -- sin límite
               END;

  INSERT INTO public.sponsored_groups (group_id, advertiser_id, starts_at, ends_at, is_active)
  VALUES (p_group_id, auth.uid(), NOW(), v_ends_at, TRUE)
  ON CONFLICT (group_id) DO UPDATE
    SET is_active  = TRUE,
        starts_at  = NOW(),
        ends_at    = v_ends_at,
        updated_at = NOW();

  RAISE NOTICE '[ADMIN_FREE] sponsored activated group=% days=%', p_group_id, p_days;
  RETURN jsonb_build_object('ok', true, 'type', 'sponsored', 'ends_at', v_ends_at);
END;
$$;

GRANT EXECUTE ON FUNCTION public.admin_activate_sponsored(UUID, INT) TO authenticated;


-- ── 3. admin_activate_recommendation ─────────────────────────────────────────
-- Crea recommendation_order con is_free=TRUE, status='paid'.
-- No genera wallet_transactions.

DROP FUNCTION IF EXISTS public.admin_activate_recommendation(UUID, INT);
CREATE OR REPLACE FUNCTION public.admin_activate_recommendation(
  p_group_id UUID,
  p_days     INT DEFAULT 7
)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_role     TEXT := auth.jwt()->'user_metadata'->>'role';
  v_ends_at  TIMESTAMPTZ;
  v_city     TEXT;
  v_state    TEXT;
  v_order_id UUID;
BEGIN
  IF v_role NOT IN ('admin', 'service_role') THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_admin');
  END IF;

  SELECT normalize_state_name(state), city
  INTO   v_state, v_city
  FROM   public.groups
  WHERE  id = p_group_id;

  v_ends_at := CASE WHEN p_days > 0
                 THEN NOW() + (p_days || ' days')::INTERVAL
                 ELSE NULL
               END;

  INSERT INTO public.recommendation_orders
    (group_id, amount, duration_days, status, is_free, city, state, starts_at, ends_at)
  VALUES
    (p_group_id, 0, p_days, 'paid', TRUE, v_city, v_state, NOW(), v_ends_at)
  RETURNING id INTO v_order_id;

  RAISE NOTICE '[ADMIN_FREE] recommendation activated group=% order=% days=%', p_group_id, v_order_id, p_days;
  RETURN jsonb_build_object('ok', true, 'type', 'recommendation', 'order_id', v_order_id, 'ends_at', v_ends_at);
END;
$$;

GRANT EXECUTE ON FUNCTION public.admin_activate_recommendation(UUID, INT) TO authenticated;


-- ── 4. admin_activate_bidding ─────────────────────────────────────────────────
-- Crea bid_order con is_free=TRUE, status='paid'.
-- No genera wallet_transactions.

DROP FUNCTION IF EXISTS public.admin_activate_bidding(UUID, NUMERIC, INT);
CREATE OR REPLACE FUNCTION public.admin_activate_bidding(
  p_group_id   UUID,
  p_bid_amount NUMERIC DEFAULT 100,
  p_days       INT     DEFAULT 7
)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_role     TEXT := auth.jwt()->'user_metadata'->>'role';
  v_ends_at  TIMESTAMPTZ;
  v_state    TEXT;
  v_order_id UUID;
BEGIN
  IF v_role NOT IN ('admin', 'service_role') THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_admin');
  END IF;

  SELECT normalize_state_name(state) INTO v_state
  FROM   public.groups
  WHERE  id = p_group_id;

  v_ends_at := CASE WHEN p_days > 0
                 THEN NOW() + (p_days || ' days')::INTERVAL
                 ELSE NULL
               END;

  INSERT INTO public.bid_orders
    (group_id, amount, duration_days, status, is_free, state, starts_at, ends_at)
  VALUES
    (p_group_id, p_bid_amount, p_days, 'paid', TRUE, v_state, NOW(), v_ends_at)
  RETURNING id INTO v_order_id;

  RAISE NOTICE '[ADMIN_FREE] bidding activated group=% order=% amount=% days=%', p_group_id, v_order_id, p_bid_amount, p_days;
  RETURN jsonb_build_object('ok', true, 'type', 'bidding', 'order_id', v_order_id, 'ends_at', v_ends_at);
END;
$$;

GRANT EXECUTE ON FUNCTION public.admin_activate_bidding(UUID, NUMERIC, INT) TO authenticated;


-- ── 5. admin_deactivate_group ─────────────────────────────────────────────────
-- Desactiva/expira la activación libre de un grupo.
-- type: 'sponsored' | 'recommendation' | 'bidding'

DROP FUNCTION IF EXISTS public.admin_deactivate_group(UUID, TEXT);
CREATE OR REPLACE FUNCTION public.admin_deactivate_group(
  p_group_id UUID,
  p_type     TEXT   -- 'sponsored' | 'recommendation' | 'bidding'
)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_role TEXT := auth.jwt()->'user_metadata'->>'role';
BEGIN
  IF v_role NOT IN ('admin', 'service_role') THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_admin');
  END IF;

  IF p_type = 'sponsored' THEN
    UPDATE public.sponsored_groups
    SET is_active = FALSE, ends_at = NOW()
    WHERE group_id = p_group_id AND is_active = TRUE;

  ELSIF p_type = 'recommendation' THEN
    UPDATE public.recommendation_orders
    SET status = 'expired', ends_at = NOW()
    WHERE group_id = p_group_id AND is_free = TRUE AND status = 'paid';

  ELSIF p_type = 'bidding' THEN
    UPDATE public.bid_orders
    SET status = 'expired', ends_at = NOW()
    WHERE group_id = p_group_id AND is_free = TRUE AND status = 'paid';

  ELSE
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_type');
  END IF;

  RETURN jsonb_build_object('ok', true, 'type', p_type, 'group_id', p_group_id);
END;
$$;

GRANT EXECUTE ON FUNCTION public.admin_deactivate_group(UUID, TEXT) TO authenticated;


-- ── 6. get_active_recommendations — is_free al final ─────────────────────────
-- Los gratuitos aparecen DESPUÉS de los pagados (protege ingresos).

DROP FUNCTION IF EXISTS public.get_active_recommendations(TEXT, TEXT, INT);
CREATE OR REPLACE FUNCTION public.get_active_recommendations(
  p_city  TEXT DEFAULT NULL,
  p_state TEXT DEFAULT NULL,
  p_limit INT  DEFAULT 10
)
RETURNS TABLE (id UUID, name TEXT, city TEXT, state TEXT, is_free BOOLEAN)
LANGUAGE plpgsql SECURITY DEFINER STABLE
SET search_path = public
AS $$
BEGIN
  RETURN QUERY
  SELECT
    g.id,
    g.name,
    g.city,
    g.state,
    ro.is_free
  FROM   public.recommendation_orders ro
  JOIN   public.groups g ON g.id = ro.group_id
  WHERE  ro.status = 'paid'
    AND  g.is_active = TRUE
    AND  (ro.ends_at IS NULL OR ro.ends_at > NOW())
    AND  (p_city  IS NULL OR g.city  = p_city)
    AND  (p_state IS NULL OR normalize_state_name(g.state) = normalize_state_name(p_state))
  ORDER BY
    ro.is_free ASC,         -- pagados primero (FALSE < TRUE)
    ro.amount  DESC,
    ro.created_at DESC
  LIMIT p_limit;
END;
$$;

GRANT EXECUTE ON FUNCTION public.get_active_recommendations(TEXT, TEXT, INT) TO anon, authenticated;


-- ── 7. Anuncios de prueba ─────────────────────────────────────────────────────
-- Ejecutar estos INSERTs para ver cómo se ven banner_home y profile_ad.
-- REEMPLAZA las URLs con tus imágenes reales.

-- Test banner_home (aparece en el carousel del HomeScreen)
INSERT INTO public.advertisements (
  advertiser_id,
  type,
  title,
  subtitle,
  button_text,
  media_url,
  media_type,
  status,
  is_free,
  target_location_type,
  starts_at,
  ends_at,
  order_index
) VALUES (
  public.get_platform_admin_id(),
  'banner_home',
  'Test Banner 1',
  'Subtítulo del banner de prueba',
  'Ver más',
  -- ⬇ REEMPLAZA con tu URL de imagen (1200×628px recomendado)
  'https://picsum.photos/seed/banner1/1200/628',
  'image',
  'active',
  TRUE,
  'national',
  NOW(),
  NOW() + INTERVAL '90 days',
  1
),
(
  public.get_platform_admin_id(),
  'banner_home',
  'Test Banner 2',
  'Segundo banner para ver rotación',
  'Contratar',
  -- ⬇ REEMPLAZA con tu segunda imagen
  'https://picsum.photos/seed/banner2/1200/628',
  'image',
  'active',
  TRUE,
  'national',
  NOW(),
  NOW() + INTERVAL '90 days',
  2
);

-- Test profile_ad (aparece dentro del perfil del grupo en GroupDetailScreen)
INSERT INTO public.advertisements (
  advertiser_id,
  type,
  title,
  subtitle,
  button_text,
  media_url,
  media_type,
  status,
  is_free,
  target_location_type,
  starts_at,
  ends_at,
  order_index
) VALUES (
  public.get_platform_admin_id(),
  'profile_ad',
  'Test Anuncio en Perfil',
  'Este anuncio aparece en el perfil del grupo',
  'Ver oferta',
  -- ⬇ REEMPLAZA con tu imagen de perfil (cuadrada o 16:9)
  'https://picsum.photos/seed/profilead/800/450',
  'image',
  'active',
  TRUE,
  'national',
  NOW(),
  NOW() + INTERVAL '90 days',
  1
);


-- ── Verificación ──────────────────────────────────────────────────────────────

SELECT type, title, status, is_free, ends_at
FROM public.advertisements
WHERE status = 'active'
ORDER BY type, is_free, created_at DESC
LIMIT 10;

SELECT '187_admin_free_activations.sql ejecutado ✅' AS status;
