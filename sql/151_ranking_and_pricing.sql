-- ════════════════════════════════════════════════════════════════════════════
-- 151_ranking_and_pricing.sql
-- Ranking de grupos por ciudad y precios dinámicos.
--
-- FUNCIONES:
--   · get_group_ranking_position(p_group_id, p_city)
--       → posición actual, top 3, badge, gap para subir
--
-- Ejecutar DESPUÉS de 150_normalize_cities.sql
-- ════════════════════════════════════════════════════════════════════════════


-- ── get_group_ranking_position() ─────────────────────────────────────────────
-- Devuelve la posición de un grupo en el ranking de bids de su ciudad.
-- Usado en DashboardScreen para mostrar el mini-card de competencia.
--
-- Retorna:
--   ok           BOOLEAN
--   position     INT  — posición actual (NULL si no tiene bid activo)
--   total        INT  — total de grupos con bid activo en la ciudad
--   my_bid       NUMERIC
--   top3         JSONB  — [{name, pos, bid_amount, is_me}]
--   gap_to_next  NUMERIC — cuánto falta para superar al grupo inmediatamente arriba
--   badge        TEXT   — 'gold' | 'silver' | 'bronze' | null

DROP FUNCTION IF EXISTS public.get_group_ranking_position(UUID, TEXT);
CREATE OR REPLACE FUNCTION public.get_group_ranking_position(
  p_group_id UUID,
  p_city     TEXT
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER STABLE
SET search_path = public
AS $$
DECLARE
  v_city_norm  TEXT     := normalize_city_name(p_city);
  v_my_bid     NUMERIC  := 0;
  v_position   INT      := NULL;
  v_total      INT      := 0;
  v_top3       JSONB;
  v_gap        NUMERIC  := NULL;
  v_badge      TEXT     := NULL;
BEGIN
  -- ── Mi bid actual ────────────────────────────────────────────────────────
  SELECT COALESCE(bid_amount, 0) INTO v_my_bid
  FROM   public.groups
  WHERE  id = p_group_id;

  -- ── Total grupos con bid activo en la ciudad ─────────────────────────────
  SELECT COUNT(*) INTO v_total
  FROM   public.groups g
  WHERE  normalize_city_name(g.city) = v_city_norm
    AND  g.bid_ends_at > now()
    AND  COALESCE(g.bid_amount, 0) > 0
    AND  g.is_active = true;

  -- ── Mi posición (solo si tengo bid activo) ───────────────────────────────
  IF v_my_bid > 0 THEN
    SELECT COUNT(*) + 1 INTO v_position
    FROM   public.groups g
    WHERE  normalize_city_name(g.city) = v_city_norm
      AND  g.bid_ends_at > now()
      AND  COALESCE(g.bid_amount, 0) > v_my_bid
      AND  g.is_active = true;
  END IF;

  -- ── Top 3 ─────────────────────────────────────────────────────────────────
  SELECT jsonb_agg(t ORDER BY t->>'pos') INTO v_top3
  FROM (
    SELECT jsonb_build_object(
      'name',       g.name,
      'pos',        ROW_NUMBER() OVER (ORDER BY COALESCE(g.bid_amount, 0) DESC),
      'bid_amount', COALESCE(g.bid_amount, 0),
      'is_me',      (g.id = p_group_id)
    ) AS t
    FROM public.groups g
    WHERE  normalize_city_name(g.city) = v_city_norm
      AND  g.bid_ends_at > now()
      AND  COALESCE(g.bid_amount, 0) > 0
      AND  g.is_active = true
    ORDER BY COALESCE(g.bid_amount, 0) DESC
    LIMIT  3
  ) sub;

  -- ── Gap para subir una posición ──────────────────────────────────────────
  IF v_position IS NOT NULL AND v_position > 1 THEN
    SELECT COALESCE(g.bid_amount, 0) - v_my_bid + 1 INTO v_gap
    FROM   public.groups g
    WHERE  normalize_city_name(g.city) = v_city_norm
      AND  g.bid_ends_at > now()
      AND  COALESCE(g.bid_amount, 0) > v_my_bid
      AND  g.is_active = true
    ORDER BY COALESCE(g.bid_amount, 0) ASC
    LIMIT  1;
  END IF;

  -- ── Badge de posición ────────────────────────────────────────────────────
  v_badge := CASE
    WHEN v_position = 1 THEN 'gold'
    WHEN v_position = 2 THEN 'silver'
    WHEN v_position = 3 THEN 'bronze'
    ELSE NULL
  END;

  RETURN jsonb_build_object(
    'ok',          true,
    'position',    v_position,
    'total',       v_total,
    'my_bid',      v_my_bid,
    'top3',        COALESCE(v_top3, '[]'::JSONB),
    'gap_to_next', v_gap,
    'badge',       v_badge
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.get_group_ranking_position(UUID, TEXT)
  TO authenticated;


SELECT '151_ranking_and_pricing.sql ejecutado ✅' AS status;
SELECT 'get_group_ranking_position(): posición, top3, badge, gap para subir' AS info;
