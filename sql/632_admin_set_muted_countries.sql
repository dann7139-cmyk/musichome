-- sql/632_admin_set_muted_countries.sql
--
-- Interruptor de la cuenta admin completa para dejar de recibir alertas
-- de un país (una vez que haya un admin_ops contratado ahí). RPC dedicado
-- en vez de dejar que el cliente actualice profiles.admin_muted_countries
-- directo — mismo patrón de todo el proyecto: la escritura vive en un
-- RPC que valida, no en un UPDATE de tabla libre.
BEGIN;

CREATE OR REPLACE FUNCTION public.admin_set_muted_countries(p_countries text[])
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_caller_role TEXT;
  v_country     TEXT;
BEGIN
  SELECT role INTO v_caller_role FROM profiles WHERE id = auth.uid();
  IF v_caller_role <> 'admin' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_admin');
  END IF;

  FOREACH v_country IN ARRAY COALESCE(p_countries, '{}') LOOP
    IF v_country NOT IN ('US', 'CA') THEN
      RETURN jsonb_build_object('ok', false, 'error', 'invalid_country', 'country', v_country);
    END IF;
  END LOOP;

  UPDATE profiles SET admin_muted_countries = COALESCE(p_countries, '{}')
  WHERE id = auth.uid();

  RETURN jsonb_build_object('ok', true, 'muted_countries', COALESCE(p_countries, '{}'));
END;
$function$;

COMMIT;
