-- ROLLBACK de sql/615_bidding_rank_por_estado.sql
-- Solo correr en emergencia deliberada. Regresa get_group_ranking_position
-- a rankear por CIUDAD en vez de por estado.

BEGIN;

CREATE OR REPLACE FUNCTION public.get_group_ranking_position(p_group_id uuid, p_city text)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public' AS $function$
DECLARE
  v_city_norm  TEXT     := normalize_city_name(p_city);
  v_my_bid     NUMERIC  := 0;
  v_position   INT      := NULL;
  v_total      INT      := 0;
  v_top3       JSONB;
  v_gap        NUMERIC  := NULL;
  v_badge      TEXT     := NULL;
BEGIN
  SELECT COALESCE(bid_amount, 0) INTO v_my_bid
  FROM   public.groups
  WHERE  id = p_group_id;

  SELECT COUNT(*) INTO v_total
  FROM   public.groups g
  WHERE  normalize_city_name(g.city) = v_city_norm
    AND  g.bid_ends_at > now()
    AND  COALESCE(g.bid_amount, 0) > 0
    AND  g.is_active = true;

  IF v_my_bid > 0 THEN
    SELECT COUNT(*) + 1 INTO v_position
    FROM   public.groups g
    WHERE  normalize_city_name(g.city) = v_city_norm
      AND  g.bid_ends_at > now()
      AND  COALESCE(g.bid_amount, 0) > v_my_bid
      AND  g.is_active = true;
  END IF;

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
$function$;

COMMIT;
