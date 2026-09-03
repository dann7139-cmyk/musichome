-- ============================================================
-- 557_fix_get_group_reviews_type.sql
--
-- BUG CONFIRMADO: get_group_reviews declara su columna de retorno
-- `rating` como smallint, pero reviews.rating es integer. Postgres
-- rechaza la función con error 42804 ("structure of query does not
-- match function result type") en TODA llamada, para cualquier grupo.
-- Confirmado en vivo: SELECT * FROM get_group_reviews(<grupo real>, 10)
-- truena con ese error exacto.
--
-- IMPACTO: el frontend (GroupDetailScreen.tsx) captura el error y cae
-- a un plan B (lectura directa de la tabla reviews, que sí funciona,
-- confirmado con las 2 reseñas reales del grupo de referencia) — así
-- que hoy las reseñas probablemente SÍ se ven, pero vía una llamada
-- que siempre falla primero. Se corrige para que el camino principal
-- funcione de verdad.
--
-- CAMBIO (único): rating smallint → rating integer en el tipo de
-- retorno. El cuerpo de la función no cambia en absoluto.
-- ============================================================

BEGIN;

DO $$
DECLARE
  v_hash TEXT;
BEGIN
  SELECT md5(prosrc) INTO v_hash FROM pg_proc WHERE proname='get_group_reviews' AND pronamespace='public'::regnamespace;
  IF v_hash IS NULL THEN
    RAISE EXCEPTION 'ABORT: get_group_reviews no existe en esta base';
  END IF;
  RAISE NOTICE 'Pre-check: hash actual de get_group_reviews = %', v_hash;
END $$;

-- No se puede usar CREATE OR REPLACE para cambiar el tipo de una columna
-- de retorno TABLE(...) — Postgres lo rechaza (42P13). DROP primero,
-- dentro de la misma transacción que el CREATE de abajo.
DROP FUNCTION public.get_group_reviews(uuid, integer);

CREATE FUNCTION public.get_group_reviews(p_group_id uuid, p_limit integer)
RETURNS TABLE(
  id          uuid,
  rating      integer,
  comment     text,
  created_at  timestamptz,
  client_name text,
  client_avatar text
)
LANGUAGE plpgsql
AS $function$
BEGIN
  RETURN QUERY
  SELECT
    rv.id,
    rv.rating,
    rv.comment,
    rv.created_at,
    COALESCE(p.full_name, 'Cliente')::TEXT AS client_name,
    p.avatar_url::TEXT                     AS client_avatar
  FROM reviews rv
  LEFT JOIN profiles p ON p.id = rv.client_id
  WHERE rv.group_id = p_group_id
  ORDER BY rv.created_at DESC
  LIMIT p_limit;
END;
$function$;

-- DROP FUNCTION quita todos los GRANTs previos — se restauran explícitamente
-- (antes tenía EXECUTE para service_role, authenticated, anon, postgres, PUBLIC).
GRANT EXECUTE ON FUNCTION public.get_group_reviews(uuid, integer) TO authenticated, anon, service_role;

COMMIT;

-- ============================================================
-- VERIFICACIÓN (ejecutar por separado después del COMMIT)
-- ============================================================
-- SELECT * FROM get_group_reviews('83911568-2694-4541-81ae-af1f80bc490e'::uuid, 10);
-- Esperado: 2 filas, sin error.

SELECT '557_fix_get_group_reviews_type preparado' AS status;
