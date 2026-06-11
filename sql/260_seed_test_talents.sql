-- ============================================================
-- sql/260_seed_test_talents.sql
--
-- SOLO PARA PRUEBAS DE DESARROLLO. NO ejecutar en producción.
--
-- Crea 2 talentos de prueba para ver el tab "Talentos" en
-- AdminVerificationsScreen con datos reales.
--
--   Talento 1 — Ana García Torres
--     · verification_status = 'pending'
--     · tiene id_document_url (chip "Documento subido" activo)
--     · verificacion_submitted_at hace 2 días
--     · muestra botones Verificar / Rechazar
--
--   Talento 2 — Carlos Mendoza Ruiz
--     · verification_status = 'none'
--     · sin docs ni selfie
--     · muestra estado base sin acción pendiente
--
-- ROLLBACK:
--   DELETE FROM public.profiles
--     WHERE id IN (
--       '11111111-1111-1111-1111-111111111101',
--       '11111111-1111-1111-1111-111111111102'
--     );
--   DELETE FROM auth.users
--     WHERE email IN (
--       'talento1@test.daricefy.com',
--       'talento2@test.daricefy.com'
--     );
-- ============================================================

-- ─────────────────────────────────────────────────────────────────────────────
-- § 0  Columnas faltantes en profiles (de sql/06_client_verification.sql)
--      Usa IF NOT EXISTS: no hace daño si ya existen.
-- ─────────────────────────────────────────────────────────────────────────────

ALTER TABLE public.profiles
  ADD COLUMN IF NOT EXISTS city TEXT;

ALTER TABLE public.profiles
  ADD COLUMN IF NOT EXISTS state TEXT;

ALTER TABLE public.profiles
  ADD COLUMN IF NOT EXISTS verification_status TEXT DEFAULT 'none'
    CHECK (verification_status IN ('none','pending','approved','rejected'));

ALTER TABLE public.profiles
  ADD COLUMN IF NOT EXISTS id_document_url TEXT;

ALTER TABLE public.profiles
  ADD COLUMN IF NOT EXISTS selfie_url TEXT;

ALTER TABLE public.profiles
  ADD COLUMN IF NOT EXISTS verification_submitted_at TIMESTAMP WITH TIME ZONE;

ALTER TABLE public.profiles
  ADD COLUMN IF NOT EXISTS verification_reviewed_at TIMESTAMP WITH TIME ZONE;

ALTER TABLE public.profiles
  ADD COLUMN IF NOT EXISTS verification_admin_notes TEXT;


DO $$
DECLARE
  v_uid1 CONSTANT UUID := '11111111-1111-1111-1111-111111111101';
  v_uid2 CONSTANT UUID := '11111111-1111-1111-1111-111111111102';
BEGIN

  -- ── 1. Insertar auth users ────────────────────────────────────────
  --    ON CONFLICT DO NOTHING: idempotente si ya existen.
  --    La contraseña de prueba es: Test1234!
  INSERT INTO auth.users (
    id, instance_id, aud, role, email,
    encrypted_password,
    email_confirmed_at,
    raw_app_meta_data,
    raw_user_meta_data,
    created_at, updated_at,
    confirmation_token, recovery_token,
    email_change_token_new, email_change
  )
  VALUES
    (
      v_uid1,
      '00000000-0000-0000-0000-000000000000',
      'authenticated', 'authenticated',
      'talento1@test.daricefy.com',
      crypt('Test1234!', gen_salt('bf')),
      now(),
      '{"provider":"email","providers":["email"]}'::jsonb,
      '{"full_name":"Ana García Torres","role":"talent"}'::jsonb,
      now(), now(), '', '', '', ''
    ),
    (
      v_uid2,
      '00000000-0000-0000-0000-000000000000',
      'authenticated', 'authenticated',
      'talento2@test.daricefy.com',
      crypt('Test1234!', gen_salt('bf')),
      now(),
      '{"provider":"email","providers":["email"]}'::jsonb,
      '{"full_name":"Carlos Mendoza Ruiz","role":"talent"}'::jsonb,
      now(), now(), '', '', '', ''
    )
  ON CONFLICT (id) DO NOTHING;

  -- ── 2. Insertar / actualizar perfiles ─────────────────────────────
  --    Upsert por id: si el trigger on_auth_user_created ya los creó
  --    como 'client', los actualiza a 'talent' con los datos de prueba.
  INSERT INTO public.profiles (
    id,
    full_name,
    role,
    city,
    state,
    country,
    phone,
    verification_status,
    admin_verified,
    verification_submitted_at,
    id_document_url,
    selfie_url,
    created_at
  )
  VALUES
    (
      v_uid1,
      'Ana García Torres',
      'talent',
      'Guadalajara', 'Jalisco', 'México',
      '3312345678',
      'pending',
      false,
      now() - interval '2 days',
      'kyc_test_ana_doc.jpg',   -- path ficticio para chip "Documento subido"
      null,                      -- sin selfie
      now() - interval '5 days'
    ),
    (
      v_uid2,
      'Carlos Mendoza Ruiz',
      'talent',
      'Ciudad de México', 'CDMX', 'México',
      '5512345678',
      'none',
      false,
      null,
      null,
      null,
      now() - interval '3 days'
    )
  ON CONFLICT (id) DO UPDATE SET
    full_name                 = EXCLUDED.full_name,
    role                      = EXCLUDED.role,
    city                      = EXCLUDED.city,
    state                     = EXCLUDED.state,
    country                   = EXCLUDED.country,
    phone                     = EXCLUDED.phone,
    verification_status       = EXCLUDED.verification_status,
    admin_verified            = EXCLUDED.admin_verified,
    verification_submitted_at = EXCLUDED.verification_submitted_at,
    id_document_url           = EXCLUDED.id_document_url,
    selfie_url                = EXCLUDED.selfie_url;

  RAISE NOTICE '[260] Talentos de prueba insertados:';
  RAISE NOTICE '      Ana García Torres   → % (pending, con doc)', v_uid1;
  RAISE NOTICE '      Carlos Mendoza Ruiz → % (none, sin docs)',   v_uid2;
  RAISE NOTICE '      Login: talento1@test.daricefy.com / Test1234!';
  RAISE NOTICE '      Login: talento2@test.daricefy.com / Test1234!';

END;
$$;

-- Verificación
DO $$
DECLARE
  v_count INT;
BEGIN
  SELECT COUNT(*) INTO v_count
  FROM public.profiles
  WHERE id IN (
    '11111111-1111-1111-1111-111111111101',
    '11111111-1111-1111-1111-111111111102'
  )
    AND role = 'talent';

  IF v_count < 2 THEN
    RAISE EXCEPTION '[260] Solo se insertaron % de 2 perfiles esperados ❌', v_count;
  END IF;
  RAISE NOTICE '[260] % perfiles de talento confirmados en BD ✅', v_count;
END;
$$;

SELECT '[260] Seed de talentos de prueba ejecutado ✅' AS status;
