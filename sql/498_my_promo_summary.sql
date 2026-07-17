-- ============================================================
-- sql/498_my_promo_summary.sql
-- 📊 "Mi publicidad": el anunciante (grupo o cliente) ve TODO lo
--    que ha comprado — estado, vigencia y cuánto lleva gastado.
--    (Antes pagaban y no había dónde ver nada.)
--
--  Un solo RPC para la pantalla MyAdsScreen:
--   · advertisements (banner / destacado / anuncio de perfil)
--   · bid_orders (posicionamiento)
--   · recommendation_orders (recomendados, vía su grupo)
--   · total_gastado = SOLO lo realmente pagado
--
--  SECURITY DEFINER con auth.uid() — cada quien ve lo suyo.
-- ============================================================

BEGIN;

CREATE OR REPLACE FUNCTION public.get_my_promo_summary()
RETURNS JSONB
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_user  UUID := auth.uid();
  v_ads   JSONB;
  v_bids  JSONB;
  v_recs  JSONB;
  v_spent NUMERIC := 0;
  v_active INT := 0;
BEGIN
  IF v_user IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'no_session');
  END IF;

  -- Anuncios (banner / destacado / perfil)
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'id',        a.id,
    'kind',      'ad',
    'type',      a.type,
    'title',     a.title,
    'status',    a.status,
    'amount',    a.effective_price,
    'paid',      (a.mp_payment_id IS NOT NULL AND a.status <> 'pending_payment') OR COALESCE(a.is_free, false),
    'is_free',   COALESCE(a.is_free, false),
    'starts_at', a.starts_at,
    'ends_at',   a.ends_at,
    'created_at', a.created_at
  ) ORDER BY a.created_at DESC), '[]'::jsonb)
  INTO v_ads
  FROM advertisements a
  WHERE a.advertiser_id = v_user;

  -- Posicionamiento (bidding)
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'id',        b.id,
    'kind',      'bid',
    'status',    b.status,
    'amount',    b.amount,
    'paid',      b.status IN ('paid', 'expired'),
    'days',      b.duration_days,
    'starts_at', b.starts_at,
    'ends_at',   b.ends_at,
    'created_at', b.created_at
  ) ORDER BY b.created_at DESC), '[]'::jsonb)
  INTO v_bids
  FROM bid_orders b
  WHERE b.user_id = v_user;

  -- Recomendados (por los grupos del usuario)
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'id',        r.id,
    'kind',      'rec',
    'status',    r.status,
    'amount',    r.amount,
    'paid',      r.status IN ('paid', 'expired'),
    'days',      r.duration_days,
    'starts_at', r.starts_at,
    'ends_at',   r.ends_at,
    'created_at', r.created_at
  ) ORDER BY r.created_at DESC), '[]'::jsonb)
  INTO v_recs
  FROM recommendation_orders r
  JOIN groups g ON g.id = r.group_id
  WHERE g.owner_id = v_user;

  -- 💰 Total gastado: SOLO pagos confirmados (nunca pendientes ni gratis)
  SELECT COALESCE((
    SELECT SUM(a.effective_price) FROM advertisements a
    WHERE a.advertiser_id = v_user
      AND a.mp_payment_id IS NOT NULL
      AND a.status <> 'pending_payment'
      AND COALESCE(a.is_free, false) = false
  ), 0)
  + COALESCE((
    SELECT SUM(b.amount) FROM bid_orders b
    WHERE b.user_id = v_user AND b.status IN ('paid', 'expired')
  ), 0)
  + COALESCE((
    SELECT SUM(r.amount) FROM recommendation_orders r
    JOIN groups g ON g.id = r.group_id
    WHERE g.owner_id = v_user AND r.status IN ('paid', 'expired')
  ), 0)
  INTO v_spent;

  -- Activos ahora mismo
  SELECT
    (SELECT COUNT(*) FROM advertisements a
      WHERE a.advertiser_id = v_user AND a.status = 'active'
        AND (a.ends_at IS NULL OR a.ends_at > NOW()))
  + (SELECT COUNT(*) FROM bid_orders b
      WHERE b.user_id = v_user AND b.status = 'paid'
        AND b.ends_at IS NOT NULL AND b.ends_at > NOW())
  + (SELECT COUNT(*) FROM recommendation_orders r
      JOIN groups g ON g.id = r.group_id
      WHERE g.owner_id = v_user AND r.status = 'paid'
        AND r.ends_at IS NOT NULL AND r.ends_at > NOW())
  INTO v_active;

  RETURN jsonb_build_object(
    'ok',           true,
    'ads',          v_ads,
    'bids',         v_bids,
    'recs',         v_recs,
    'total_spent',  v_spent,
    'active_count', v_active
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.get_my_promo_summary() TO authenticated;

COMMIT;

-- ── VERIFICACIÓN ──────────────────────────────────────────────────────────────
SELECT proname FROM pg_proc WHERE proname = 'get_my_promo_summary';
-- Esperado: 1 fila

SELECT '498_my_promo_summary.sql ejecutado ✅' AS status;
