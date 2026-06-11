-- 320_location_improvements.sql
-- Extiende update_my_location para aceptar p_country.
-- Arquitectura País → Estado: state y country son los campos principales;
-- city es auxiliar (métricas, publicidad por ciudad).

CREATE OR REPLACE FUNCTION public.update_my_location(
  p_city    TEXT DEFAULT NULL,
  p_state   TEXT DEFAULT NULL,
  p_country TEXT DEFAULT NULL
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  UPDATE public.profiles
  SET
    city    = COALESCE(LOWER(TRIM(p_city)),    city),
    state   = COALESCE(p_state,                state),
    country = COALESCE(p_country,              country),
    updated_at = NOW()
  WHERE id = auth.uid();
END;
$$;

-- Revocar versión anterior (2 parámetros) si existe como función independiente
-- y asegurar que authenticated pueda ejecutar la nueva firma (3 parámetros).
GRANT EXECUTE ON FUNCTION public.update_my_location(TEXT, TEXT, TEXT) TO authenticated;
