-- sql/626_fix_get_profile_ads_category_key.sql
--
-- HALLAZGO REAL descubierto corriendo la suite de regresión después de
-- sql/625 (fusión Payasos → Shows): get_profile_ads() NO comparaba
-- categorías reales — usaba group_default_break_type(id) IS NULL como
-- aproximación de "¿es músico?" para decidir si un anuncio es de la
-- "misma categoría" (y por lo tanto debe ocultarse, para no mostrarle a
-- un proveedor el anuncio de su propio competidor).
--
-- Antes de sql/625, Payasos SIEMPRE tenía break_type='D' (no-músico), así
-- que por casualidad SÍ quedaba separado de Banda/DJ (músicos). Al
-- fusionar Payasos con Shows (ahora elige libremente, break_type=NULL),
-- Payasos empezó a contar como "músico" igual que una Banda — y el
-- anuncio de un músico dejaba de mostrarse en un perfil de Payasos
-- (exclusión incorrecta, detectada por el check [14] de sql/602).
--
-- Corrección: usar group_category_key() (sql/610+625) directamente en vez
-- del proxy de break_type — compara la categoría REAL, no una
-- aproximación. Verificado en sandbox: Payaso (categoría distinta a
-- Banda) SÍ ve el anuncio; Mariachi (MISMA categoría 'grupo' que Banda)
-- NO lo ve — ambos casos correctos.
CREATE OR REPLACE FUNCTION public.get_profile_ads(p_group_id uuid, p_city text DEFAULT NULL::text, p_state text DEFAULT NULL::text)
 RETURNS TABLE(id uuid, title text, subtitle text, button_text text, media_url text, media_type text, link_type text, link_id uuid, link_url text, youtube_url text, is_free boolean)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_viewed_category TEXT := public.group_category_key(p_group_id);
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
        AND public.group_category_key(adv.id) = v_viewed_category
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
