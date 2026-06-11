-- ============================================================
-- sql/265_jalisco_test_groups_and_sync_owners.sql
--
-- 1. Dos grupos extra en Jalisco para probar filtros de estado.
-- 2. Sincroniza profiles.state / profiles.country para dueños
--    de grupos que ya tienen estado registrado en groups pero no
--    en su perfil (ej: Derek / Daniel Rivera).
--
-- Idempotente. ROLLBACK:
--   DELETE FROM auth.users WHERE email LIKE '%@mhtest.dev';
-- ============================================================

DO $$
DECLARE
  jal1 UUID;
  jal2 UUID;
  g9   UUID;
  g10  UUID;
BEGIN

  -- ── Reutilizar o crear usuarios de prueba ────────────────────────────────
  jal1 := COALESCE((SELECT id FROM auth.users WHERE email = 'jalisco1@mhtest.dev'), gen_random_uuid());
  jal2 := COALESCE((SELECT id FROM auth.users WHERE email = 'jalisco2@mhtest.dev'), gen_random_uuid());

  g9  := COALESCE((SELECT id FROM public.groups WHERE owner_id = jal1), gen_random_uuid());
  g10 := COALESCE((SELECT id FROM public.groups WHERE owner_id = jal2), gen_random_uuid());

  -- Auth users
  INSERT INTO auth.users (
    id, email, encrypted_password,
    email_confirmed_at, created_at, updated_at,
    raw_app_meta_data, raw_user_meta_data,
    aud, role, is_super_admin
  )
  VALUES
    (jal1, 'jalisco1@mhtest.dev', crypt('Test1234!', gen_salt('bf')), now(), now(), now(), '{"provider":"email","providers":["email"]}', '{}', 'authenticated', 'authenticated', false),
    (jal2, 'jalisco2@mhtest.dev', crypt('Test1234!', gen_salt('bf')), now(), now(), now(), '{"provider":"email","providers":["email"]}', '{}', 'authenticated', 'authenticated', false)
  ON CONFLICT (id) DO NOTHING;

  -- Profiles
  INSERT INTO public.profiles (id, full_name, role, state, country, phone, verification_status, admin_verified, created_at)
  VALUES
    (jal1, 'Roberto Lara',  'group', 'Jalisco', 'México', '3331110001', 'approved', true,  now() - interval '3 months'),
    (jal2, 'Claudia Soto',  'group', 'Jalisco', 'México', '3332220002', 'none',     false, now() - interval '1 month')
  ON CONFLICT (id) DO UPDATE SET
    full_name           = EXCLUDED.full_name,
    role                = EXCLUDED.role,
    state               = EXCLUDED.state,
    country             = EXCLUDED.country,
    admin_verified      = EXCLUDED.admin_verified;

  -- Grupos
  INSERT INTO public.groups (
    id, name, city, state, genre, description,
    is_verified, admin_verified, is_active,
    rating, total_reviews, owner_id,
    verification_status, strike_count, created_at
  )
  VALUES
    (g9,  'Trio Tapatío',    'Guadalajara', 'Jalisco', 'Mariachi',  'Trio de cuerdas tradicional para bodas y serenatas en Jalisco.',  true,  true,  true,  4.8, 22, jal1, 'approved', 0, now() - interval '3 months'),
    (g10, 'Jarana Jalisco',  'Zapopan',     'Jalisco', 'Versátil',  'Grupo versátil para fiestas, quinceañeras y eventos en Zapopan.', false, false, true,  4.2,  6, jal2, 'none',     0, now() - interval '1 month')
  ON CONFLICT (id) DO UPDATE SET
    name                = EXCLUDED.name,
    city                = EXCLUDED.city,
    state               = EXCLUDED.state,
    genre               = EXCLUDED.genre,
    description         = EXCLUDED.description,
    is_verified         = EXCLUDED.is_verified,
    admin_verified      = EXCLUDED.admin_verified,
    is_active           = EXCLUDED.is_active,
    rating              = EXCLUDED.rating,
    total_reviews       = EXCLUDED.total_reviews,
    verification_status = EXCLUDED.verification_status;

  RAISE NOTICE '2 grupos de prueba en Jalisco creados/actualizados ✅';
END;
$$;

-- ── Sincronizar state+country de dueños que tienen grupo con estado
--    pero su perfil no lo tiene. Afecta a Derek y cualquier otro caso igual.
UPDATE public.profiles p
SET
  state   = g.state,
  country = COALESCE(p.country, g.country, 'México')
FROM public.groups g
WHERE g.owner_id     = p.id
  AND g.state        IS NOT NULL
  AND g.state        != ''
  AND (p.state IS NULL OR p.state = '');

-- ── Verificación ─────────────────────────────────────────────────────────────
SELECT
  g.name   AS grupo,
  g.city   AS ciudad,
  g.state  AS estado_grupo,
  p.state  AS estado_perfil,
  p.country AS pais_perfil
FROM public.groups g
JOIN public.profiles p ON p.id = g.owner_id
WHERE g.state = 'Jalisco'
ORDER BY g.created_at DESC;
