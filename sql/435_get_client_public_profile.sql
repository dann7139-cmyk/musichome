-- ============================================================
-- sql/435_get_client_public_profile.sql
-- Perfil PÚBLICO del cliente para el grupo (solicitudes exprés)
--
-- Devuelve SOLO campos públicos POR CONSTRUCCIÓN: nombre, foto,
-- ciudad, rating como cliente (promedio + conteo de client_reviews,
-- calculado server-side) y antigüedad. SIN teléfono, SIN email —
-- la regla anti-robo de contacto vive en el contrato del RPC.
--
-- (Nota: hoy la RLS profiles_authenticated_read permitiría el select
-- directo con teléfono incluido — deuda de endurecimiento agendada.
-- Este RPC deja el contrato correcto desde ya y sobrevivirá a ese
-- endurecimiento.)
-- ============================================================

BEGIN;

CREATE OR REPLACE FUNCTION public.get_client_public_profile(p_client_id UUID)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_profile RECORD;
  v_rating  NUMERIC;
  v_count   INT;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'unauthorized: sesión requerida';
  END IF;

  SELECT p.full_name, p.avatar_url, p.city, p.created_at
  INTO   v_profile
  FROM   profiles p
  WHERE  p.id = p_client_id;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_found');
  END IF;

  SELECT ROUND(AVG(cr.rating)::numeric, 1), COUNT(*)::INT
  INTO   v_rating, v_count
  FROM   client_reviews cr
  WHERE  cr.client_id = p_client_id;

  RETURN jsonb_build_object(
    'ok',            true,
    'full_name',     v_profile.full_name,
    'avatar_url',    v_profile.avatar_url,
    'city',          v_profile.city,
    'rating',        v_rating,          -- null si aún no tiene reseñas
    'reviews_count', COALESCE(v_count, 0),
    'member_since',  v_profile.created_at
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.get_client_public_profile(UUID) TO authenticated;

COMMIT;

-- ── Verificaciones ────────────────────────────────────────────────────────────
-- V1: el payload NO contiene teléfono ni email (por construcción)
SELECT
  routine_definition NOT LIKE '%phone%' AS sin_telefono,
  routine_definition NOT LIKE '%email%' AS sin_email,
  routine_definition LIKE '%client_reviews%' AS con_rating
FROM information_schema.routines
WHERE routine_schema = 'public' AND routine_name = 'get_client_public_profile';
-- Esperado: true | true | true

-- V2 (funcional, disfrazado de cualquier usuario):
-- BEGIN;
-- SELECT set_config('request.jwt.claims', json_build_object(
--   'sub', (SELECT id::text FROM profiles LIMIT 1), 'role','authenticated')::text, true);
-- SELECT get_client_public_profile((SELECT id FROM profiles WHERE role='client' LIMIT 1));
-- ROLLBACK;
-- Esperado: {ok:true, full_name, avatar_url, city, rating, reviews_count, member_since}

SELECT '435_get_client_public_profile.sql ejecutado ✅' AS status;
