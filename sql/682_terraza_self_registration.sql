-- ============================================================================
-- 682 — Las terrazas pueden registrarse solas
-- ============================================================================
-- Petición real (2026-09-23): "de hecho estaba pensando que será bueno que se
-- registren solos" (aprobar una por una "será un caos si son muchos").
--
-- sql/681 ya dejó 'Terraza' como categoría y arregló el país. Falta la última
-- pieza: `submit_provider_application` tiene una lista blanca de categorías
-- en el servidor y 'terraza' NO está en ella — una terraza que tocara el chip
-- nuevo recibiría "Elige una categoría válida" y no podría inscribirse.
--
-- ÚNICO cambio: agregar 'terraza' a esa lista. Todo lo demás de la función
-- (límite de 3 pendientes por teléfono en 24h, recorte de longitudes,
-- notificación a admin/admin_ops respetando el mute de país) queda
-- byte-idéntico.
--
-- La lista se deja explícita a propósito y NO se reemplaza por
-- "genre_category_key(...) IS NOT NULL": son dos cosas distintas — ésta es la
-- lista de categorías en las que se ACEPTAN solicitudes, y conviene poder
-- cerrar una sin tener que quitarla del Explorador.
-- ============================================================================

BEGIN;

CREATE OR REPLACE FUNCTION public.submit_provider_application(
  p_full_name text,
  p_phone text,
  p_category text,
  p_years_experience integer DEFAULT NULL::integer,
  p_min_hours numeric DEFAULT NULL::numeric,
  p_country text DEFAULT NULL::text,
  p_state text DEFAULT NULL::text,
  p_city text DEFAULT NULL::text,
  p_notes text DEFAULT NULL::text
)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_id uuid;
  v_cc text;
BEGIN
  IF p_full_name IS NULL OR trim(p_full_name) = '' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'missing_full_name');
  END IF;
  IF p_phone IS NULL OR trim(p_phone) = '' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'missing_phone');
  END IF;
  IF p_category IS NULL OR p_category NOT IN
     ('grupo','solista','dj','comediante','espectaculo','mc','luzSonido','comida','renta','fotografos',
      'terraza')
  THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_category');
  END IF;

  IF (SELECT count(*) FROM public.provider_applications
      WHERE phone = trim(p_phone) AND status = 'pending' AND created_at > now() - interval '1 day') >= 3 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'too_many_pending');
  END IF;

  INSERT INTO public.provider_applications
    (full_name, phone, category, years_experience, min_hours, country, state, city, notes)
  VALUES
    (LEFT(trim(p_full_name), 120), LEFT(trim(p_phone), 30), p_category,
     p_years_experience, p_min_hours,
     NULLIF(LEFT(trim(COALESCE(p_country,'')), 60), ''),
     NULLIF(LEFT(trim(COALESCE(p_state,'')), 60), ''),
     NULLIF(LEFT(trim(COALESCE(p_city,'')), 60), ''),
     NULLIF(LEFT(trim(COALESCE(p_notes,'')), 500), ''))
  RETURNING id INTO v_id;

  v_cc := public.country_code_of(p_country);
  INSERT INTO public.notifications (user_id, type, title, body, data)
  SELECT p.id, 'provider_application',
    '📝 Nueva solicitud de proveedor — ' || LEFT(trim(p_full_name), 120),
    format('%s pidió unirse (%s). Tel: %s.', LEFT(trim(p_full_name),120), p_category, LEFT(trim(p_phone),30)),
    jsonb_build_object('application_id', v_id, 'screen', 'AdminProviderApplications')
  FROM public.profiles p
  WHERE (p.role = 'admin' AND NOT public.admin_is_country_muted(p_country, p.id))
     OR (p.role = 'admin_ops' AND p.admin_country_scope = v_cc);

  RETURN jsonb_build_object('ok', true, 'application_id', v_id);
END;
$$;

COMMIT;
