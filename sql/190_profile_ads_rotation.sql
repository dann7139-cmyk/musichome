-- ════════════════════════════════════════════════════════════════════
-- 190_profile_ads_rotation.sql
--
-- OBJETIVO: Soportar rotación de varios profile_ads en el perfil
-- de un grupo. Antes retornaba LIMIT 1; ahora retorna hasta 5
-- para que el frontend pueda ciclarlos cada 6 segundos.
--
-- Cambios:
--   1. get_profile_ads — elimina LIMIT 1, agrega LIMIT 5
--      (pagados siempre primero, luego gratuitos)
--
-- Front-end: GroupDetailScreen ya fue actualizado para obtener el
-- array completo y rotar con Animated fade cada 6 s.
--
-- Requiere: 189_dynamic_pricing.sql
-- ════════════════════════════════════════════════════════════════════


-- ── get_profile_ads — hasta 5 anuncios para rotación ────────────────────────

DROP FUNCTION IF EXISTS public.get_profile_ads(UUID, TEXT, TEXT);

CREATE OR REPLACE FUNCTION public.get_profile_ads(
  p_group_id UUID,
  p_city     TEXT DEFAULT NULL,
  p_state    TEXT DEFAULT NULL
)
RETURNS TABLE (
  id          UUID,
  title       TEXT,
  subtitle    TEXT,
  button_text TEXT,
  media_url   TEXT,
  media_type  TEXT,
  link_type   TEXT,
  link_id     UUID,
  is_free     BOOLEAN
)
LANGUAGE plpgsql
SECURITY DEFINER STABLE
SET search_path = public
AS $$
BEGIN
  RETURN QUERY
  SELECT
    a.id, a.title, a.subtitle, a.button_text,
    a.media_url, a.media_type,
    a.link_type, a.link_id,
    a.is_free
  FROM   public.advertisements a
  WHERE  a.type   = 'profile_ad'
    AND  a.status = 'active'
    AND  (a.target_group_id IS NULL OR a.target_group_id = p_group_id)
    AND  (a.starts_at IS NULL OR a.starts_at <= now())
    AND  (a.ends_at   IS NULL OR a.ends_at   >  now())
    -- Filtro de ciudad
    AND  (
      a.target_location_type IS NULL
      OR a.target_location_type = 'national'
      OR p_city IS NULL
      OR (a.target_locations IS NOT NULL
          AND a.target_locations @> jsonb_build_array(p_city))
    )
    -- Filtro de estado: multi-estado + backward compat
    AND  (
      p_state IS NULL
      OR (a.target_states IS NULL AND a.target_state IS NULL)
      OR (a.target_states IS NOT NULL
          AND normalize_state_name(p_state) = ANY(a.target_states))
      OR (a.target_states IS NULL AND a.target_state IS NOT NULL
          AND a.target_state = normalize_state_name(p_state))
    )
  ORDER BY
    a.is_free ASC,      -- pagados primero (FALSE < TRUE)
    a.order_index ASC,
    a.starts_at   ASC
  LIMIT 5;              -- máximo 5 para rotación (era LIMIT 1)
END;
$$;

GRANT EXECUTE ON FUNCTION public.get_profile_ads(UUID, TEXT, TEXT) TO authenticated;


-- ── Verificación ──────────────────────────────────────────────────────────────

SELECT
  id, title, is_free, status, starts_at::DATE, ends_at::DATE
FROM public.advertisements
WHERE type = 'profile_ad'
  AND status = 'active'
ORDER BY is_free, order_index;

SELECT '190_profile_ads_rotation.sql ejecutado ✅' AS status;
