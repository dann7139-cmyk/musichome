-- ════════════════════════════════════════════════════════════════════
-- 178_normalize_in_rpcs_and_payment_logs.sql
--
-- OBJETIVO:
-- 1. Aplicar normalize_state_name() en las 4 RPCs de búsqueda
--    (get_active_banner_ads, get_profile_ads, get_active_recommendations,
--     get_groups_ranked_by_city) — reemplaza LOWER(TRIM()) inline.
--
-- 2. Agregar RAISE NOTICE de auditoría en las 3 funciones de pago:
--    - confirm_bid_payment     → log + mismatch check
--    - confirm_recommendation_payment → log + mismatch check
--    - mark_ad_payment         → log + mismatch check
--
--    Los RAISE NOTICE aparecen en los logs de Supabase (Database Logs).
--    NO bloquean el flujo. NO cambian la lógica existente.
--
-- Requiere: 177_normalize_state_and_fixes.sql (normalize_state_name)
-- Seguro: DROP FUNCTION IF EXISTS con firma exacta antes de CREATE
-- ════════════════════════════════════════════════════════════════════


-- ════════════════════════════════════════════════════════════════════
-- PARTE 1: normalize_state_name() en RPCs de búsqueda
-- ════════════════════════════════════════════════════════════════════


-- ── 1a. get_active_banner_ads ────────────────────────────────────────────────

DROP FUNCTION IF EXISTS public.get_active_banner_ads(TEXT);
DROP FUNCTION IF EXISTS public.get_active_banner_ads(TEXT, TEXT);

CREATE OR REPLACE FUNCTION public.get_active_banner_ads(
  p_city  TEXT DEFAULT NULL,
  p_state TEXT DEFAULT NULL
)
RETURNS TABLE (
  id               UUID,
  title            TEXT,
  subtitle         TEXT,
  tag              TEXT,
  button_text      TEXT,
  media_url        TEXT,
  media_type       TEXT,
  media_offset     INT,
  link_type        TEXT,
  link_id          UUID,
  duration_seconds INT,
  order_index      INT
)
LANGUAGE plpgsql
SECURITY DEFINER STABLE
SET search_path = public
AS $$
BEGIN
  PERFORM public.expire_advertisements();
  RETURN QUERY
  SELECT
    a.id, a.title, a.subtitle, a.tag, a.button_text,
    a.media_url, a.media_type, a.media_offset,
    a.link_type, a.link_id,
    a.duration_seconds, a.order_index
  FROM   public.advertisements a
  LEFT JOIN public.ad_packages pkg ON pkg.id = a.package_id
  WHERE  a.type   = 'banner_home'
    AND  a.status = 'active'
    AND  (a.starts_at IS NULL OR a.starts_at <= now())
    AND  (a.ends_at   IS NULL OR a.ends_at   >  now())
    -- Filtro de ciudad (legacy)
    AND  (
      a.target_location_type IS NULL
      OR a.target_location_type = 'national'
      OR p_city IS NULL
      OR (a.target_locations IS NOT NULL
          AND a.target_locations @> jsonb_build_array(p_city))
    )
    -- Filtro de estado normalizado
    AND  (
      p_state IS NULL
      OR a.target_state IS NULL
      OR normalize_state_name(a.target_state) = normalize_state_name(p_state)
    )
  ORDER BY
    COALESCE(pkg.price, 0) DESC,
    a.order_index ASC,
    a.starts_at   ASC;
END;
$$;

GRANT EXECUTE ON FUNCTION public.get_active_banner_ads(TEXT, TEXT) TO anon, authenticated;


-- ── 1b. get_profile_ads ──────────────────────────────────────────────────────

DROP FUNCTION IF EXISTS public.get_profile_ads(UUID, TEXT);
DROP FUNCTION IF EXISTS public.get_profile_ads(UUID, TEXT, TEXT);

CREATE OR REPLACE FUNCTION public.get_profile_ads(
  p_group_id UUID,
  p_city     TEXT DEFAULT NULL,
  p_state    TEXT DEFAULT NULL
)
RETURNS TABLE (
  id          UUID,
  title       TEXT,
  subtitle    TEXT,
  button_text TEXT,
  media_url   TEXT,
  media_type  TEXT,
  link_type   TEXT,
  link_id     UUID
)
LANGUAGE plpgsql
SECURITY DEFINER STABLE
SET search_path = public
AS $$
BEGIN
  RETURN QUERY
  SELECT
    a.id, a.title, a.subtitle, a.button_text,
    a.media_url, a.media_type,
    a.link_type, a.link_id
  FROM   public.advertisements a
  WHERE  a.type   = 'profile_ad'
    AND  a.status = 'active'
    AND  (a.target_group_id IS NULL OR a.target_group_id = p_group_id)
    AND  (a.starts_at IS NULL OR a.starts_at <= now())
    AND  (a.ends_at   IS NULL OR a.ends_at   >  now())
    -- Filtro de ciudad (legacy)
    AND  (
      a.target_location_type IS NULL
      OR a.target_location_type = 'national'
      OR p_city IS NULL
      OR (a.target_locations IS NOT NULL
          AND a.target_locations @> jsonb_build_array(p_city))
    )
    -- Filtro de estado normalizado
    AND  (
      p_state IS NULL
      OR a.target_state IS NULL
      OR normalize_state_name(a.target_state) = normalize_state_name(p_state)
    )
  ORDER  BY a.order_index
  LIMIT  1;
END;
$$;

GRANT EXECUTE ON FUNCTION public.get_profile_ads(UUID, TEXT, TEXT) TO authenticated;


-- ── 1c. get_active_recommendations ──────────────────────────────────────────

DROP FUNCTION IF EXISTS public.get_active_recommendations(TEXT, INTEGER);
DROP FUNCTION IF EXISTS public.get_active_recommendations(TEXT, TEXT, INTEGER);

CREATE OR REPLACE FUNCTION public.get_active_recommendations(
  p_city   TEXT    DEFAULT NULL,
  p_state  TEXT    DEFAULT NULL,
  p_limit  INTEGER DEFAULT 10
)
RETURNS TABLE (
  id             UUID,
  name           TEXT,
  genre          TEXT,
  city           TEXT,
  description    TEXT,
  price_from     NUMERIC,
  rating         NUMERIC,
  total_reviews  INT,
  is_verified    BOOLEAN,
  profile_image  TEXT,
  amount         NUMERIC,
  ends_at        TIMESTAMPTZ
)
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public
AS $$
  SELECT
    g.id, g.name, g.genre, g.city, g.description,
    g.price_from, g.rating, g.total_reviews, g.is_verified, g.profile_image,
    ro.amount, ro.ends_at
  FROM public.recommendation_orders ro
  JOIN public.groups g ON g.id = ro.group_id
  WHERE ro.status  = 'paid'
    AND ro.starts_at <= NOW()
    AND ro.ends_at   >  NOW()
    AND g.is_active  = TRUE
    -- Filtro de ciudad normalizado
    AND (p_city IS NULL
         OR normalize_state_name(g.city) = normalize_state_name(p_city))
    -- Filtro de estado normalizado
    AND (
      p_state IS NULL
      OR g.state IS NULL
      OR normalize_state_name(g.state) = normalize_state_name(p_state)
    )
  ORDER BY
    COALESCE(ro.bid_amount, ro.amount) DESC,
    ro.ends_at   DESC,
    ro.starts_at DESC
  LIMIT p_limit;
$$;

GRANT EXECUTE ON FUNCTION public.get_active_recommendations(TEXT, TEXT, INTEGER) TO anon, authenticated;


-- ── 1d. get_groups_ranked_by_city ────────────────────────────────────────────

DROP FUNCTION IF EXISTS public.get_groups_ranked_by_city(TEXT, INT);
DROP FUNCTION IF EXISTS public.get_groups_ranked_by_city(TEXT, TEXT, INT);

CREATE OR REPLACE FUNCTION public.get_groups_ranked_by_city(
  p_city  TEXT,
  p_state TEXT    DEFAULT NULL,
  p_limit INT     DEFAULT 60
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
  v_city_norm  TEXT := CASE WHEN p_city  IS NULL THEN NULL ELSE normalize_city_name(p_city)  END;
  v_state_norm TEXT := CASE WHEN p_state IS NULL THEN NULL ELSE normalize_state_name(p_state) END;
BEGIN
  RETURN QUERY
  SELECT
    g.id, g.name, g.genre, g.city,
    COALESCE(g.service_cities, '[]'::JSONB),
    g.profile_image, g.photo_status, g.price_from,
    g.rating, g.total_reviews, g.is_verified, g.verification_status,
    g.is_active,
    COALESCE(g.puntos_reputacion, 0)::INT,
    COALESCE(g.bid_amount, 0::NUMERIC),
    g.bid_ends_at,
    COALESCE(g.boost_score, 0)::INT,
    g.boost_ends_at,
    COALESCE(g.trust_score, 0::NUMERIC),
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
    -- Filtro de ciudad
    AND (
      v_city_norm IS NULL
      OR normalize_city_name(g.city) = v_city_norm
      OR EXISTS (
        SELECT 1
        FROM jsonb_array_elements_text(COALESCE(g.service_cities, '[]'::JSONB)) sc(city_name)
        WHERE normalize_city_name(sc.city_name) = v_city_norm
      )
    )
    -- Filtro de estado normalizado: NULL = nacional (aparece en todos)
    AND (
      v_state_norm IS NULL
      OR g.state IS NULL
      OR normalize_state_name(g.state) = v_state_norm
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

GRANT EXECUTE ON FUNCTION public.get_groups_ranked_by_city(TEXT, TEXT, INT) TO anon, authenticated;


-- ════════════════════════════════════════════════════════════════════
-- PARTE 2: RAISE NOTICE de auditoría en funciones de pago
-- Los mensajes aparecen en Supabase → Database Logs.
-- NO bloquean el flujo en ningún caso.
-- ════════════════════════════════════════════════════════════════════


-- ── 2a. confirm_bid_payment ──────────────────────────────────────────────────

DROP FUNCTION IF EXISTS public.confirm_bid_payment(UUID, TEXT);
CREATE OR REPLACE FUNCTION public.confirm_bid_payment(
  p_order_id      UUID,
  p_mp_payment_id TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_order   RECORD;
  v_ends_at TIMESTAMPTZ;
  v_admin   RECORD;
  v_ref_id  TEXT;
BEGIN
  SELECT bo.*, g.city AS group_city, g.name AS group_name, g.state AS group_state
  INTO   v_order
  FROM   public.bid_orders bo
  LEFT JOIN public.groups g ON g.id = bo.group_id
  WHERE  bo.id = p_order_id;

  IF NOT FOUND THEN
    RAISE NOTICE '[PAYMENT_BID] order_not_found order=%', p_order_id;
    RETURN jsonb_build_object('ok', false, 'error', 'order_not_found');
  END IF;

  -- Idempotencia
  IF v_order.status = 'paid' THEN
    RAISE NOTICE '[PAYMENT_BID] skip already_paid order=% amount=%', p_order_id, v_order.amount;
    RETURN jsonb_build_object('ok', true, 'skipped', true);
  END IF;

  v_ref_id  := COALESCE(NULLIF(p_mp_payment_id, ''), 'bid_' || p_order_id::TEXT);
  v_ends_at := NOW() + (v_order.duration_days || ' days')::INTERVAL;

  RAISE NOTICE '[PAYMENT_BID] confirm order=% amount=% state=% reference=%',
    p_order_id, v_order.amount, v_order.group_state, v_ref_id;

  -- Activar puja en el grupo
  UPDATE public.groups
  SET
    bid_amount  = CASE
                    WHEN bid_ends_at IS NOT NULL AND bid_ends_at > NOW()
                    THEN GREATEST(bid_amount, v_order.amount)
                    ELSE v_order.amount
                  END,
    bid_ends_at = CASE
                    WHEN bid_ends_at IS NOT NULL AND bid_ends_at > NOW()
                         AND bid_amount >= v_order.amount
                    THEN bid_ends_at
                    ELSE v_ends_at
                  END
  WHERE id = v_order.group_id;

  -- Marcar orden como pagada
  UPDATE public.bid_orders
  SET status        = 'paid',
      mp_payment_id = p_mp_payment_id,
      state         = COALESCE(state, normalize_state_name(v_order.group_state)),
      starts_at     = NOW(),
      ends_at       = v_ends_at,
      updated_at    = NOW()
  WHERE id = p_order_id;

  -- Registrar ingreso en wallet de cada admin (deduplicado por reference_id)
  FOR v_admin IN SELECT id FROM public.profiles WHERE role = 'admin' LOOP

    INSERT INTO public.wallets (user_id)
    VALUES (v_admin.id)
    ON CONFLICT (user_id) DO NOTHING;

    WITH inserted AS (
      INSERT INTO public.wallet_transactions
        (user_id, amount, type, status, reference_id, description)
      VALUES (
        v_admin.id,
        v_order.amount,
        'bid_income',
        'completed',
        v_ref_id,
        'Posicionamiento: ' || COALESCE(v_order.group_name, v_order.group_id::TEXT)
          || CASE WHEN v_order.group_state IS NOT NULL
                 THEN ' (' || v_order.group_state || ')'
                 ELSE '' END
      )
      ON CONFLICT (reference_id) DO NOTHING
      RETURNING amount, user_id
    )
    UPDATE public.wallets w
    SET available_balance = w.available_balance + i.amount,
        total_earned      = w.total_earned      + i.amount,
        updated_at        = NOW()
    FROM inserted i
    WHERE w.user_id = i.user_id;

  END LOOP;

  RAISE NOTICE '[PAYMENT_BID] done order=% amount=% ends_at=%',
    p_order_id, v_order.amount, v_ends_at;

  RETURN jsonb_build_object(
    'ok',       true,
    'group_id', v_order.group_id,
    'ends_at',  v_ends_at,
    'amount',   v_order.amount,
    'state',    v_order.group_state
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.confirm_bid_payment(UUID, TEXT) TO service_role, authenticated;


-- ── 2b. confirm_recommendation_payment ──────────────────────────────────────

DROP FUNCTION IF EXISTS public.confirm_recommendation_payment(UUID, TEXT);
CREATE OR REPLACE FUNCTION public.confirm_recommendation_payment(
  p_order_id        UUID,
  p_mp_payment_id   TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_order  RECORD;
  v_ends   TIMESTAMPTZ;
  v_admin  RECORD;
  v_ref_id TEXT;
BEGIN
  SELECT ro.*, g.name AS group_name, g.city AS group_city
  INTO   v_order
  FROM   public.recommendation_orders ro
  LEFT JOIN public.groups g ON g.id = ro.group_id
  WHERE  ro.id = p_order_id;

  IF NOT FOUND THEN
    RAISE NOTICE '[PAYMENT_REC] order_not_found order=%', p_order_id;
    RETURN jsonb_build_object('ok', false, 'error', 'order_not_found');
  END IF;

  -- Idempotencia
  IF v_order.status = 'paid' THEN
    RAISE NOTICE '[PAYMENT_REC] skip already_paid order=% amount=%', p_order_id, v_order.amount;
    RETURN jsonb_build_object('ok', true, 'skipped', true, 'reason', 'already_paid');
  END IF;

  v_ends   := NOW() + (v_order.duration_days || ' days')::INTERVAL;
  v_ref_id := COALESCE(NULLIF(p_mp_payment_id, ''), 'rec_' || p_order_id::TEXT);

  RAISE NOTICE '[PAYMENT_REC] confirm order=% amount=% city=% reference=%',
    p_order_id, v_order.amount, v_order.group_city, v_ref_id;

  -- Activar la orden
  UPDATE public.recommendation_orders
  SET status            = 'paid',
      stripe_payment_id = p_mp_payment_id,
      starts_at         = NOW(),
      ends_at           = v_ends,
      updated_at        = NOW()
  WHERE id = p_order_id;

  -- Registrar recommendation_income en wallet de cada admin (CTE atómica)
  FOR v_admin IN SELECT id FROM public.profiles WHERE role = 'admin' LOOP

    INSERT INTO public.wallets (user_id)
    VALUES (v_admin.id)
    ON CONFLICT (user_id) DO NOTHING;

    WITH inserted AS (
      INSERT INTO public.wallet_transactions
        (user_id, amount, type, status, reference_id, description)
      VALUES (
        v_admin.id,
        v_order.amount,
        'recommendation_income',
        'completed',
        v_ref_id,
        'Recomendación: ' || COALESCE(v_order.group_name, v_order.group_id::TEXT)
          || ' · ' || v_order.duration_days || 'd'
          || CASE WHEN v_order.group_city IS NOT NULL
                 THEN ' (' || v_order.group_city || ')'
                 ELSE '' END
      )
      ON CONFLICT (reference_id) DO NOTHING
      RETURNING amount, user_id
    )
    UPDATE public.wallets w
    SET available_balance = w.available_balance + i.amount,
        total_earned      = w.total_earned      + i.amount,
        updated_at        = NOW()
    FROM inserted i
    WHERE w.user_id = i.user_id;

  END LOOP;

  RAISE NOTICE '[PAYMENT_REC] done order=% amount=% ends_at=%',
    p_order_id, v_order.amount, v_ends;

  RETURN jsonb_build_object(
    'ok',        true,
    'order_id',  p_order_id,
    'ends_at',   v_ends,
    'amount',    v_order.amount,
    'reference', v_ref_id
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.confirm_recommendation_payment(UUID, TEXT) TO service_role;
GRANT EXECUTE ON FUNCTION public.confirm_recommendation_payment(UUID, TEXT) TO authenticated;


-- ── 2c. mark_ad_payment ──────────────────────────────────────────────────────

DROP FUNCTION IF EXISTS public.mark_ad_payment(UUID, TEXT);
CREATE OR REPLACE FUNCTION public.mark_ad_payment(
  p_ad_id         UUID,
  p_mp_payment_id TEXT
)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_ad    RECORD;
  v_price NUMERIC(10,2);
  v_admin RECORD;
BEGIN
  -- Leer anuncio + precio del paquete
  SELECT a.*, COALESCE(ap.price, 0) AS pkg_price
  INTO   v_ad
  FROM   public.advertisements a
  LEFT JOIN public.ad_packages ap ON ap.id = a.package_id
  WHERE  a.id = p_ad_id;

  IF NOT FOUND THEN
    RAISE NOTICE '[PAYMENT_AD] ad_not_found ad=%', p_ad_id;
    RETURN jsonb_build_object('ok', false, 'error', 'ad_not_found');
  END IF;

  -- Idempotencia
  IF v_ad.mp_payment_id = p_mp_payment_id AND v_ad.mp_payment_id IS NOT NULL THEN
    RAISE NOTICE '[PAYMENT_AD] skip already_paid ad=% reference=%', p_ad_id, p_mp_payment_id;
    RETURN jsonb_build_object('ok', true, 'skipped', true, 'reason', 'already_paid');
  END IF;

  v_price := v_ad.pkg_price;

  RAISE NOTICE '[PAYMENT_AD] confirm ad=% price=% type=% reference=%',
    p_ad_id, v_price, v_ad.type, p_mp_payment_id;

  -- Actualizar status del anuncio: pending_payment → pending_review
  UPDATE public.advertisements
  SET    mp_payment_id = p_mp_payment_id,
         status        = CASE
                           WHEN status = 'pending_payment' THEN 'pending_review'
                           ELSE status
                         END,
         updated_at    = now()
  WHERE  id = p_ad_id;

  -- Registrar ingreso en wallet (solo si hay precio y pago real)
  IF v_price > 0 AND p_mp_payment_id IS NOT NULL AND p_mp_payment_id != '' THEN
    FOR v_admin IN SELECT id FROM public.profiles WHERE role = 'admin' LOOP

      INSERT INTO public.wallets (user_id)
      VALUES (v_admin.id)
      ON CONFLICT (user_id) DO NOTHING;

      WITH inserted AS (
        INSERT INTO public.wallet_transactions
          (user_id, amount, type, status, reference_id, description)
        VALUES (
          v_admin.id,
          v_price,
          'ad_income',
          'completed',
          p_mp_payment_id,
          'Publicidad pagada: ' || v_ad.title || ' (' || v_ad.type || ')'
        )
        ON CONFLICT (reference_id) DO NOTHING
        RETURNING amount, user_id
      )
      UPDATE public.wallets w
      SET available_balance = w.available_balance + i.amount,
          total_earned      = w.total_earned      + i.amount,
          updated_at        = now()
      FROM inserted i
      WHERE w.user_id = i.user_id;

    END LOOP;

    RAISE NOTICE '[PAYMENT_AD] done ad=% price=% reference=%',
      p_ad_id, v_price, p_mp_payment_id;
  ELSE
    RAISE NOTICE '[PAYMENT_AD] no_wallet_entry ad=% price=% (price=0 or no reference)',
      p_ad_id, v_price;
  END IF;

  RETURN jsonb_build_object('ok', true, 'price', v_price, 'ad_id', p_ad_id);
END;
$$;

GRANT EXECUTE ON FUNCTION public.mark_ad_payment(UUID, TEXT) TO authenticated, service_role;


-- ── Verificación ──────────────────────────────────────────────────────────────

-- Confirmar que normalize_state_name existe
SELECT proname, pronargs
FROM   pg_proc
WHERE  proname = 'normalize_state_name'
  AND  pronamespace = 'public'::regnamespace;

SELECT '178_normalize_in_rpcs_and_payment_logs.sql ejecutado ✅' AS status;
