-- ============================================================
-- sql/609_profile_ads_multi_group_owner_fix.sql
-- APLICADO 2026-09-04.
--
-- HALLAZGO REAL corriendo la suite de regresión (sql/602) tras sql/607:
-- get_profile_ads() usaba `SELECT ... FROM groups WHERE owner_id = X
-- LIMIT 1` (sin ORDER BY) para encontrar "el grupo del anunciante" y así
-- calcular su categoría. Si un mismo owner_id tiene MÁS de un grupo (ej.
-- una Banda y también un Comida), el LIMIT 1 podía traer cualquiera de
-- los dos de forma arbitraria — el filtro de "categoría distinta" se
-- volvía errático en vez de correcto.
--
-- Corrección: en vez de escoger UN grupo del anunciante, se pregunta con
-- EXISTS si el anunciante tiene AL MENOS UN grupo del MISMO tier
-- (músico/no-músico) que el perfil que se está viendo — si sí, se
-- excluye. Para el caso normal (un dueño = un grupo) el resultado es
-- idéntico a antes; para un dueño con varios grupos, ahora es correcto
-- sin importar cuántos tenga ni en qué orden los devuelva el planner.
--
-- Probado en BEGIN...ROLLBACK antes de aplicar: un anunciante con DOS
-- grupos músicos (Banda + Mariachi) — su anuncio NO aparece en el perfil
-- músico de otro dueño, SÍ aparece en el perfil de Payasos de otro dueño.
-- Ver rollback en el archivo _ROLLBACK (regresa a la versión LIMIT 1 de
-- sql/607).
-- ============================================================

BEGIN;

CREATE OR REPLACE FUNCTION public.get_profile_ads(p_group_id uuid, p_city text DEFAULT NULL::text, p_state text DEFAULT NULL::text)
RETURNS TABLE(id uuid, title text, subtitle text, button_text text, media_url text, media_type text, link_type text, link_id uuid, link_url text, youtube_url text, is_free boolean)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public' AS $function$
DECLARE
  v_viewed_is_musician BOOLEAN := (public.group_default_break_type(p_group_id) IS NULL);
BEGIN
  RETURN QUERY
  SELECT
    a.id, a.title, a.subtitle, a.button_text,
    a.media_url, a.media_type,
    a.link_type, a.link_id, a.link_url, a.youtube_url,
    a.is_free
  FROM   public.advertisements a
  WHERE  a.type   = 'profile_ad'
    AND  a.status = 'active'
    AND  (a.target_group_id IS NULL OR a.target_group_id = p_group_id)
    AND  (a.starts_at IS NULL OR a.starts_at <= now())
    AND  (a.ends_at   IS NULL OR a.ends_at   >  now())
    AND  (
      a.target_location_type IS NULL
      OR a.target_location_type IN ('national', 'international')
      OR p_city IS NULL
      OR (a.target_location_type IN ('city', 'multi_city')
          AND a.target_locations IS NOT NULL
          AND a.target_locations @> jsonb_build_array(p_city))
    )
    AND  (
      p_state IS NULL
      OR (a.target_states IS NULL AND a.target_state IS NULL)
      OR (a.target_states IS NOT NULL
          AND normalize_state_name(p_state) = ANY(a.target_states))
      OR (a.target_states IS NULL AND a.target_state IS NOT NULL
          AND a.target_state = normalize_state_name(p_state))
    )
    AND  NOT EXISTS (
      SELECT 1 FROM public.groups adv
      WHERE adv.owner_id = a.advertiser_id
        AND (public.group_default_break_type(adv.id) IS NULL) = v_viewed_is_musician
    )
  ORDER BY
    a.is_free ASC,
    (
      CASE
        WHEN a.target_location_type IN ('city', 'multi_city')
             AND p_city IS NOT NULL
             AND a.target_locations IS NOT NULL
             AND a.target_locations @> jsonb_build_array(p_city)
        THEN 3.0
        ELSE 1.0
      END
    ) * RANDOM() DESC,
    a.order_index ASC,
    a.starts_at   ASC
  LIMIT 5;
END;
$function$;

COMMIT;
