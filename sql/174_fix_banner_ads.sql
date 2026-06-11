-- ════════════════════════════════════════════════════════════════════
-- 174_fix_banner_ads.sql
-- 1. Inserta anuncio banner_home de DEMOSTRACIÓN (visible en panel admin)
-- 2. Inserta un anuncio profile_ad de demostración extra
-- 3. Asegura wallet del admin con los ingresos correspondientes
-- 4. Actualiza get_groups_ranked_by_city para retornar price_from
--
-- Seguro: usa WHERE NOT EXISTS / ON CONFLICT — no duplica.
-- Ejecutar en Supabase SQL Editor (después de 173_demo_ads_and_wallet.sql).
-- ════════════════════════════════════════════════════════════════════

DO $$
DECLARE
  v_admin_id UUID;
  v_group_id UUID;
  v_banner_id UUID;
  v_profile_ad_id UUID;
BEGIN

  -- ── Obtener admin y grupo activo ────────────────────────────────────────
  SELECT id INTO v_admin_id FROM public.profiles WHERE role = 'admin' LIMIT 1;
  SELECT id INTO v_group_id FROM public.groups WHERE is_active = true LIMIT 1;

  IF v_admin_id IS NULL THEN
    RAISE NOTICE '174: No hay usuario admin — abortando';
    RETURN;
  END IF;

  -- Asegurar wallet del admin
  INSERT INTO public.wallets (user_id)
  VALUES (v_admin_id)
  ON CONFLICT (user_id) DO NOTHING;

  -- ── 1. Anuncio Banner Home activo ───────────────────────────────────────
  INSERT INTO public.advertisements (
    type,
    title,
    subtitle,
    tag,
    button_text,
    link_type,
    link_id,
    status,
    starts_at,
    ends_at,
    advertiser_id,
    order_index
  )
  SELECT
    'banner_home',
    'SONEXUS — Música en Vivo para tu Evento',
    'Orquestas, DJs, Mariachis y más · Reserva fácil y seguro',
    'DESTÁCATE',
    'Ver grupos',
    CASE WHEN v_group_id IS NOT NULL THEN 'group' ELSE 'none' END,
    v_group_id,
    'active',
    NOW(),
    NOW() + INTERVAL '30 days',
    v_admin_id,
    0
  WHERE NOT EXISTS (
    SELECT 1 FROM public.advertisements
    WHERE type = 'banner_home'
      AND advertiser_id = v_admin_id
      AND status = 'active'
  )
  RETURNING id INTO v_banner_id;

  IF v_banner_id IS NOT NULL THEN
    -- Ingreso en billetera por el banner
    INSERT INTO public.wallet_transactions
      (user_id, amount, type, status, reference_id, description)
    SELECT
      v_admin_id, 899, 'ad_income', 'completed',
      'demo_banner_' || v_banner_id::TEXT,
      'Banner Home (demo): 30 días · SONEXUS'
    WHERE NOT EXISTS (
      SELECT 1 FROM public.wallet_transactions
      WHERE reference_id = 'demo_banner_' || v_banner_id::TEXT
    );

    UPDATE public.wallets
    SET available_balance = available_balance + 899,
        total_earned      = total_earned      + 899,
        updated_at        = NOW()
    WHERE user_id = v_admin_id
      AND NOT EXISTS (
        SELECT 1 FROM public.wallet_transactions
        WHERE reference_id = 'demo_banner_' || v_banner_id::TEXT
          AND created_at < NOW() - INTERVAL '1 second'
      );

    RAISE NOTICE '174: banner_home insertado — id=%', v_banner_id;
  ELSE
    RAISE NOTICE '174: banner_home ya existe — saltado';
  END IF;


  -- ── 2. Anuncio Profile Ad (visible en perfiles de grupo) ────────────────
  -- Aseguramos que exista AL MENOS uno activo sin target_group_id
  -- (aparece en todos los perfiles)
  INSERT INTO public.advertisements (
    type,
    title,
    subtitle,
    tag,
    button_text,
    link_type,
    link_id,
    status,
    starts_at,
    ends_at,
    advertiser_id,
    order_index
  )
  SELECT
    'profile_ad',
    'MusicHome Premium',
    'Anuncio de perfil destacado · Llega a más clientes',
    'PUBLICIDAD',
    'Ver más',
    CASE WHEN v_group_id IS NOT NULL THEN 'group' ELSE 'none' END,
    v_group_id,
    'active',
    NOW(),
    NOW() + INTERVAL '7 days',
    v_admin_id,
    0
  WHERE NOT EXISTS (
    SELECT 1 FROM public.advertisements
    WHERE type        = 'profile_ad'
      AND status      = 'active'
      AND (ends_at IS NULL OR ends_at > NOW())
  )
  RETURNING id INTO v_profile_ad_id;

  IF v_profile_ad_id IS NOT NULL THEN
    INSERT INTO public.wallet_transactions
      (user_id, amount, type, status, reference_id, description)
    SELECT
      v_admin_id, 250, 'ad_income', 'completed',
      'demo_profad_' || v_profile_ad_id::TEXT,
      'Anuncio Perfil (demo): 7 días'
    WHERE NOT EXISTS (
      SELECT 1 FROM public.wallet_transactions
      WHERE reference_id = 'demo_profad_' || v_profile_ad_id::TEXT
    );

    UPDATE public.wallets
    SET available_balance = available_balance + 250,
        total_earned      = total_earned      + 250,
        updated_at        = NOW()
    WHERE user_id = v_admin_id
      AND NOT EXISTS (
        SELECT 1 FROM public.wallet_transactions
        WHERE reference_id = 'demo_profad_' || v_profile_ad_id::TEXT
          AND created_at < NOW() - INTERVAL '1 second'
      );

    RAISE NOTICE '174: profile_ad insertado — id=%', v_profile_ad_id;
  ELSE
    RAISE NOTICE '174: profile_ad activo ya existe — saltado';
  END IF;

END $$;


-- ── Actualizar get_groups_ranked_by_city para incluir price_from ──────────────
-- Necesario para que las tarjetas de grupo muestren el precio "Desde $X"

DROP FUNCTION IF EXISTS public.get_groups_ranked_by_city(TEXT, INT);
CREATE OR REPLACE FUNCTION public.get_groups_ranked_by_city(
  p_city  TEXT,
  p_limit INT DEFAULT 60
)
RETURNS TABLE (
  id                    UUID,
  name                  TEXT,
  genre                 TEXT,
  city                  TEXT,
  service_cities        JSONB,
  profile_image         TEXT,
  photo_status          TEXT,
  price_from            NUMERIC,
  rating                NUMERIC,
  total_reviews         INT,
  is_verified           BOOLEAN,
  verification_status   TEXT,
  is_active             BOOLEAN,
  puntos_reputacion     INT,
  bid_amount            NUMERIC,
  bid_ends_at           TIMESTAMPTZ,
  boost_score           INT,
  boost_ends_at         TIMESTAMPTZ,
  trust_score           NUMERIC,
  search_penalty        NUMERIC,
  is_high_demand        BOOLEAN,
  recent_completions    INT,
  bid_active            BOOLEAN,
  is_local              BOOLEAN
)
LANGUAGE plpgsql
SECURITY DEFINER STABLE
SET search_path = public
AS $$
DECLARE
  v_city_norm TEXT := CASE WHEN p_city IS NULL THEN NULL
                           ELSE normalize_city_name(p_city) END;
BEGIN
  RETURN QUERY
  SELECT
    g.id,
    g.name,
    g.genre,
    g.city,
    COALESCE(g.service_cities, '[]'::JSONB),
    g.profile_image,
    g.photo_status,
    g.price_from,
    g.rating,
    g.total_reviews,
    g.is_verified,
    g.verification_status,
    g.is_active,
    COALESCE(g.puntos_reputacion, 0)::INT,
    COALESCE(g.bid_amount,   0::NUMERIC),
    g.bid_ends_at,
    COALESCE(g.boost_score,  0)::INT,
    g.boost_ends_at,
    COALESCE(g.trust_score,  0::NUMERIC),
    COALESCE(g.search_penalty, 0::NUMERIC),
    COALESCE(g.is_high_demand, false),
    COALESCE(g.recent_completions, 0)::INT,
    (
      g.bid_ends_at IS NOT NULL
      AND g.bid_ends_at > now()
      AND COALESCE(g.bid_amount, 0) > 0
    ) AS bid_active,
    (v_city_norm IS NULL OR normalize_city_name(g.city) = v_city_norm) AS is_local
  FROM public.groups g
  WHERE g.is_active = true
    AND (
      v_city_norm IS NULL
      OR normalize_city_name(g.city) = v_city_norm
      OR EXISTS (
        SELECT 1
        FROM jsonb_array_elements_text(COALESCE(g.service_cities, '[]'::JSONB)) sc(city_name)
        WHERE normalize_city_name(sc.city_name) = v_city_norm
      )
    )
  ORDER BY
    (v_city_norm IS NULL OR normalize_city_name(g.city) = v_city_norm) DESC,
    (g.bid_ends_at IS NOT NULL AND g.bid_ends_at > now()
      AND COALESCE(g.bid_amount, 0) > 0) DESC,
    COALESCE(g.bid_amount, 0) DESC,
    COALESCE(g.boost_score, 0) DESC,
    COALESCE(g.rating, 0) DESC,
    COALESCE(g.total_reviews, 0) DESC,
    g.created_at DESC
  LIMIT p_limit;
END;
$$;

GRANT EXECUTE ON FUNCTION public.get_groups_ranked_by_city(TEXT, INT) TO anon, authenticated;


-- ── Verificación ──────────────────────────────────────────────────────────────
SELECT
  type, title, status,
  starts_at::DATE AS inicio,
  ends_at::DATE   AS fin
FROM public.advertisements
WHERE status = 'active'
ORDER BY type, created_at DESC;

SELECT
  type, COUNT(*) AS total, SUM(amount) AS ingreso
FROM public.wallet_transactions
WHERE type IN ('ad_income', 'bid_income', 'recommendation_income')
  AND status = 'completed'
GROUP BY type;

SELECT '174_fix_banner_ads.sql ejecutado ✅' AS status;
