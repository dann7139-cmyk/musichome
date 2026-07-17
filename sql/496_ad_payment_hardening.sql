-- ============================================================
-- sql/496_ad_payment_hardening.sql
-- 🔒 FUGAS DE PUBLICIDAD (auditoría 2026-07-16). Corrige:
--
--  1. create_advertisement_order: aceptaba CUALQUIER p_total_price del
--     cliente (podías pagar $1). Ahora hay PISO server-side.
--  2. create_bid_order: validaba el TOTAL contra el mínimo POR DÍA
--     (30 días al precio de 1). Ahora total ≥ díaMin × días − descuento.
--  3. mark_ad_payment: la idempotencia usaba mp_payment_id, pero
--     create-ad-payment lo escribía ANTES de pagar → el webhook real
--     podía saltarse la confirmación. Ahora es por STATUS + FOR UPDATE.
--     Además acreditaba ad_packages.price en vez de lo realmente
--     cobrado (effective_price).
--  4. approve_ad: cualquiera con sesión podía activar un anuncio SIN
--     pagar, y sobreescribía la duración pagada con defaults. Ahora:
--     solo admin, solo anuncios pagados (o gratis), respeta la
--     duración pagada.
--  5. confirm_bid_payment: carrera en la acreditación de wallet
--     (ventana de 1 segundo). Ahora FOR UPDATE + inserción atómica.
--  6. expire_advertisements: no expiraba recommendation_orders.
--
--  NO toca reservas, wallets de grupos, GPS ni liberaciones.
-- ============================================================

BEGIN;

-- ── 1. create_advertisement_order v2 — piso de precio server-side ────
-- Piso = base × 0.70 (0.70 es el multiplicador de ciudad MÍNIMO en
-- cities.price_multiplier; demanda y ubicación siempre son ≥ 1.0).
-- Base con paquete: precio de tier banner (espejo de BANNER_TIER_PRICES
-- del frontend) o ad_packages.price. Base personalizada: $/día × días
-- (banner 65, sponsored 55, profile 55 — espejo de BASE_PER_DAY).
CREATE OR REPLACE FUNCTION public.ad_price_floor(
  p_type        TEXT,
  p_package_id  UUID,
  p_custom_days INT
)
RETURNS NUMERIC
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_pkg  RECORD;
  v_base NUMERIC := 0;
  v_days INT;
BEGIN
  IF p_package_id IS NOT NULL THEN
    SELECT * INTO v_pkg FROM ad_packages WHERE id = p_package_id;
    IF FOUND THEN
      -- Tier banners: precios espejo del frontend (top_1_3 / top_4_10)
      IF v_pkg.type = 'banner_home' AND v_pkg.tier = 'top_1_3' THEN
        v_base := CASE v_pkg.duration_days WHEN 7 THEN 699 WHEN 14 THEN 1199 WHEN 30 THEN 1999 ELSE v_pkg.price END;
      ELSIF v_pkg.type = 'banner_home' AND v_pkg.tier = 'top_4_10' THEN
        v_base := CASE v_pkg.duration_days WHEN 7 THEN 499 WHEN 14 THEN 899 WHEN 30 THEN 1499 ELSE v_pkg.price END;
      ELSE
        v_base := COALESCE(v_pkg.price, 0);
      END IF;
    END IF;
  ELSE
    v_days := GREATEST(COALESCE(p_custom_days, 7), 1);
    v_base := v_days * CASE p_type
      WHEN 'banner_home'     THEN 65
      WHEN 'sponsored_group' THEN 55
      WHEN 'profile_ad'      THEN 55
      ELSE 65
    END;
  END IF;

  RETURN ROUND(v_base * 0.70, 2);
END;
$$;

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
  p_total_price      NUMERIC  DEFAULT NULL,
  p_target_state     TEXT     DEFAULT NULL,
  p_target_states    TEXT[]   DEFAULT NULL,
  p_target_country   TEXT     DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_user_id     UUID := auth.uid();
  v_ad_id       UUID;
  v_group_id    UUID;
  v_group_state TEXT;
  v_pkg         RECORD;
  v_total       NUMERIC;
  v_floor       NUMERIC;
  v_dur_days    INT;
  v_state_norm  TEXT;
  v_states_arr  TEXT[];
BEGIN
  IF v_user_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'no_session');
  END IF;

  IF p_type NOT IN ('banner_home', 'sponsored_group', 'profile_ad') THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_type: ' || COALESCE(p_type, 'null'));
  END IF;

  IF p_package_id IS NOT NULL THEN
    SELECT * INTO v_pkg FROM public.ad_packages
    WHERE id = p_package_id AND is_active = true;
    IF NOT FOUND THEN
      RETURN jsonb_build_object('ok', false, 'error', 'package_not_found');
    END IF;
  END IF;

  SELECT id, state INTO v_group_id, v_group_state
  FROM   public.groups
  WHERE  owner_id = v_user_id
  LIMIT  1;

  IF p_type = 'sponsored_group' THEN
    v_state_norm := normalize_state_name(v_group_state);
  ELSE
    v_state_norm := normalize_state_name(
      COALESCE(NULLIF(TRIM(COALESCE(p_target_state, '')), ''), v_group_state)
    );
  END IF;

  IF p_type IN ('banner_home', 'profile_ad')
     AND COALESCE(p_location_type, 'national') <> 'international'
     AND p_target_states IS NOT NULL
     AND array_length(p_target_states, 1) > 0
  THEN
    SELECT ARRAY(
      SELECT normalize_state_name(s)
      FROM   unnest(p_target_states) AS s
      WHERE  TRIM(s) <> ''
    ) INTO v_states_arr;
    IF array_length(v_states_arr, 1) IS NULL THEN
      v_states_arr := NULL;
    END IF;
  END IF;

  IF p_package_id IS NOT NULL THEN
    v_total    := COALESCE(p_total_price, v_pkg.price, 0);
    v_dur_days := COALESCE(v_pkg.duration_days, p_custom_days, 7);
  ELSE
    v_total    := COALESCE(p_total_price, 0);
    v_dur_days := COALESCE(p_custom_days, 7);
  END IF;

  -- 🔒 PISO server-side: el cliente no puede inventar un precio menor
  v_floor := ad_price_floor(p_type, p_package_id, p_custom_days);
  IF v_total < v_floor THEN
    RETURN jsonb_build_object('ok', false, 'error', 'price_below_minimum', 'minimum', v_floor);
  END IF;

  INSERT INTO public.advertisements (
    advertiser_id, package_id, type, title, subtitle, button_text,
    media_url, media_type, link_type, link_id,
    target_location_type, target_locations, target_state, target_states,
    target_country,
    duration_seconds, youtube_url, custom_days,
    total_price, effective_price,
    status,
    starts_at, ends_at
  ) VALUES (
    v_user_id, p_package_id, p_type, p_title, p_subtitle,
    COALESCE(p_button_text, 'Contratar'),
    p_media_url, COALESCE(p_media_type, 'none'),
    CASE WHEN p_type = 'sponsored_group' THEN 'group'
         ELSE COALESCE(p_link_type, 'none') END,
    CASE WHEN p_type = 'sponsored_group' THEN v_group_id
         ELSE p_link_id END,
    COALESCE(p_location_type, 'national'), p_locations,
    v_state_norm, v_states_arr,
    p_target_country,
    p_duration_seconds,
    CASE WHEN COALESCE(p_link_type, 'none') = 'video' THEN p_youtube_url ELSE NULL END,
    p_custom_days,
    v_total, v_total,
    'pending_payment',
    NOW(),
    NOW() + (v_dur_days || ' days')::INTERVAL
  )
  RETURNING id INTO v_ad_id;

  IF p_type = 'sponsored_group' AND v_group_id IS NOT NULL THEN
    INSERT INTO public.sponsored_groups (group_id, advertiser_id, starts_at, ends_at, is_active)
    VALUES (v_group_id, v_user_id, NOW(), NOW() + (v_dur_days || ' days')::INTERVAL, false)
    ON CONFLICT DO NOTHING;
  END IF;

  RETURN jsonb_build_object(
    'ok',     true,
    'ad_id',  v_ad_id,
    'state',  v_state_norm,
    'states', v_states_arr,
    'total',  v_total
  );
END;
$$;

-- ── 2. create_bid_order v2 — total ≥ mínimo/día × días − descuento ───
-- Espejo de DISCOUNT_TIERS del frontend: 15d→15%, 8d→10%, 4d→5%.
CREATE OR REPLACE FUNCTION public.create_bid_order(
  p_package_id    UUID    DEFAULT NULL,
  p_custom_amount NUMERIC DEFAULT NULL,
  p_duration_days INT     DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_user_id  UUID := auth.uid();
  v_group    RECORD;
  v_pkg      RECORD;
  v_amount   NUMERIC;
  v_days     INT;
  v_per_day  NUMERIC;
  v_discount NUMERIC;
  v_min_tot  NUMERIC;
  v_order_id UUID;
BEGIN
  IF v_user_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'no_session');
  END IF;

  SELECT id, city, state INTO v_group FROM public.groups WHERE owner_id = v_user_id LIMIT 1;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'group_not_found');
  END IF;

  IF p_package_id IS NOT NULL THEN
    SELECT * INTO v_pkg FROM public.bid_packages WHERE id = p_package_id AND is_active = true;
    IF NOT FOUND THEN
      RETURN jsonb_build_object('ok', false, 'error', 'package_not_found');
    END IF;
    v_days    := COALESCE(p_duration_days, v_pkg.duration_days);
    v_per_day := v_pkg.min_bid;
    v_amount  := COALESCE(p_custom_amount, v_pkg.min_bid * v_days);
  ELSE
    IF p_custom_amount IS NULL OR p_duration_days IS NULL THEN
      RETURN jsonb_build_object('ok', false, 'error', 'missing_bid_params');
    END IF;
    v_days    := p_duration_days;
    v_per_day := 50;
    v_amount  := p_custom_amount;
  END IF;

  IF v_days < 1 OR v_days > 90 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_duration');
  END IF;

  -- 🔒 El TOTAL debe cubrir el mínimo por día × días, menos el descuento
  -- por volumen que el frontend ofrece (espejo de DISCOUNT_TIERS)
  v_discount := CASE
    WHEN v_days >= 15 THEN 0.15
    WHEN v_days >= 8  THEN 0.10
    WHEN v_days >= 4  THEN 0.05
    ELSE 0
  END;
  v_min_tot := ROUND(v_per_day * v_days * (1 - v_discount));
  IF v_amount < v_min_tot THEN
    RETURN jsonb_build_object('ok', false, 'error', 'bid_below_minimum', 'min_bid', v_min_tot);
  END IF;

  INSERT INTO public.bid_orders (group_id, user_id, package_id, amount, duration_days, state)
  VALUES (v_group.id, v_user_id, p_package_id, v_amount, v_days, v_group.state)
  RETURNING id INTO v_order_id;

  RETURN jsonb_build_object(
    'ok',           true,
    'order_id',     v_order_id,
    'amount',       v_amount,
    'duration_days', v_days,
    'group_id',     v_group.id,
    'state',        v_group.state
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.create_bid_order(UUID, NUMERIC, INT) TO authenticated;

-- ── 3. mark_ad_payment v2 — idempotencia por STATUS, acredita lo cobrado ──
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
  -- FOR UPDATE: serializa reenvíos concurrentes del webhook
  SELECT a.*, COALESCE(ap.price, 0) AS pkg_price
  INTO   v_ad
  FROM   public.advertisements a
  LEFT JOIN public.ad_packages ap ON ap.id = a.package_id
  WHERE  a.id = p_ad_id
  FOR UPDATE OF a;

  IF NOT FOUND THEN
    RAISE NOTICE '[PAYMENT_AD] ad_not_found ad=%', p_ad_id;
    RETURN jsonb_build_object('ok', false, 'error', 'ad_not_found');
  END IF;

  IF v_ad.is_free = TRUE THEN
    RETURN jsonb_build_object('ok', true, 'skipped', true, 'reason', 'free_ad');
  END IF;

  -- Idempotencia POR STATUS (antes era por mp_payment_id, que
  -- create-ad-payment escribía ANTES de pagar → saltaba el webhook real)
  IF v_ad.status <> 'pending_payment' THEN
    RETURN jsonb_build_object('ok', true, 'skipped', true, 'reason', 'already_processed');
  END IF;

  -- 💰 Acreditar lo que REALMENTE se cobró (effective_price), no el
  -- precio base del paquete
  v_price := COALESCE(NULLIF(v_ad.effective_price, 0), NULLIF(v_ad.total_price, 0), v_ad.pkg_price);

  UPDATE public.advertisements
  SET    mp_payment_id = p_mp_payment_id,
         status        = 'pending_review',
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
          v_admin.id, v_price, 'ad_income', 'completed', p_mp_payment_id,
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
  END IF;

  RETURN jsonb_build_object('ok', true, 'price', v_price, 'ad_id', p_ad_id);
END;
$$;

-- Solo el webhook (service_role) confirma pagos — nunca el cliente
REVOKE EXECUTE ON FUNCTION public.mark_ad_payment(UUID, TEXT) FROM authenticated;
GRANT  EXECUTE ON FUNCTION public.mark_ad_payment(UUID, TEXT) TO service_role;

-- ── 4. approve_ad v2 — solo admin, solo pagados, respeta duración pagada ──
CREATE OR REPLACE FUNCTION public.approve_ad(p_id UUID, p_duration_days INT DEFAULT NULL)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_ad    public.advertisements%ROWTYPE;
  v_limit INT;
  v_count INT;
  v_days  INT;
BEGIN
  -- 🔒 Solo admin puede aprobar
  IF NOT EXISTS (
    SELECT 1 FROM public.profiles WHERE id = auth.uid() AND role = 'admin'
  ) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_admin');
  END IF;

  SELECT * INTO v_ad FROM public.advertisements WHERE id = p_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_found');
  END IF;

  -- 🔒 No se activa un anuncio SIN pagar (los gratis sí pasan)
  IF v_ad.status = 'pending_payment' AND COALESCE(v_ad.is_free, false) = false THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_paid_yet');
  END IF;

  -- ⏱ Respetar la duración PAGADA: la fijó create_advertisement_order en
  -- ends_at − created_at. p_duration_days solo la puede ajustar el admin
  -- explícitamente.
  v_days := COALESCE(
    p_duration_days,
    NULLIF(GREATEST(EXTRACT(DAY FROM (v_ad.ends_at - v_ad.created_at))::INT, 0), 0),
    CASE v_ad.type
      WHEN 'banner_home'     THEN 7
      WHEN 'sponsored_group' THEN 30
      WHEN 'profile_ad'      THEN 14
      ELSE 7
    END
  );

  v_limit := CASE v_ad.type
    WHEN 'banner_home'     THEN 3
    WHEN 'sponsored_group' THEN 10
    WHEN 'profile_ad'      THEN 20
    ELSE 5
  END;

  SELECT COUNT(*) INTO v_count
  FROM public.advertisements
  WHERE type = v_ad.type AND status = 'active' AND id != p_id;

  IF v_count >= v_limit THEN
    RETURN jsonb_build_object(
      'ok', false, 'error', 'limit_reached',
      'type', v_ad.type, 'count', v_count, 'limit', v_limit
    );
  END IF;

  UPDATE public.advertisements
  SET status    = 'active',
      starts_at = NOW(),
      ends_at   = NOW() + (v_days || ' days')::INTERVAL,
      updated_at = NOW()
  WHERE id = p_id;

  IF v_ad.type = 'sponsored_group' THEN
    UPDATE public.sponsored_groups
    SET is_active = true,
        ends_at   = NOW() + (v_days || ' days')::INTERVAL
    WHERE id = (
      SELECT id FROM public.sponsored_groups
      WHERE advertiser_id = v_ad.advertiser_id
        AND is_active = false
      ORDER BY created_at DESC
      LIMIT 1
    );
  END IF;

  RETURN jsonb_build_object('ok', true, 'days', v_days);
END;
$$;

-- ── 5. confirm_bid_payment v2 — FOR UPDATE + acreditación atómica ────
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
BEGIN
  -- FOR UPDATE: reenvíos concurrentes del webhook se serializan aquí
  SELECT bo.*, g.city AS group_city, g.name AS group_name, g.state AS group_state
  INTO   v_order
  FROM   public.bid_orders bo
  LEFT JOIN public.groups g ON g.id = bo.group_id
  WHERE  bo.id = p_order_id
  FOR UPDATE OF bo;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'order_not_found');
  END IF;

  IF v_order.status = 'paid' THEN
    RETURN jsonb_build_object('ok', true, 'skipped', true);  -- idempotente
  END IF;

  v_ends_at := NOW() + (v_order.duration_days || ' days')::INTERVAL;

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

  UPDATE public.bid_orders
  SET status        = 'paid',
      mp_payment_id = p_mp_payment_id,
      state         = COALESCE(state, v_order.group_state),
      starts_at     = NOW(),
      ends_at       = v_ends_at,
      updated_at    = NOW()
  WHERE id = p_order_id;

  -- Acreditación ATÓMICA (antes: ventana de 1 segundo con carrera)
  FOR v_admin IN SELECT id FROM public.profiles WHERE role = 'admin' LOOP
    INSERT INTO public.wallets (user_id)
    VALUES (v_admin.id)
    ON CONFLICT (user_id) DO NOTHING;

    WITH inserted AS (
      INSERT INTO public.wallet_transactions
        (user_id, amount, type, status, reference_id, description)
      SELECT
        v_admin.id, v_order.amount, 'bid_income', 'completed',
        'bid_' || p_order_id,
        'Posicionamiento: ' || COALESCE(v_order.group_name, v_order.group_id::TEXT)
          || CASE WHEN v_order.group_state IS NOT NULL
                 THEN ' (' || v_order.group_state || ')'
                 ELSE '' END
      WHERE NOT EXISTS (
        SELECT 1 FROM public.wallet_transactions
        WHERE reference_id = 'bid_' || p_order_id
          AND user_id      = v_admin.id
      )
      RETURNING amount, user_id
    )
    UPDATE public.wallets w
    SET available_balance = w.available_balance + i.amount,
        total_earned      = w.total_earned      + i.amount,
        updated_at        = NOW()
    FROM inserted i
    WHERE w.user_id = i.user_id;
  END LOOP;

  RETURN jsonb_build_object(
    'ok',       true,
    'group_id', v_order.group_id,
    'ends_at',  v_ends_at,
    'amount',   v_order.amount,
    'state',    v_order.group_state
  );
END;
$$;

-- ── 6. expire_advertisements v2 — también recommendation_orders ──────
CREATE OR REPLACE FUNCTION public.expire_advertisements()
RETURNS INT
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_count INT := 0;
BEGIN
  IF NOT pg_try_advisory_xact_lock(9876543210) THEN
    RETURN 0;
  END IF;

  INSERT INTO public.ad_audit_log (ad_id, action, performed_by, details)
  SELECT
    id, 'expired', NULL,
    jsonb_build_object('title', title, 'type', type, 'ended_at', ends_at)
  FROM public.advertisements
  WHERE status IN ('active', 'approved')
    AND ends_at IS NOT NULL
    AND ends_at < now();

  UPDATE public.advertisements
  SET    status     = 'expired',
         updated_at = now()
  WHERE  status IN ('active', 'approved')
    AND  ends_at IS NOT NULL
    AND  ends_at < now();
  GET DIAGNOSTICS v_count = ROW_COUNT;

  UPDATE public.sponsored_groups
  SET    is_active = false
  WHERE  is_active = true
    AND  ends_at IS NOT NULL
    AND  ends_at < now();

  UPDATE public.bid_orders
  SET    status     = 'expired',
         updated_at = now()
  WHERE  status = 'paid'
    AND  ends_at IS NOT NULL
    AND  ends_at < now();

  UPDATE public.groups
  SET    bid_amount  = 0,
         bid_ends_at = NULL
  WHERE  bid_ends_at IS NOT NULL
    AND  bid_ends_at < now();

  -- 🆕 Recomendados vencidos (antes quedaban en 'paid' para siempre)
  UPDATE public.recommendation_orders
  SET    status = 'expired'
  WHERE  status = 'paid'
    AND  ends_at IS NOT NULL
    AND  ends_at < now();

  RETURN v_count;
END;
$$;

GRANT EXECUTE ON FUNCTION public.expire_advertisements() TO service_role;
REVOKE EXECUTE ON FUNCTION public.expire_advertisements() FROM authenticated;

COMMIT;

-- ── VERIFICACIÓN ──────────────────────────────────────────────────────────────
SELECT prosrc LIKE '%price_below_minimum%' AS piso_anuncios
FROM pg_proc WHERE proname = 'create_advertisement_order';
-- Esperado: true

SELECT prosrc LIKE '%v_min_tot%' AS piso_bidding
FROM pg_proc WHERE proname = 'create_bid_order';
-- Esperado: true

SELECT prosrc LIKE '%already_processed%' AS idempotencia_status
FROM pg_proc WHERE proname = 'mark_ad_payment';
-- Esperado: true

SELECT prosrc LIKE '%not_admin%' AS approve_solo_admin
FROM pg_proc WHERE proname = 'approve_ad';
-- Esperado: true

SELECT prosrc LIKE '%recommendation_orders%' AS expira_recomendados
FROM pg_proc WHERE proname = 'expire_advertisements';
-- Esperado: true

SELECT '496_ad_payment_hardening.sql ejecutado ✅' AS status;
