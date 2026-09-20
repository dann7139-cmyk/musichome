-- sql/671_destacado_349_recomendado_499.sql
--
-- Ajuste final de precios de autoservicio (2026-09-19), tras varias
-- rondas con el usuario viendo la vista previa de DestacadoScreen.tsx:
-- $1,098 → $599 (sql/670) → esta vez a $349/mes. Recomendado mensual
-- también baja de $1,299 a $499/mes (ese número vive en el edge function
-- create-promo-subscription, no en esta migración — ver commit del
-- código de esa función). Se mantiene la regla ya establecida:
-- Recomendado cuesta más que Destacado a propósito.
--
-- Único cambio en BD: v_price15 de sponsored_group en calculate_ad_price
-- (299.5 → 174.5). DestacadoScreen.tsx siempre pide 30 días →
-- 30*(174.5/15) = $349.00 exacto (verificado en sandbox antes de aplicar).
--
-- No afecta profile_ad ni banner_home.
--
-- Rollback: sql/671_destacado_349_recomendado_499_ROLLBACK.sql (regresa a 299.5 / $599)

CREATE OR REPLACE FUNCTION public.calculate_ad_price(p_type text, p_duration_days integer, p_location_type text DEFAULT 'city'::text, p_is_video boolean DEFAULT false)
 RETURNS numeric
 LANGUAGE plpgsql
 IMMUTABLE
AS $function$
DECLARE
  v_price3 NUMERIC; v_price7 NUMERIC; v_price15 NUMERIC;
  v_base NUMERIC; v_loc_mult NUMERIC; v_video_mult NUMERIC := 1.0;
  v_days INT := GREATEST(COALESCE(p_duration_days, 7), 1);
BEGIN
  CASE p_type
    WHEN 'profile_ad'      THEN v_price3 := 129; v_price7 := 249; v_price15 := 449;
    WHEN 'sponsored_group' THEN v_price3 := 169; v_price7 := 299; v_price15 := 174.5;
    WHEN 'banner_home'     THEN v_price3 := 229; v_price7 := 399; v_price15 := 749;
    ELSE RAISE EXCEPTION 'invalid_ad_type: %', p_type;
  END CASE;

  IF v_days <= 3 THEN v_base := v_days * (v_price3 / 3.0);
  ELSIF v_days <= 7 THEN v_base := v_days * (v_price7 / 7.0);
  ELSE v_base := v_days * (v_price15 / 15.0);
  END IF;

  v_loc_mult := CASE COALESCE(p_location_type, 'city')
    WHEN 'city' THEN 1.0 WHEN 'multi_city' THEN 1.5
    WHEN 'national' THEN 2.0 WHEN 'international' THEN 3.5
    ELSE 1.0
  END;

  IF p_is_video AND p_type IN ('banner_home', 'profile_ad') THEN
    v_video_mult := 1.35;
  END IF;

  RETURN ROUND(v_base * v_loc_mult * v_video_mult, 2);
END;
$function$;

SELECT calculate_ad_price('sponsored_group', 30, 'city', false) AS precio_30d_debe_ser_349;
SELECT '671_destacado_349_recomendado_499 ✅' AS status;
