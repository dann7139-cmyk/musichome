-- ============================================================================
-- ROLLBACK de 682 — NO CORRER salvo emergencia deliberada
-- ============================================================================
-- Quita 'terraza' de la lista blanca de solicitudes de proveedor: las
-- terrazas dejan de poder registrarse solas (el chip seguiría visible en la
-- app y daría "Elige una categoría válida").
-- Las solicitudes de terraza YA enviadas no se borran ni se invalidan: se
-- pueden seguir aprobando con admin_approve_provider_application.
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
     ('grupo','solista','dj','comediante','espectaculo','mc','luzSonido','comida','renta','fotografos') THEN
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
