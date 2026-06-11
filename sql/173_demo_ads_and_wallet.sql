-- ════════════════════════════════════════════════════════════════════
-- 173_demo_ads_and_wallet.sql
-- Inserta anuncios de DEMOSTRACIÓN para probar la UI:
--   1. Un anuncio de Perfil (profile_ad) activo
--   2. Un bid_order activo (posicionamiento)
--   3. Wallet_transactions correspondientes para el admin
--
-- Seguro: usa WHERE NOT EXISTS / ON CONFLICT — no duplica.
-- Ejecutar en Supabase SQL Editor.
-- ════════════════════════════════════════════════════════════════════

-- Agregar columnas de fecha a bid_orders si no existen (el panel las necesita para mostrar vigencia)
ALTER TABLE public.bid_orders
  ADD COLUMN IF NOT EXISTS starts_at TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS ends_at   TIMESTAMPTZ;

DO $$
DECLARE
  v_admin_id UUID;
  v_group_id UUID;
  v_ad_id    UUID;
  v_bid_id   UUID;
BEGIN

  -- ── Obtener admin y un grupo activo ────────────────────────────────
  SELECT id INTO v_admin_id FROM public.profiles WHERE role = 'admin' LIMIT 1;
  SELECT id INTO v_group_id FROM public.groups   WHERE is_active = true LIMIT 1;

  IF v_admin_id IS NULL THEN
    RAISE NOTICE '173: No hay usuario admin — abortando';
    RETURN;
  END IF;

  -- ── 1. Anuncio de perfil (profile_ad) ──────────────────────────────
  --    Columnas reales de public.advertisements (ver 117_advertising_system.sql)
  IF v_group_id IS NOT NULL THEN
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
      advertiser_id
    )
    SELECT
      'profile_ad',
      'MusicHome Premium',
      'Anuncio de perfil destacado · Demo',
      'DEMO',
      'Ver más',
      'group',
      v_group_id,
      'active',
      NOW(),
      NOW() + INTERVAL '7 days',
      v_admin_id
    WHERE NOT EXISTS (
      SELECT 1 FROM public.advertisements
      WHERE title = 'MusicHome Premium' AND type = 'profile_ad'
    )
    RETURNING id INTO v_ad_id;

    IF v_ad_id IS NOT NULL THEN
      -- Asegurar wallet del admin
      INSERT INTO public.wallets (user_id)
      VALUES (v_admin_id)
      ON CONFLICT (user_id) DO NOTHING;

      -- Ingreso en billetera
      INSERT INTO public.wallet_transactions
        (user_id, amount, type, status, reference_id, description)
      SELECT
        v_admin_id,
        250,
        'ad_income',
        'completed',
        'ad_' || v_ad_id::TEXT,
        'Publicidad perfil (demo): MusicHome Premium · 7d'
      WHERE NOT EXISTS (
        SELECT 1 FROM public.wallet_transactions
        WHERE reference_id = 'ad_' || v_ad_id::TEXT AND user_id = v_admin_id
      );

      -- Actualizar saldo solo si se insertó la transacción
      UPDATE public.wallets
      SET available_balance = available_balance + 250,
          total_earned      = total_earned      + 250,
          updated_at        = NOW()
      WHERE user_id = v_admin_id
        AND NOT EXISTS (
          SELECT 1 FROM public.wallet_transactions
          WHERE reference_id = 'ad_' || v_ad_id::TEXT
            AND user_id      = v_admin_id
            AND created_at   < NOW() - INTERVAL '1 second'
        );

      RAISE NOTICE '173: profile_ad insertado — id=%', v_ad_id;
    ELSE
      RAISE NOTICE '173: profile_ad ya existía — saltado';
    END IF;
  END IF;

  -- ── 2. Bid order activo ─────────────────────────────────────────────
  --    bid_orders real columns: id, group_id, user_id, package_id,
  --    amount, duration_days, status, mp_payment_id, created_at, updated_at
  IF v_group_id IS NOT NULL THEN
    INSERT INTO public.bid_orders (
      group_id,
      user_id,
      amount,
      duration_days,
      status,
      starts_at,
      ends_at
    )
    SELECT
      v_group_id,
      v_admin_id,
      150,
      5,
      'paid',
      NOW(),
      NOW() + INTERVAL '5 days'
    WHERE NOT EXISTS (
      SELECT 1 FROM public.bid_orders
      WHERE group_id = v_group_id
        AND status   = 'paid'
        AND (ends_at IS NULL OR ends_at > NOW())
    )
    RETURNING id INTO v_bid_id;

    IF v_bid_id IS NOT NULL THEN
      -- Marcar grupo como bid activo
      UPDATE public.groups
      SET bid_amount  = 150,
          bid_ends_at = NOW() + INTERVAL '5 days'
      WHERE id = v_group_id;

      INSERT INTO public.wallets (user_id)
      VALUES (v_admin_id)
      ON CONFLICT (user_id) DO NOTHING;

      INSERT INTO public.wallet_transactions
        (user_id, amount, type, status, reference_id, description)
      SELECT
        v_admin_id,
        150,
        'bid_income',
        'completed',
        'bid_' || v_bid_id::TEXT,
        'Posicionamiento (demo): bid activo · 5d'
      WHERE NOT EXISTS (
        SELECT 1 FROM public.wallet_transactions
        WHERE reference_id = 'bid_' || v_bid_id::TEXT AND user_id = v_admin_id
      );

      UPDATE public.wallets
      SET available_balance = available_balance + 150,
          total_earned      = total_earned      + 150,
          updated_at        = NOW()
      WHERE user_id = v_admin_id
        AND NOT EXISTS (
          SELECT 1 FROM public.wallet_transactions
          WHERE reference_id = 'bid_' || v_bid_id::TEXT
            AND user_id      = v_admin_id
            AND created_at   < NOW() - INTERVAL '1 second'
        );

      RAISE NOTICE '173: bid_order insertado — id=%', v_bid_id;
    ELSE
      RAISE NOTICE '173: bid_order activo ya existía — saltado';
    END IF;
  END IF;

END $$;

-- ── Verificar resultado ───────────────────────────────────────────────────────
SELECT
  type,
  COUNT(*)       AS transacciones,
  SUM(amount)    AS total_ingresado
FROM public.wallet_transactions
WHERE type   IN ('ad_income', 'bid_income', 'recommendation_income')
  AND status = 'completed'
GROUP BY type
ORDER BY total_ingresado DESC;

SELECT
  type, title, status,
  starts_at::DATE AS inicio,
  ends_at::DATE   AS fin
FROM public.advertisements
WHERE status = 'active'
ORDER BY created_at DESC
LIMIT 10;

SELECT '173_demo_ads_and_wallet.sql ejecutado ✅' AS status;
