-- ============================================================
-- sql/615_bidding_rank_por_estado.sql
-- get_group_ranking_position() pasa de rankear por CIUDAD a rankear por
-- ESTADO — petición real del usuario (2026-09-05), tras confirmar que
-- Destacado/Recomendado/Banner/Perfil ya funcionan por estado, y que el
-- Explorador (HomeScreen) también rankea el Bidding sobre lo que tenga
-- filtrado (típicamente el estado completo, no la ciudad).
--
-- PROBLEMA REAL: con solo Daniel Rivera pujando en toda la app, "#1 en tu
-- panel" y "Top 3 en Explorador" coincidían por accidente (no había con
-- quién competir). El día que dos grupos pujaran en distintas ciudades
-- del MISMO estado, cada uno hubiera visto "#1 en mi ciudad" en su panel
-- aunque en el Explorador (que ve todo el estado junto) uno de los dos
-- en realidad fuera #2 — números que no combinan entre sí.
--
-- p_city se queda en la firma de la función a propósito (sin usarse) para
-- no tener que tocar los 2 call-sites del frontend (DashboardScreen.tsx)
-- — el estado se saca directo del grupo, igual que ya hacen
-- check_sponsored_availability/check_recommendation_availability.
--
-- TESTEADO en BEGIN...ROLLBACK: 2 grupos, mismo estado, ciudades
-- distintas ($300 y $100 de puja) — confirmado que ahora compiten entre
-- sí (el de $300 queda #1, el de $100 queda #2, total=2), en vez de cada
-- uno saliendo "#1 en su ciudad" por separado.
-- ============================================================

BEGIN;

CREATE OR REPLACE FUNCTION public.get_group_ranking_position(p_group_id uuid, p_city text)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public' AS $function$
DECLARE
  v_state_norm TEXT;
  v_my_bid     NUMERIC  := 0;
  v_position   INT      := NULL;
  v_total      INT      := 0;
  v_top3       JSONB;
  v_gap        NUMERIC  := NULL;
  v_badge      TEXT     := NULL;
BEGIN
  SELECT normalize_state_name(state), COALESCE(bid_amount, 0)
  INTO   v_state_norm, v_my_bid
  FROM   public.groups
  WHERE  id = p_group_id;

  SELECT COUNT(*) INTO v_total
  FROM   public.groups g
  WHERE  normalize_state_name(g.state) = v_state_norm
    AND  g.bid_ends_at > now()
    AND  COALESCE(g.bid_amount, 0) > 0
    AND  g.is_active = true;

  IF v_my_bid > 0 THEN
    SELECT COUNT(*) + 1 INTO v_position
    FROM   public.groups g
    WHERE  normalize_state_name(g.state) = v_state_norm
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
    WHERE  normalize_state_name(g.state) = v_state_norm
      AND  g.bid_ends_at > now()
      AND  COALESCE(g.bid_amount, 0) > 0
      AND  g.is_active = true
    ORDER BY COALESCE(g.bid_amount, 0) DESC
    LIMIT  3
  ) sub;

  IF v_position IS NOT NULL AND v_position > 1 THEN
    SELECT COALESCE(g.bid_amount, 0) - v_my_bid + 1 INTO v_gap
    FROM   public.groups g
    WHERE  normalize_state_name(g.state) = v_state_norm
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
