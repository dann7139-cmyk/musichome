-- ════════════════════════════════════════════════════════════════════
-- 170_ad_monetization_ordering.sql
-- • Mejora el orden de get_active_recommendations: mayor monto primero,
--   luego por tiempo restante (grupos con más días vigentes van arriba).
-- • Agrega columna bid_amount a recommendation_orders para futura subasta.
-- ════════════════════════════════════════════════════════════════════

-- ── 1. bid_amount en recommendation_orders ──────────────────────────
ALTER TABLE public.recommendation_orders
  ADD COLUMN IF NOT EXISTS bid_amount NUMERIC(10, 2) DEFAULT NULL;

COMMENT ON COLUMN public.recommendation_orders.bid_amount IS
  'Monto de subasta (futuro). Cuando no es NULL, se usa en lugar de amount para calcular prioridad.';

-- ── 2. get_active_recommendations mejorado ──────────────────────────
-- DROP primero porque el tipo de retorno cambió (nueva columna profile_image)
DROP FUNCTION IF EXISTS public.get_active_recommendations(TEXT, INTEGER);
-- Orden: (1) amount DESC — mayor pago primero
--        (2) ends_at DESC — más tiempo restante como desempate
--        (3) starts_at DESC — más reciente como último desempate
CREATE OR REPLACE FUNCTION public.get_active_recommendations(
  p_city   TEXT    DEFAULT NULL,
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
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public
AS $$
  SELECT
    g.id,
    g.name,
    g.genre,
    g.city,
    g.description,
    g.price_from,
    g.rating,
    g.total_reviews,
    g.is_verified,
    g.profile_image,
    ro.amount,
    ro.ends_at
  FROM public.recommendation_orders ro
  JOIN public.groups g ON g.id = ro.group_id
  WHERE ro.status  = 'paid'
    AND ro.starts_at <= NOW()
    AND ro.ends_at   >  NOW()
    AND g.is_active  = TRUE
    AND (p_city IS NULL OR LOWER(TRIM(g.city)) = LOWER(TRIM(p_city)))
  ORDER BY
    -- Mayor pago absoluto primero
    COALESCE(ro.bid_amount, ro.amount) DESC,
    -- Más tiempo restante como desempate (presencia garantizada más larga)
    ro.ends_at DESC,
    -- Más reciente como último desempate
    ro.starts_at DESC
  LIMIT p_limit;
$$;

GRANT EXECUTE ON FUNCTION public.get_active_recommendations(TEXT, INTEGER) TO anon, authenticated;

SELECT '170_ad_monetization_ordering.sql ejecutado ✅' AS status;
SELECT 'bid_amount column added to recommendation_orders' AS info_1;
SELECT 'get_active_recommendations now orders by amount DESC → ends_at DESC → starts_at DESC' AS info_2;
