-- ════════════════════════════════════════════════════════════════════
-- 164_admin_wallet_ad_bid_income.sql
-- Registra ingresos de publicidad (ad_income) y bidding (bid_income)
-- en la wallet del admin. Incluye deduplicación por reference_id.
--
-- EJECUTAR DESPUÉS DE: 69, 117, 119, 133, 139
-- ════════════════════════════════════════════════════════════════════

-- ── 1. Columna reference_id para deduplicación ───────────────────────────────
ALTER TABLE public.wallet_transactions
  ADD COLUMN IF NOT EXISTS reference_id TEXT;

CREATE UNIQUE INDEX IF NOT EXISTS idx_wt_reference_id
  ON public.wallet_transactions(reference_id)
  WHERE reference_id IS NOT NULL;

-- ── 2. Ampliar tipos de wallet_transactions ──────────────────────────────────
ALTER TABLE public.wallet_transactions
  DROP CONSTRAINT IF EXISTS wallet_transactions_type_check;

ALTER TABLE public.wallet_transactions
  ADD CONSTRAINT wallet_transactions_type_check
  CHECK (type IN (
    'event_earning',    -- ganancia al terminar evento (grupos/talentos)
    'extra_hour',       -- ganancia por hora extra
    'withdrawal',       -- retiro
    'commission',       -- comisión retenida (registro legacy)
    'adjustment',       -- ajuste manual
    'refund',           -- reembolso
    'platform_income',  -- comisión 8% de evento → admin
    'ad_income',        -- ingreso por publicidad → admin
    'bid_income'        -- ingreso por posicionamiento/bidding → admin
  ));

-- ── 3. approve_ad: registrar ingreso en wallet admin al aprobar ──────────────
DROP FUNCTION IF EXISTS public.approve_ad(UUID, INT);
CREATE OR REPLACE FUNCTION public.approve_ad(
  p_id            UUID,
  p_duration_days INT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_days    INT;
  v_ad      RECORD;
  v_count   INT;
  v_max     INT;
  v_price   NUMERIC(10,2);
  v_admin   RECORD;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.profiles WHERE id = auth.uid() AND role = 'admin') THEN
    RETURN jsonb_build_object('ok', false, 'error', 'Unauthorized');
  END IF;

  SELECT a.*, ap.duration_days AS pkg_days, ap.price AS pkg_price
  INTO   v_ad
  FROM   public.advertisements a
  LEFT JOIN public.ad_packages ap ON ap.id = a.package_id
  WHERE  a.id = p_id;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'ad_not_found');
  END IF;

  v_days  := COALESCE(p_duration_days, v_ad.pkg_days, 7);
  v_price := COALESCE(v_ad.pkg_price, 0);

  -- Verificar límite por tipo
  v_max := CASE v_ad.type
    WHEN 'banner_home'     THEN 8
    WHEN 'sponsored_group' THEN 5
    WHEN 'profile_ad'      THEN 10
    ELSE 99
  END;

  SELECT COUNT(*) INTO v_count
  FROM   public.advertisements
  WHERE  type = v_ad.type AND status = 'active' AND id != p_id;

  IF v_count >= v_max THEN
    RETURN jsonb_build_object(
      'ok',    false,
      'error', 'limit_reached',
      'limit', v_max,
      'count', v_count,
      'type',  v_ad.type
    );
  END IF;

  -- Activar el anuncio
  UPDATE public.advertisements
  SET    status      = 'active',
         approved_at = now(),
         approved_by = auth.uid(),
         starts_at   = COALESCE(starts_at, now()),
         ends_at     = COALESCE(ends_at,   now() + (v_days || ' days')::INTERVAL),
         updated_at  = now()
  WHERE  id = p_id;

  -- Para sponsored_group: activar registro en sponsored_groups
  IF v_ad.type = 'sponsored_group' AND v_ad.link_id IS NOT NULL THEN
    INSERT INTO public.sponsored_groups
      (group_id, advertiser_id, package_id, starts_at, ends_at, is_active)
    VALUES
      (v_ad.link_id, v_ad.advertiser_id, v_ad.package_id,
       now(), now() + (v_days || ' days')::INTERVAL, true)
    ON CONFLICT (group_id, advertiser_id) DO UPDATE
      SET is_active  = true,
          starts_at  = now(),
          ends_at    = now() + (v_days || ' days')::INTERVAL,
          package_id = v_ad.package_id;
  END IF;

  -- Registrar ingreso en wallet de CADA admin (deduplicado por reference_id)
  IF v_price > 0 THEN
    FOR v_admin IN SELECT id FROM public.profiles WHERE role = 'admin' LOOP

      INSERT INTO public.wallets (user_id)
      VALUES (v_admin.id)
      ON CONFLICT (user_id) DO NOTHING;

      -- Solo insertar si no existe ya (deduplicación)
      INSERT INTO public.wallet_transactions
        (user_id, amount, type, status, reference_id, description)
      SELECT
        v_admin.id,
        v_price,
        'ad_income',
        'completed',
        'ad_' || p_id,
        'Publicidad aprobada: ' || v_ad.title || ' (' || v_ad.type || ')'
      WHERE NOT EXISTS (
        SELECT 1 FROM public.wallet_transactions
        WHERE reference_id = 'ad_' || p_id
          AND user_id      = v_admin.id
      );

      UPDATE public.wallets
      SET available_balance = available_balance + v_price,
          total_earned      = total_earned      + v_price,
          updated_at        = now()
      WHERE user_id = v_admin.id
        AND NOT EXISTS (
          SELECT 1 FROM public.wallet_transactions
          WHERE reference_id = 'ad_' || p_id
            AND user_id      = v_admin.id
            AND created_at   < now() - interval '1 second'
        );

    END LOOP;
  END IF;

  -- Audit log
  INSERT INTO public.ad_audit_log (ad_id, action, performed_by, details)
  VALUES (p_id, 'approved', auth.uid(),
    jsonb_build_object(
      'title',         v_ad.title,
      'type',          v_ad.type,
      'duration_days', v_days,
      'price',         v_price,
      'ends_at',       now() + (v_days || ' days')::INTERVAL
    )
  );

  RETURN jsonb_build_object('ok', true, 'duration_days', v_days, 'price', v_price);
END;
$$;

GRANT EXECUTE ON FUNCTION public.approve_ad(UUID, INT) TO authenticated;

-- ── 4. confirm_bid_payment: registrar ingreso en wallet admin ────────────────
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
  v_group   RECORD;
BEGIN
  SELECT bo.*, g.city AS group_city, g.name AS group_name
  INTO   v_order
  FROM   public.bid_orders bo
  LEFT JOIN public.groups g ON g.id = bo.group_id
  WHERE  bo.id = p_order_id;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'order_not_found');
  END IF;

  IF v_order.status = 'paid' THEN
    RETURN jsonb_build_object('ok', true, 'skipped', true);  -- idempotente
  END IF;

  v_ends_at := NOW() + (v_order.duration_days || ' days')::INTERVAL;

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
      updated_at    = NOW()
  WHERE id = p_order_id;

  -- Registrar ingreso en wallet de CADA admin (deduplicado)
  FOR v_admin IN SELECT id FROM public.profiles WHERE role = 'admin' LOOP

    INSERT INTO public.wallets (user_id)
    VALUES (v_admin.id)
    ON CONFLICT (user_id) DO NOTHING;

    INSERT INTO public.wallet_transactions
      (user_id, amount, type, status, reference_id, description)
    SELECT
      v_admin.id,
      v_order.amount,
      'bid_income',
      'completed',
      'bid_' || p_order_id,
      'Posicionamiento: ' || COALESCE(v_order.group_name, v_order.group_id::TEXT)
    WHERE NOT EXISTS (
      SELECT 1 FROM public.wallet_transactions
      WHERE reference_id = 'bid_' || p_order_id
        AND user_id      = v_admin.id
    );

    UPDATE public.wallets
    SET available_balance = available_balance + v_order.amount,
        total_earned      = total_earned      + v_order.amount,
        updated_at        = NOW()
    WHERE user_id = v_admin.id
      AND NOT EXISTS (
        SELECT 1 FROM public.wallet_transactions
        WHERE reference_id = 'bid_' || p_order_id
          AND user_id      = v_admin.id
          AND created_at   < now() - interval '1 second'
      );

  END LOOP;

  RETURN jsonb_build_object(
    'ok',       true,
    'group_id', v_order.group_id,
    'ends_at',  v_ends_at,
    'amount',   v_order.amount
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.confirm_bid_payment(UUID, TEXT) TO service_role;
GRANT EXECUTE ON FUNCTION public.confirm_bid_payment(UUID, TEXT) TO authenticated;

-- ── 5. RLS: admin puede leer TODAS las wallet_transactions ───────────────────
DROP POLICY IF EXISTS "wt_admin_select" ON public.wallet_transactions;
CREATE POLICY "wt_admin_select"
  ON public.wallet_transactions FOR SELECT
  USING (EXISTS (
    SELECT 1 FROM public.profiles
    WHERE id = auth.uid() AND role = 'admin'
  ));

-- ── 6. Backfill: anuncios ya aprobados que no tienen wallet_transaction ───────
DO $$
DECLARE
  v_admin  RECORD;
  v_ad     RECORD;
BEGIN
  FOR v_admin IN SELECT id FROM public.profiles WHERE role = 'admin' LOOP
    FOR v_ad IN
      SELECT a.id, a.title, a.type, COALESCE(ap.price, 0) AS price
      FROM   public.advertisements a
      LEFT JOIN public.ad_packages ap ON ap.id = a.package_id
      WHERE  a.status IN ('active', 'approved', 'expired', 'pending_review')
        AND  COALESCE(ap.price, 0) > 0
    LOOP
      INSERT INTO public.wallet_transactions
        (user_id, amount, type, status, reference_id, description)
      SELECT
        v_admin.id,
        v_ad.price,
        'ad_income',
        'completed',
        'ad_' || v_ad.id,
        'Publicidad (backfill): ' || v_ad.title || ' (' || v_ad.type || ')'
      WHERE NOT EXISTS (
        SELECT 1 FROM public.wallet_transactions
        WHERE reference_id = 'ad_' || v_ad.id
          AND user_id      = v_admin.id
      );

      UPDATE public.wallets
      SET available_balance = available_balance + v_ad.price,
          total_earned      = total_earned      + v_ad.price,
          updated_at        = now()
      WHERE user_id = v_admin.id
        AND EXISTS (
          SELECT 1 FROM public.wallet_transactions
          WHERE reference_id = 'ad_' || v_ad.id
            AND user_id      = v_admin.id
            AND created_at   >= now() - interval '5 seconds'
        );
    END LOOP;
  END LOOP;
END $$;

-- ── 7. Backfill: bids ya pagados que no tienen wallet_transaction ─────────────
DO $$
DECLARE
  v_admin  RECORD;
  v_bid    RECORD;
BEGIN
  FOR v_admin IN SELECT id FROM public.profiles WHERE role = 'admin' LOOP
    FOR v_bid IN
      SELECT bo.id, bo.amount, g.name AS group_name
      FROM   public.bid_orders bo
      LEFT JOIN public.groups g ON g.id = bo.group_id
      WHERE  bo.status = 'paid'
    LOOP
      INSERT INTO public.wallet_transactions
        (user_id, amount, type, status, reference_id, description)
      SELECT
        v_admin.id,
        v_bid.amount,
        'bid_income',
        'completed',
        'bid_' || v_bid.id,
        'Posicionamiento (backfill): ' || COALESCE(v_bid.group_name, '—')
      WHERE NOT EXISTS (
        SELECT 1 FROM public.wallet_transactions
        WHERE reference_id = 'bid_' || v_bid.id
          AND user_id      = v_admin.id
      );

      UPDATE public.wallets
      SET available_balance = available_balance + v_bid.amount,
          total_earned      = total_earned      + v_bid.amount,
          updated_at        = now()
      WHERE user_id = v_admin.id
        AND EXISTS (
          SELECT 1 FROM public.wallet_transactions
          WHERE reference_id = 'bid_' || v_bid.id
            AND user_id      = v_admin.id
            AND created_at   >= now() - interval '5 seconds'
        );
    END LOOP;
  END LOOP;
END $$;

SELECT '164_admin_wallet_ad_bid_income.sql ejecutado ✅' AS status;
SELECT 'Tipos nuevos: ad_income, bid_income | reference_id para deduplicación' AS cambios;
SELECT 'Backfill completado: anuncios aprobados + bids pagados → wallet admin' AS backfill;
