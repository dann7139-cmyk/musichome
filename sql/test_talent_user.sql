-- ============================================================
-- sql/test_talent_user.sql
-- Crea UN usuario de prueba con rol 'talent'
-- Solo inserta datos — NO altera estructura, RLS ni funciones
--
-- Credenciales resultantes:
--   Email:    talento@musicome.com
--   Password: MusicTest2024!
--
-- Ejecutar en: Supabase Dashboard → SQL Editor
-- ============================================================

DO $$
DECLARE
  v_user_id UUID := gen_random_uuid();
BEGIN

  -- ── 1. Crear usuario en auth.users ──────────────────────────────────────────
  --    email_confirmed_at = NOW() → no requiere verificación de correo
  INSERT INTO auth.users (
    id,
    instance_id,
    aud,
    role,
    email,
    encrypted_password,
    email_confirmed_at,
    raw_app_meta_data,
    raw_user_meta_data,
    created_at,
    updated_at,
    confirmation_token,
    recovery_token,
    is_sso_user,
    deleted_at
  )
  VALUES (
    v_user_id,
    '00000000-0000-0000-0000-000000000000',
    'authenticated',
    'authenticated',
    'talento@musicome.com',
    crypt('MusicTest2024!', gen_salt('bf')),
    NOW(),
    '{"provider":"email","providers":["email"]}'::jsonb,
    '{"full_name":"Carlos Monterrey","role":"talent"}'::jsonb,
    NOW(),
    NOW(),
    '',
    '',
    FALSE,
    NULL
  );

  -- ── 2. auth.identities — necesario para login con email/password ────────────
  INSERT INTO auth.identities (
    id,
    user_id,
    identity_data,
    provider,
    provider_id,
    last_sign_in_at,
    created_at,
    updated_at
  )
  VALUES (
    gen_random_uuid(),
    v_user_id,
    jsonb_build_object('sub', v_user_id::text, 'email', 'talento@musicome.com'),
    'email',
    'talento@musicome.com',
    NOW(),
    NOW(),
    NOW()
  );

  -- ── 3. profiles — respaldo si el trigger handle_new_user no se ejecutó ───────
  --    ON CONFLICT DO NOTHING: si el trigger ya creó la fila, no hace nada
  INSERT INTO public.profiles (
    id,
    email,
    full_name,
    role,
    phone_verified,
    id_verified
  )
  VALUES (
    v_user_id,
    'talento@musicome.com',
    'Carlos Monterrey',
    'talent',
    FALSE,
    FALSE
  )
  ON CONFLICT (id) DO NOTHING;

  -- ── 4. job_board_profiles — respaldo si handle_new_talent no se ejecutó ──────
  INSERT INTO public.job_board_profiles (
    user_id,
    instrument_or_role,
    bio,
    experience_years,
    is_visible,
    availability_status
  )
  VALUES (
    v_user_id,
    'Guitarrista',
    'Guitarrista con experiencia en rock, pop y cumbia. Disponible para eventos y grabaciones.',
    5,
    TRUE,
    'available'
  )
  ON CONFLICT (user_id) DO NOTHING;

  RAISE NOTICE '✅ Talento creado — email: talento@musicome.com | password: MusicTest2024! | id: %', v_user_id;
END;
$$;

-- ── Verificación ─────────────────────────────────────────────────────────────
-- Confirma que todo quedó bien después de ejecutar:

SELECT
  p.id,
  p.email,
  p.full_name,
  p.role,
  jp.instrument_or_role,
  jp.experience_years,
  jp.is_visible,
  jp.availability_status
FROM public.profiles p
JOIN public.job_board_profiles jp ON jp.user_id = p.id
WHERE p.email = 'talento@musicome.com';
