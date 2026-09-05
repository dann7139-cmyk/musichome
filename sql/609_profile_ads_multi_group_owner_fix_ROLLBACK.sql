-- ROLLBACK de sql/609_profile_ads_multi_group_owner_fix.sql
-- Solo correr en emergencia deliberada. Regresa a la versión LIMIT 1 (sin
-- ORDER BY) de sql/607 — vuelve a ser errática si un owner tiene varios
-- grupos.

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
    AND  (
      NOT EXISTS (SELECT 1 FROM public.groups adv WHERE adv.owner_id = a.advertiser_id)
      OR (
        SELECT (public.group_default_break_type(adv.id) IS NULL) IS DISTINCT FROM v_viewed_is_musician
        FROM public.groups adv WHERE adv.owner_id = a.advertiser_id LIMIT 1
      )
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
