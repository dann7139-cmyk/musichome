-- ════════════════════════════════════════════════════════════════════════════
-- 149_multi_city.sql
-- Sistema multi-ciudad para grupos.
-- Los grupos pueden recibir solicitudes de ciudades fuera de su ciudad base.
--
-- CAMBIOS:
--   · groups.service_cities  JSONB[]  — ciudades adicionales donde el grupo opera
--   · get_groups_ranked_by_city()     — incluye grupos con service_cities que
--                                       contienen la ciudad del cliente
--   · RPC update_my_service_cities()  — el grupo actualiza sus ciudades de cobertura
--
-- Ciudad base (groups.city) = mercado principal, determina ranking y bids.
-- service_cities = extensión geográfica opcional, sin impacto en ranking.
--
-- Ejecutar DESPUÉS de 148_dynamic_pricing.sql
-- ════════════════════════════════════════════════════════════════════════════


-- ── 1. Agregar columna service_cities a groups ────────────────────────────────

ALTER TABLE public.groups
  ADD COLUMN IF NOT EXISTS service_cities JSONB NOT NULL DEFAULT '[]'::JSONB;

COMMENT ON COLUMN public.groups.service_cities IS
  'Array de ciudades adicionales donde el grupo acepta trabajar, ej: ["Zapopan","Puerto Vallarta"]';


-- ── 2. Re-crear get_groups_ranked_by_city con soporte multi-ciudad ────────────
-- Incluye grupos cuya ciudad base O service_cities coincide con p_city.
-- El ranking sigue siendo por ciudad base (bid/boost local), no mezclado.

DROP FUNCTION IF EXISTS public.get_groups_ranked_by_city(TEXT, INT);
CREATE OR REPLACE FUNCTION public.get_groups_ranked_by_city(
  p_city  TEXT,
  p_limit INT DEFAULT 60
)
RETURNS TABLE (
  id                    UUID,
  name                  TEXT,
  genre                 TEXT,
  city                  TEXT,
  service_cities        JSONB,
  profile_image         TEXT,
  rating                NUMERIC,
  total_reviews         INT,
  is_verified           BOOLEAN,
  verification_status   TEXT,
  is_active             BOOLEAN,
  puntos_reputacion     INT,
  bid_amount            NUMERIC,
  bid_ends_at           TIMESTAMPTZ,
  boost_score           INT,
  boost_ends_at         TIMESTAMPTZ,
  trust_score           NUMERIC,
  search_penalty        NUMERIC,
  is_high_demand        BOOLEAN,
  recent_completions    INT,
  bid_active            BOOLEAN,
  is_local              BOOLEAN   -- TRUE si la ciudad base coincide, FALSE si es via service_cities
)
LANGUAGE plpgsql
SECURITY DEFINER STABLE
SET search_path = public
AS $$
BEGIN
  RETURN QUERY
  SELECT
    g.id,
    g.name,
    g.genre,
    g.city,
    COALESCE(g.service_cities, '[]'::JSONB),
    g.profile_image,
    g.rating,
    g.total_reviews,
    g.is_verified,
    g.verification_status,
    g.is_active,
    COALESCE(g.puntos_reputacion, 0)::INT,
    COALESCE(g.bid_amount,   0::NUMERIC),
    g.bid_ends_at,
    COALESCE(g.boost_score,  0)::INT,
    g.boost_ends_at,
    COALESCE(g.trust_score,  0::NUMERIC),
    COALESCE(g.search_penalty, 0::NUMERIC),
    COALESCE(g.is_high_demand, false),
    COALESCE(g.recent_completions, 0)::INT,
    (
      g.bid_ends_at IS NOT NULL
      AND g.bid_ends_at > now()
      AND COALESCE(g.bid_amount, 0) > 0
    ) AS bid_active,
    -- is_local: TRUE cuando la ciudad base coincide (mejor visibilidad)
    (p_city IS NULL OR g.city ILIKE p_city) AS is_local
  FROM public.groups g
  WHERE g.is_active = true
    AND (
      p_city IS NULL
      -- Ciudad base coincide
      OR g.city ILIKE p_city
      -- Ciudad está en service_cities (búsqueda case-insensitive en array JSONB)
      OR EXISTS (
        SELECT 1
        FROM jsonb_array_elements_text(COALESCE(g.service_cities, '[]'::JSONB)) sc(city_name)
        WHERE sc.city_name ILIKE p_city
      )
    )
  ORDER BY
    -- 1. Grupos locales (ciudad base) primero
    (p_city IS NULL OR g.city ILIKE p_city) DESC,
    -- 2. bid activo
    (g.bid_ends_at IS NOT NULL AND g.bid_ends_at > now()
      AND COALESCE(g.bid_amount, 0) > 0) DESC,
    -- 3. monto de bid
    COALESCE(g.bid_amount, 0) DESC,
    -- 4. boost
    COALESCE(g.boost_score, 0) DESC,
    -- 5. calidad
    COALESCE(g.rating, 0) DESC,
    COALESCE(g.total_reviews, 0) DESC,
    -- 6. desempate
    g.created_at DESC
  LIMIT p_limit;
END;
$$;

GRANT EXECUTE ON FUNCTION public.get_groups_ranked_by_city(TEXT, INT)
  TO anon, authenticated;


-- ── 3. RPC update_my_service_cities() ────────────────────────────────────────
-- Permite al grupo actualizar su lista de ciudades de cobertura.
-- Solo el dueño del grupo puede llamarlo.

DROP FUNCTION IF EXISTS public.update_my_service_cities(UUID, JSONB);
CREATE OR REPLACE FUNCTION public.update_my_service_cities(
  p_group_id      UUID,
  p_service_cities JSONB   -- array de nombres: '["Zapopan","Tlaquepaque"]'
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_user_id UUID := auth.uid();
  v_owner   UUID;
BEGIN
  -- Verificar que el caller es dueño del grupo
  SELECT owner_id INTO v_owner
  FROM   public.groups
  WHERE  id = p_group_id;

  IF v_owner IS DISTINCT FROM v_user_id THEN
    RETURN jsonb_build_object('ok', false, 'error', 'No autorizado');
  END IF;

  -- Validar que sea un array JSON
  IF jsonb_typeof(p_service_cities) <> 'array' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'service_cities debe ser un array');
  END IF;

  -- Límite: máx 10 ciudades adicionales
  IF jsonb_array_length(p_service_cities) > 10 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'Máximo 10 ciudades adicionales');
  END IF;

  UPDATE public.groups
  SET    service_cities = p_service_cities,
         updated_at     = now()
  WHERE  id = p_group_id;

  RETURN jsonb_build_object('ok', true);
END;
$$;

REVOKE ALL ON FUNCTION public.update_my_service_cities(UUID, JSONB) FROM anon;
GRANT  EXECUTE ON FUNCTION public.update_my_service_cities(UUID, JSONB) TO authenticated;


-- ── 4. Índice para búsquedas en service_cities ────────────────────────────────
-- GIN index acelera las consultas jsonb con @> y jsonb_array_elements

CREATE INDEX IF NOT EXISTS idx_groups_service_cities
  ON public.groups USING GIN (service_cities);


SELECT '149_multi_city.sql ejecutado ✅' AS status;
SELECT 'Columna groups.service_cities agregada' AS info;
SELECT 'get_groups_ranked_by_city actualizada: incluye grupos via service_cities' AS info;
SELECT 'RPC update_my_service_cities disponible para grupos' AS info;
