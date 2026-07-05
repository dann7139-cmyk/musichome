-- ============================================================
-- sql/436_reviews_with_avatars.sql
-- Reseñas con foto+nombre del reseñador (chiquitas en perfiles)
--
-- 1. get_group_reviews v2 — agrega client_avatar (foto del cliente
--    que reseñó al grupo). El cliente ve foto+nombre de otros
--    clientes en pequeño, pero NUNCA ampliable (regla de producto;
--    el frontend no expone visor para estas fotos).
--    RETURNS TABLE cambia → hay que DROP antes de recrear (42P13).
--    Definición COMPLETA y autocontenida (no parcha la de prod).
--
-- 2. get_client_public_reviews — NUEVA: reseñas que otros GRUPOS
--    dejaron al cliente (client_reviews), con nombre y foto del
--    grupo. La consume el perfil público del cliente que ve el
--    grupo (ClientProfileModal). Solo campos públicos: sin datos
--    de contacto por construcción.
-- ============================================================

BEGIN;

-- ── 1. get_group_reviews v2 (+ client_avatar) ────────────────────────────────
DROP FUNCTION IF EXISTS public.get_group_reviews(UUID, INT);

CREATE FUNCTION public.get_group_reviews(
  p_group_id UUID,
  p_limit    INT DEFAULT 20
)
RETURNS TABLE (
  review_id     UUID,
  rating        SMALLINT,
  comment       TEXT,
  created_at    TIMESTAMPTZ,
  client_name   TEXT,
  client_avatar TEXT
) LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
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
$$;

GRANT EXECUTE ON FUNCTION public.get_group_reviews(UUID, INT) TO authenticated, anon;

-- ── 2. get_client_public_reviews (reseñas de grupos hacia el cliente) ────────
CREATE OR REPLACE FUNCTION public.get_client_public_reviews(
  p_client_id UUID,
  p_limit     INT DEFAULT 10
)
RETURNS TABLE (
  review_id   UUID,
  rating      INTEGER,
  comment     TEXT,
  created_at  TIMESTAMPTZ,
  group_name  TEXT,
  group_photo TEXT
) LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'unauthorized: sesión requerida';
  END IF;

  RETURN QUERY
  SELECT
    cr.id,
    cr.rating,
    cr.comment,
    cr.created_at,
    COALESCE(g.name, 'Grupo')::TEXT AS group_name,
    g.profile_image::TEXT           AS group_photo
  FROM client_reviews cr
  LEFT JOIN groups g ON g.id = cr.group_id
  WHERE cr.client_id = p_client_id
  ORDER BY cr.created_at DESC
  LIMIT p_limit;
END;
$$;

GRANT EXECUTE ON FUNCTION public.get_client_public_reviews(UUID, INT) TO authenticated;

COMMIT;

-- ── Verificaciones ────────────────────────────────────────────────────────────
-- V1: firmas y columnas nuevas presentes
SELECT
  routine_definition LIKE '%client_avatar%' AS group_reviews_con_avatar
FROM information_schema.routines
WHERE routine_schema = 'public' AND routine_name = 'get_group_reviews';
-- Esperado: true

SELECT
  routine_definition LIKE '%profile_image%' AS client_reviews_con_foto_grupo,
  routine_definition NOT LIKE '%phone%'     AS sin_telefono
FROM information_schema.routines
WHERE routine_schema = 'public' AND routine_name = 'get_client_public_reviews';
-- Esperado: true | true

-- V2 (funcional): debe regresar filas si hay reseñas
-- SELECT * FROM get_group_reviews((SELECT id FROM groups LIMIT 1), 5);

SELECT '436_reviews_with_avatars.sql ejecutado ✅' AS status;
