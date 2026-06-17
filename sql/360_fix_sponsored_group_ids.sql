-- ════════════════════════════════════════════════════════════════════
-- sql/360_fix_sponsored_group_ids.sql
--
-- Resuelve bug P1: get_sponsored_group_ids solo filtraba por ciudad.
-- Un grupo de Texas podía aparecer en el feed de México si la ciudad
-- del grupo coincidía con alguna ciudad mexicana.
--
-- Cambios:
--   - Agrega p_state   TEXT DEFAULT NULL (segundo nivel)
--   - Agrega p_country TEXT DEFAULT NULL (prioridad máxima)
--   - g.state/g.country IS NULL = grupo nacional → siempre visible
--   - p_city mantiene compatibilidad con llamadas existentes
--
-- Backward compatible: todos los nuevos params tienen DEFAULT NULL.
-- La llamada actual { p_city: userCity } sigue funcionando sin cambios
-- hasta que HomeScreen.tsx envíe p_state y p_country.
--
-- Requiere: normalize_state_name() de sql/177.
-- Ejecutar ANTES de sql/361_recommendations_bi_country.sql.
-- ════════════════════════════════════════════════════════════════════

BEGIN;

-- ═══════════════════════════════════════════════════════════════════
-- BLOQUE 1: get_sponsored_group_ids con filtro bi-país
-- Bug P1: antes solo filtraba (p_city IS NULL OR g.city ILIKE p_city)
-- ═══════════════════════════════════════════════════════════════════

-- 1a. Eliminar firma antigua con exactamente 1 parámetro (TEXT)
--     DROP con firma completa para no afectar sobrecargas futuras.
DROP FUNCTION IF EXISTS public.get_sponsored_group_ids(TEXT);

-- 1b. Nueva versión con p_state y p_country
CREATE OR REPLACE FUNCTION public.get_sponsored_group_ids(
  p_city    TEXT DEFAULT NULL,
  p_state   TEXT DEFAULT NULL,
  p_country TEXT DEFAULT NULL
)
RETURNS TABLE (group_id UUID, ends_at TIMESTAMPTZ)
LANGUAGE plpgsql
SECURITY DEFINER STABLE
SET search_path = public
AS $$
BEGIN
  RETURN QUERY
  SELECT DISTINCT sg.group_id, sg.ends_at
  FROM   public.sponsored_groups sg
  JOIN   public.groups           g ON g.id = sg.group_id
  WHERE  sg.is_active = true
    AND  sg.ends_at   > now()
    -- País: prioridad máxima.
    -- g.country IS NULL = grupo sin país asignado → se muestra siempre (nacional).
    AND  (
      p_country IS NULL
      OR g.country IS NULL
      OR LOWER(TRIM(g.country)) = LOWER(TRIM(p_country))
    )
    -- Estado: segundo nivel de filtro.
    -- g.state IS NULL = grupo nacional → visible en cualquier estado.
    AND  (
      p_state IS NULL
      OR g.state IS NULL
      OR normalize_state_name(g.state) = normalize_state_name(p_state)
    )
    -- Ciudad: auxiliar, para compatibilidad con llamadas ya existentes.
    AND  (p_city IS NULL OR g.city ILIKE p_city)
  ORDER BY sg.ends_at DESC;
END;
$$;

-- 1c. Permisos explícitos sobre la nueva firma (3 parámetros)
GRANT EXECUTE ON FUNCTION public.get_sponsored_group_ids(TEXT, TEXT, TEXT)
  TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_sponsored_group_ids(TEXT, TEXT, TEXT)
  TO service_role;

COMMIT;


-- ═══════════════════════════════════════════════════════════════════
-- VERIFICACIÓN — ejecutar DESPUÉS del COMMIT para confirmar éxito
-- ═══════════════════════════════════════════════════════════════════

-- Confirmar que la función tiene 3 parámetros con DEFAULT NULL
SELECT
  p.ordinal_position  AS pos,
  p.parameter_name    AS nombre,
  p.data_type         AS tipo,
  p.parameter_default AS default_val
FROM information_schema.parameters p
WHERE p.specific_schema = 'public'
  AND p.routine_name    = 'get_sponsored_group_ids'
ORDER BY p.ordinal_position;
-- Esperado: 3 filas
--   1 | p_city    | text | NULL
--   2 | p_state   | text | NULL
--   3 | p_country | text | NULL

SELECT '360_fix_sponsored_group_ids.sql ejecutado ✅' AS status;
