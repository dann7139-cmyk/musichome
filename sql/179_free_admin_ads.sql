-- ════════════════════════════════════════════════════════════════════
-- 179_free_admin_ads.sql
--
-- OBJETIVO: Permitir que el admin cree anuncios gratuitos que aparecen
-- en la app sin generar ingresos en wallet.
--
-- 1. Columna is_free en advertisements (DEFAULT FALSE — no toca filas existentes)
-- 2. create_free_ad — RPC para que admin inserte anuncios gratis (status='active')
-- 3. mark_ad_payment — guarda protección: ignora anuncios is_free=TRUE
-- 4. get_active_banner_ads — ORDER BY is_free ASC (pagados primero)
-- 5. get_profile_ads — ORDER BY is_free ASC (pagado gana si hay ambos, LIMIT 1)
--
-- Seguro: ADD COLUMN IF NOT EXISTS. DROP FUNCTION + firma exacta.
-- Requiere: 178_normalize_in_rpcs_and_payment_logs.sql
-- ════════════════════════════════════════════════════════════════════


-- ── 1. Columna is_free ───────────────────────────────────────────────────────

ALTER TABLE public.advertisements
  ADD COLUMN IF NOT EXISTS is_free BOOLEAN NOT NULL DEFAULT FALSE;

COMMENT ON COLUMN public.advertisements.is_free IS
  'TRUE = anuncio gratuito creado por admin. No genera wallet_transaction. Aparece debajo de pagados.';

CREATE INDEX IF NOT EXISTS idx_advertisements_is_free
  ON public.advertisements (is_free);


-- ── 2. create_free_ad — solo admin ──────────────────────────────────────────

DROP FUNCTION IF EXISTS public.create_free_ad(TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, INT, TEXT);
CREATE OR REPLACE FUNCTION public.create_free_ad(
  p_type          TEXT,
  p_title         TEXT,
  p_subtitle      TEXT    DEFAULT NULL,
  p_button_text   TEXT    DEFAULT 'Ver más',
  p_media_url     TEXT    DEFAULT NULL,
  p_media_type    TEXT    DEFAULT NULL,   -- 'image' | 'video'
  p_target_state  TEXT    DEFAULT NULL,
  p_duration_days INT     DEFAULT 30,
  p_tag           TEXT    DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_user_id UUID := auth.uid();
  v_role    TEXT;
  v_ad_id   UUID;
  v_ends_at TIMESTAMPTZ;
BEGIN
  -- Verificar que el usuario es admin
  SELECT role INTO v_role FROM public.profiles WHERE id = v_user_id;
  IF v_role IS DISTINCT FROM 'admin' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'unauthorized');
  END IF;

  -- Validar tipo permitido
  IF p_type NOT IN ('banner_home', 'profile_ad', 'sponsored_group') THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_type',
      'allowed', '["banner_home","profile_ad","sponsored_group"]'::JSONB);
  END IF;

  -- Título obligatorio
  IF p_title IS NULL OR TRIM(p_title) = '' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'title_required');
  END IF;

  -- Calcular ends_at (NULL = sin vencimiento)
  v_ends_at := CASE
    WHEN p_duration_days IS NOT NULL AND p_duration_days > 0
    THEN NOW() + (p_duration_days || ' days')::INTERVAL
    ELSE NULL
  END;

  INSERT INTO public.advertisements (
    type, title, subtitle, button_text,
    media_url, media_type,
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
    normalize_state_name(p_target_state),   -- normalizar al guardar
    'active',                               -- activo de inmediato
    TRUE,                                   -- es gratis
    NOW(),
    v_ends_at,
    NULLIF(TRIM(COALESCE(p_tag, '')), ''),
    v_user_id
  )
  RETURNING id INTO v_ad_id;

  RAISE NOTICE '[FREE_AD] created ad=% type=% title=% state=% ends_at=%',
    v_ad_id, p_type, p_title, p_target_state, v_ends_at;

  RETURN jsonb_build_object(
    'ok',       true,
    'ad_id',    v_ad_id,
    'type',     p_type,
    'ends_at',  v_ends_at
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.create_free_ad(TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, INT, TEXT)
  TO authenticated;


-- ── 3. mark_ad_payment — protección para anuncios gratis ────────────────────
-- Si por algún error se llama mark_ad_payment sobre un anuncio is_free, lo ignora.

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
  SELECT a.*, COALESCE(ap.price, 0) AS pkg_price
  INTO   v_ad
  FROM   public.advertisements a
  LEFT JOIN public.ad_packages ap ON ap.id = a.package_id
  WHERE  a.id = p_ad_id;

  IF NOT FOUND THEN
    RAISE NOTICE '[PAYMENT_AD] ad_not_found ad=%', p_ad_id;
    RETURN jsonb_build_object('ok', false, 'error', 'ad_not_found');
  END IF;

  -- Protección: anuncios gratis no generan ingreso
  IF v_ad.is_free = TRUE THEN
    RAISE NOTICE '[PAYMENT_AD] skip_free ad=% (is_free=true, no wallet entry)', p_ad_id;
    RETURN jsonb_build_object('ok', true, 'skipped', true, 'reason', 'free_ad');
  END IF;

  -- Idempotencia
  IF v_ad.mp_payment_id = p_mp_payment_id AND v_ad.mp_payment_id IS NOT NULL THEN
    RAISE NOTICE '[PAYMENT_AD] skip already_paid ad=% reference=%', p_ad_id, p_mp_payment_id;
    RETURN jsonb_build_object('ok', true, 'skipped', true, 'reason', 'already_paid');
  END IF;

  v_price := v_ad.pkg_price;

  RAISE NOTICE '[PAYMENT_AD] confirm ad=% price=% type=% reference=%',
    p_ad_id, v_price, v_ad.type, p_mp_payment_id;

  UPDATE public.advertisements
  SET    mp_payment_id = p_mp_payment_id,
         status        = CASE
                           WHEN status = 'pending_payment' THEN 'pending_review'
                           ELSE status
                         END,
         updated_at    = now()
  WHERE  id = p_ad_id;

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
    RAISE NOTICE '[PAYMENT_AD] no_wallet_entry ad=% price=%', p_ad_id, v_price;
  END IF;

  RETURN jsonb_build_object('ok', true, 'price', v_price, 'ad_id', p_ad_id);
END;
$$;

GRANT EXECUTE ON FUNCTION public.mark_ad_payment(UUID, TEXT) TO authenticated, service_role;


-- ── 4. get_active_banner_ads — pagados primero (is_free ASC) ─────────────────

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
    AND  (
      a.target_location_type IS NULL
      OR a.target_location_type = 'national'
      OR p_city IS NULL
      OR (a.target_locations IS NOT NULL
          AND a.target_locations @> jsonb_build_array(p_city))
    )
    AND  (
      p_state IS NULL
      OR a.target_state IS NULL
      OR normalize_state_name(a.target_state) = normalize_state_name(p_state)
    )
  ORDER BY
    a.is_free ASC,                      -- FALSE (pagados) antes que TRUE (gratis)
    COALESCE(pkg.price, 0) DESC,
    a.order_index ASC,
    a.starts_at   ASC;
END;
$$;

GRANT EXECUTE ON FUNCTION public.get_active_banner_ads(TEXT, TEXT) TO anon, authenticated;


-- ── 5. get_profile_ads — pagados primero (is_free ASC) ──────────────────────
-- Con LIMIT 1: si hay un anuncio pagado y uno gratis para ese perfil,
-- siempre se muestra el pagado.

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
    AND  (
      a.target_location_type IS NULL
      OR a.target_location_type = 'national'
      OR p_city IS NULL
      OR (a.target_locations IS NOT NULL
          AND a.target_locations @> jsonb_build_array(p_city))
    )
    AND  (
      p_state IS NULL
      OR a.target_state IS NULL
      OR normalize_state_name(a.target_state) = normalize_state_name(p_state)
    )
  ORDER BY
    a.is_free ASC,    -- pagado gana (FALSE < TRUE)
    a.order_index
  LIMIT  1;
END;
$$;

GRANT EXECUTE ON FUNCTION public.get_profile_ads(UUID, TEXT, TEXT) TO authenticated;


-- ── Verificación ──────────────────────────────────────────────────────────────

SELECT
  is_free,
  COUNT(*)     AS total,
  COUNT(*) FILTER (WHERE status = 'active')  AS activos
FROM public.advertisements
GROUP BY is_free
ORDER BY is_free;

SELECT '179_free_admin_ads.sql ejecutado ✅' AS status;
