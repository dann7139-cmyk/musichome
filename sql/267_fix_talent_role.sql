-- ============================================================
-- sql/267_fix_talent_role.sql
--
-- Corrige el rol de talent@music10.com de 'client' → 'talent'
-- y crea su job_board_profile si no existe.
-- ============================================================

DO $$
DECLARE
  v_uid UUID;
BEGIN
  -- Obtener el UUID del usuario
  SELECT id INTO v_uid
  FROM auth.users
  WHERE email = 'talent@music10.com'
  LIMIT 1;

  IF v_uid IS NULL THEN
    RAISE NOTICE 'Usuario talent@music10.com no encontrado en auth.users';
    RETURN;
  END IF;

  -- Cambiar rol a talent
  UPDATE public.profiles
  SET
    role       = 'talent',
    updated_at = NOW()
  WHERE id = v_uid;

  RAISE NOTICE 'Rol actualizado a talent para uid=%', v_uid;

  -- Crear job_board_profile si no existe
  INSERT INTO public.job_board_profiles (
    user_id, instrument_or_role, bio,
    experience_years, availability_status, is_visible
  )
  VALUES (
    v_uid, 'Músico', 'Perfil artístico pendiente de completar.',
    0, 'available', true
  )
  ON CONFLICT (user_id) DO NOTHING;

  RAISE NOTICE 'job_board_profile listo para uid=%', v_uid;
END;
$$;

-- Verificación
SELECT id, email, raw_user_meta_data
FROM auth.users WHERE email = 'talent@music10.com';

SELECT id, full_name, role, city, state, country
FROM public.profiles
WHERE id = (SELECT id FROM auth.users WHERE email = 'talent@music10.com');

SELECT 'SQL 267 ejecutado ✅' AS status;
