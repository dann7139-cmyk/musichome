-- ════════════════════════════════════════════════════════════════════
-- 165_wallet_consistency.sql
-- Unifica el momento de registro de ingresos: SOLO al confirmar pago.
-- Elimina lógica por tiempo. Usa INSERT...RETURNING para atomicidad.
-- Usa mp_payment_id como reference_id real (idempotencia real).
--
-- CAMBIOS:
--   1. mark_ad_payment → registra ad_income al confirmar pago
--   2. approve_ad      → elimina registro de wallet (solo aprueba)
--   3. confirm_bid_payment → CTE atómica + mp_payment_id como reference_id
--   4. Backfill: migra reference_id de 'ad_xxx'/'bid_xxx' → mp_payment_id
--
-- EJECUTAR DESPUÉS DE: 164_admin_wallet_ad_bid_income.sql
-- ════════════════════════════════════════════════════════════════════


-- ── 1. mark_ad_payment — registra el ingreso AL CONFIRMAR PAGO ──────────────
-- Antes: solo actualizaba el status del anuncio.
-- Ahora: además registra ad_income en la wallet del admin.
-- reference_id = mp_payment_id (ID real de MercadoPago → idempotencia real).

DROP FUNCTION IF EXISTS public.mark_ad_payment(UUID, TEXT);
CREATE OR REPLACE FUNCTION public.mark_ad_payment(
  p_ad_id         UUID,
  p_mp_payment_id TEXT
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
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
    RETURN jsonb_build_object('ok', false, 'error', 'ad_not_found');
  END IF;

  -- Idempotencia: si ya tiene este mp_payment_id, no hacer nada
  IF v_ad.mp_payment_id = p_mp_payment_id AND v_ad.mp_payment_id IS NOT NULL THEN
    RETURN jsonb_build_object('ok', true, 'skipped', true, 'reason', 'already_paid');
  END IF;

  v_price := v_ad.pkg_price;

  -- Actualizar status del anuncio: pending_payment → pending_review
  UPDATE public.advertisements
  SET    mp_payment_id = p_mp_payment_id,
         status        = CASE
                           WHEN status = 'pending_payment' THEN 'pending_review'
                           ELSE status
                         END,
         updated_at    = now()
  WHERE  id = p_ad_id;

  -- Registrar ingreso en wallet de cada admin (solo si hay precio y pago real)
  IF v_price > 0 AND p_mp_payment_id IS NOT NULL AND p_mp_payment_id != '' THEN
    FOR v_admin IN SELECT id FROM public.profiles WHERE role = 'admin' LOOP

      INSERT INTO public.wallets (user_id)
      VALUES (v_admin.id)
      ON CONFLICT (user_id) DO NOTHING;

      -- CTE atómica: INSERT + UPDATE en una sola operación
      -- Si el reference_id ya existe → ON CONFLICT DO NOTHING → RETURNING vacío → UPDATE no corre
      WITH inserted AS (
        INSERT INTO public.wallet_transactions
          (user_id, amount, type, status, reference_id, description)
        VALUES (
          v_admin.id,
          v_price,
          'ad_income',
          'completed',
          p_mp_payment_id,                                      -- ID real de MercadoPago
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

GRANT EXECUTE ON FUNCTION public.mark_ad_payment(UUID, TEXT) TO authenticated, service_role;


-- ── 2. approve_ad — sin registro de wallet (solo aprobación) ────────────────
-- El dinero ya se registró en mark_ad_payment (al confirmar pago).
-- approve_ad solo activa el anuncio y sponsored_groups si aplica.

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
  v_days  INT;
  v_ad    RECORD;
  v_count INT;
  v_max   INT;
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

  v_days := COALESCE(p_duration_days, v_ad.pkg_days, 7);

  -- Límite de anuncios activos por tipo
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
          package_id = EXCLUDED.package_id;
  END IF;

  -- Audit log
  INSERT INTO public.ad_audit_log (ad_id, action, performed_by, details)
  VALUES (p_id, 'approved', auth.uid(),
    jsonb_build_object(
      'title',         v_ad.title,
      'type',          v_ad.type,
      'duration_days', v_days,
      'ends_at',       now() + (v_days || ' days')::INTERVAL
    )
  );

  RETURN jsonb_build_object('ok', true, 'duration_days', v_days);
END;
$$;

GRANT EXECUTE ON FUNCTION public.approve_ad(UUID, INT) TO authenticated;


-- ── 3. confirm_bid_payment — CTE atómica + mp_payment_id como reference_id ──
-- Antes: usaba 'bid_' || order_id y ventana de tiempo.
-- Ahora: usa mp_payment_id como reference_id. INSERT...RETURNING atómico.

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
  v_order     RECORD;
  v_ends_at   TIMESTAMPTZ;
  v_admin     RECORD;
  v_ref_id    TEXT;
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
    RETURN jsonb_build_object('ok', true, 'skipped', true, 'reason', 'already_paid');
  END IF;

  v_ends_at := NOW() + (v_order.duration_days || ' days')::INTERVAL;

  -- reference_id: mp_payment_id si existe, fallback a 'bid_' || order_id
  v_ref_id := COALESCE(
    NULLIF(p_mp_payment_id, ''),
    'bid_' || p_order_id::TEXT
  );

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

  -- Registrar ingreso en wallet de cada admin (CTE atómica)
  FOR v_admin IN SELECT id FROM public.profiles WHERE role = 'admin' LOOP

    INSERT INTO public.wallets (user_id)
    VALUES (v_admin.id)
    ON CONFLICT (user_id) DO NOTHING;

    -- Si ya existe el reference_id → ON CONFLICT DO NOTHING → RETURNING vacío → UPDATE no corre
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

  RETURN jsonb_build_object(
    'ok',        true,
    'group_id',  v_order.group_id,
    'ends_at',   v_ends_at,
    'amount',    v_order.amount,
    'reference', v_ref_id
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.confirm_bid_payment(UUID, TEXT) TO service_role;
GRANT EXECUTE ON FUNCTION public.confirm_bid_payment(UUID, TEXT) TO authenticated;


-- ── 4. Backfill: migrar reference_id de 'ad_xxx' → mp_payment_id real ────────
-- Para anuncios que ya tienen mp_payment_id registrado en advertisements,
-- actualizar el reference_id en wallet_transactions para usar el ID real.
-- Si hay colisión (ya existe el mp_payment_id), eliminar el duplicado antiguo.

DO $$
DECLARE
  v_ad RECORD;
  v_wt_id UUID;
BEGIN
  FOR v_ad IN
    SELECT a.id, a.mp_payment_id
    FROM   public.advertisements a
    WHERE  a.mp_payment_id IS NOT NULL
      AND  a.mp_payment_id != ''
  LOOP
    -- Verificar si ya existe un registro con el mp_payment_id nuevo
    IF EXISTS (
      SELECT 1 FROM public.wallet_transactions
      WHERE reference_id = v_ad.mp_payment_id
    ) THEN
      -- Ya migrado o duplicado: eliminar el registro con reference_id antiguo
      DELETE FROM public.wallet_transactions
      WHERE reference_id = 'ad_' || v_ad.id::TEXT;
    ELSE
      -- Migrar: actualizar reference_id al mp_payment_id real
      UPDATE public.wallet_transactions
      SET    reference_id = v_ad.mp_payment_id
      WHERE  reference_id = 'ad_' || v_ad.id::TEXT;
    END IF;
  END LOOP;
END $$;


-- ── 5. Backfill: migrar reference_id de 'bid_xxx' → mp_payment_id real ───────
DO $$
DECLARE
  v_bid RECORD;
BEGIN
  FOR v_bid IN
    SELECT bo.id, bo.mp_payment_id
    FROM   public.bid_orders bo
    WHERE  bo.mp_payment_id IS NOT NULL
      AND  bo.mp_payment_id != ''
  LOOP
    IF EXISTS (
      SELECT 1 FROM public.wallet_transactions
      WHERE reference_id = v_bid.mp_payment_id
    ) THEN
      DELETE FROM public.wallet_transactions
      WHERE reference_id = 'bid_' || v_bid.id::TEXT;
    ELSE
      UPDATE public.wallet_transactions
      SET    reference_id = v_bid.mp_payment_id
      WHERE  reference_id = 'bid_' || v_bid.id::TEXT;
    END IF;
  END LOOP;
END $$;


SELECT '165_wallet_consistency.sql ejecutado ✅' AS status;
SELECT 'mark_ad_payment: registra ad_income al confirmar pago (no al aprobar)' AS cambio_1;
SELECT 'approve_ad: sin lógica de wallet (solo activa anuncio y sponsored_groups)' AS cambio_2;
SELECT 'confirm_bid_payment: CTE atómica + mp_payment_id como reference_id' AS cambio_3;
SELECT 'Backfill: reference_id migrado de id interno → mp_payment_id real' AS cambio_4;
