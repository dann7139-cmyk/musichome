-- ============================================================
-- sql/261_test_groups_and_talents.sql
--
-- Datos de prueba: 8 grupos (5 MX + 3 USA) + 5 talentos
-- Idempotente: se puede re-ejecutar sin errores.
--
-- Solo para desarrollo / beta — NO ejecutar en producción real.
--
-- ROLLBACK:
--   DELETE FROM auth.users WHERE email LIKE '%@mhtest.dev';
-- ============================================================

DO $$
DECLARE
  -- IDs de dueños de grupos y talentos (se reusan si ya existen)
  go1 UUID; go2 UUID; go3 UUID; go4 UUID; go5 UUID;
  go6 UUID; go7 UUID; go8 UUID;
  t1  UUID; t2  UUID; t3  UUID; t4  UUID; t5  UUID;
  -- IDs de grupos
  g1  UUID; g2  UUID; g3  UUID; g4  UUID; g5  UUID;
  g6  UUID; g7  UUID; g8  UUID;
BEGIN

  -- ── Pre-cargar IDs de usuarios existentes (o generar nuevos) ───────────────
  go1 := COALESCE((SELECT id FROM auth.users WHERE email = 'owner1@mhtest.dev'), gen_random_uuid());
  go2 := COALESCE((SELECT id FROM auth.users WHERE email = 'owner2@mhtest.dev'), gen_random_uuid());
  go3 := COALESCE((SELECT id FROM auth.users WHERE email = 'owner3@mhtest.dev'), gen_random_uuid());
  go4 := COALESCE((SELECT id FROM auth.users WHERE email = 'owner4@mhtest.dev'), gen_random_uuid());
  go5 := COALESCE((SELECT id FROM auth.users WHERE email = 'owner5@mhtest.dev'), gen_random_uuid());
  go6 := COALESCE((SELECT id FROM auth.users WHERE email = 'owner6@mhtest.dev'), gen_random_uuid());
  go7 := COALESCE((SELECT id FROM auth.users WHERE email = 'owner7@mhtest.dev'), gen_random_uuid());
  go8 := COALESCE((SELECT id FROM auth.users WHERE email = 'owner8@mhtest.dev'), gen_random_uuid());
  t1  := COALESCE((SELECT id FROM auth.users WHERE email = 'talent1@mhtest.dev'), gen_random_uuid());
  t2  := COALESCE((SELECT id FROM auth.users WHERE email = 'talent2@mhtest.dev'), gen_random_uuid());
  t3  := COALESCE((SELECT id FROM auth.users WHERE email = 'talent3@mhtest.dev'), gen_random_uuid());
  t4  := COALESCE((SELECT id FROM auth.users WHERE email = 'talent4@mhtest.dev'), gen_random_uuid());
  t5  := COALESCE((SELECT id FROM auth.users WHERE email = 'talent5@mhtest.dev'), gen_random_uuid());

  -- Pre-cargar IDs de grupos existentes (o generar nuevos)
  g1 := COALESCE((SELECT id FROM public.groups WHERE owner_id = go1), gen_random_uuid());
  g2 := COALESCE((SELECT id FROM public.groups WHERE owner_id = go2), gen_random_uuid());
  g3 := COALESCE((SELECT id FROM public.groups WHERE owner_id = go3), gen_random_uuid());
  g4 := COALESCE((SELECT id FROM public.groups WHERE owner_id = go4), gen_random_uuid());
  g5 := COALESCE((SELECT id FROM public.groups WHERE owner_id = go5), gen_random_uuid());
  g6 := COALESCE((SELECT id FROM public.groups WHERE owner_id = go6), gen_random_uuid());
  g7 := COALESCE((SELECT id FROM public.groups WHERE owner_id = go7), gen_random_uuid());
  g8 := COALESCE((SELECT id FROM public.groups WHERE owner_id = go8), gen_random_uuid());

  -- ── Auth users ─────────────────────────────────────────────────────────────
  INSERT INTO auth.users (
    id, email, encrypted_password,
    email_confirmed_at, created_at, updated_at,
    raw_app_meta_data, raw_user_meta_data,
    aud, role, is_super_admin
  )
  VALUES
    (go1, 'owner1@mhtest.dev',  crypt('Test1234!', gen_salt('bf')), now(), now(), now(), '{"provider":"email","providers":["email"]}', '{}', 'authenticated', 'authenticated', false),
    (go2, 'owner2@mhtest.dev',  crypt('Test1234!', gen_salt('bf')), now(), now(), now(), '{"provider":"email","providers":["email"]}', '{}', 'authenticated', 'authenticated', false),
    (go3, 'owner3@mhtest.dev',  crypt('Test1234!', gen_salt('bf')), now(), now(), now(), '{"provider":"email","providers":["email"]}', '{}', 'authenticated', 'authenticated', false),
    (go4, 'owner4@mhtest.dev',  crypt('Test1234!', gen_salt('bf')), now(), now(), now(), '{"provider":"email","providers":["email"]}', '{}', 'authenticated', 'authenticated', false),
    (go5, 'owner5@mhtest.dev',  crypt('Test1234!', gen_salt('bf')), now(), now(), now(), '{"provider":"email","providers":["email"]}', '{}', 'authenticated', 'authenticated', false),
    (t1,  'talent1@mhtest.dev', crypt('Test1234!', gen_salt('bf')), now(), now(), now(), '{"provider":"email","providers":["email"]}', '{}', 'authenticated', 'authenticated', false),
    (t2,  'talent2@mhtest.dev', crypt('Test1234!', gen_salt('bf')), now(), now(), now(), '{"provider":"email","providers":["email"]}', '{}', 'authenticated', 'authenticated', false),
    (t3,  'talent3@mhtest.dev', crypt('Test1234!', gen_salt('bf')), now(), now(), now(), '{"provider":"email","providers":["email"]}', '{}', 'authenticated', 'authenticated', false),
    (t4,  'talent4@mhtest.dev', crypt('Test1234!', gen_salt('bf')), now(), now(), now(), '{"provider":"email","providers":["email"]}', '{}', 'authenticated', 'authenticated', false),
    (t5,  'talent5@mhtest.dev', crypt('Test1234!', gen_salt('bf')), now(), now(), now(), '{"provider":"email","providers":["email"]}', '{}', 'authenticated', 'authenticated', false),
    (go6, 'owner6@mhtest.dev',  crypt('Test1234!', gen_salt('bf')), now(), now(), now(), '{"provider":"email","providers":["email"]}', '{}', 'authenticated', 'authenticated', false),
    (go7, 'owner7@mhtest.dev',  crypt('Test1234!', gen_salt('bf')), now(), now(), now(), '{"provider":"email","providers":["email"]}', '{}', 'authenticated', 'authenticated', false),
    (go8, 'owner8@mhtest.dev',  crypt('Test1234!', gen_salt('bf')), now(), now(), now(), '{"provider":"email","providers":["email"]}', '{}', 'authenticated', 'authenticated', false)
  ON CONFLICT (id) DO NOTHING;

  -- ── Profiles dueños de grupos ───────────────────────────────────────────────
  INSERT INTO public.profiles (id, full_name, role, state, country, phone, verification_status, admin_verified, created_at)
  VALUES
    (go1, 'Ana Torres',    'group', 'CDMX',            'México',         '5551001001', 'approved', true,  now() - interval '8 months'),
    (go2, 'Luis Mendoza',  'group', 'Jalisco',          'México',         '3331002002', 'approved', false, now() - interval '5 months'),
    (go3, 'Sofía Ramírez', 'group', 'Nuevo León',       'México',         '8181003003', 'none',     false, now() - interval '2 months'),
    (go4, 'Marco Vega',    'group', 'Puebla',           'México',         '2221004004', 'none',     false, now() - interval '1 month'),
    (go5, 'Diana Cruz',    'group', 'Baja California',  'México',         '6641005005', 'pending',  false, now() - interval '3 weeks'),
    (go6, 'James Carter',  'group', 'California',       'Estados Unidos', '3235001001', 'approved', true,  now() - interval '6 months'),
    (go7, 'Maria Garcia',  'group', 'Texas',            'Estados Unidos', '7135002002', 'approved', false, now() - interval '4 months'),
    (go8, 'David Kim',     'group', 'New York',         'Estados Unidos', '2125003003', 'none',     false, now() - interval '2 months')
  ON CONFLICT (id) DO UPDATE SET
    full_name           = EXCLUDED.full_name,
    role                = EXCLUDED.role,
    state               = EXCLUDED.state,
    country             = EXCLUDED.country,
    phone               = EXCLUDED.phone,
    verification_status = EXCLUDED.verification_status,
    admin_verified      = EXCLUDED.admin_verified;

  -- ── Grupos ──────────────────────────────────────────────────────────────────
  INSERT INTO public.groups (
    id, name, city, state, genre, description,
    is_verified, admin_verified, is_active,
    rating, total_reviews, owner_id,
    verification_status, strike_count, created_at
  )
  VALUES
    (g1, 'Banda El Ritmo', 'Ciudad de México', 'CDMX',            'Banda',     'Banda sinaloense con 10 años de experiencia en bodas y eventos.',   true,  true,  true,  4.8, 32, go1, 'approved', 0, now() - interval '8 months'),
    (g2, 'Mariachi Sol',   'Guadalajara',      'Jalisco',          'Mariachi',  'El mejor mariachi de Guadalajara para eventos y serenatas.',         true,  false, true,  4.5, 18, go2, 'approved', 0, now() - interval '5 months'),
    (g3, 'Norteño Mix',    'Monterrey',        'Nuevo León',       'Norteño',   'Música norteña para fiestas, bodas y eventos corporativos.',         false, false, true,  4.2,  7, go3, 'none',     0, now() - interval '2 months'),
    (g4, 'Los Clásicos',   'Puebla',           'Puebla',           'Versátil',  'Grupo versátil: cumpleaños, bodas, eventos corporativos y más.',     false, false, false, 3.9,  3, go4, 'none',     1, now() - interval '1 month'),
    (g5, 'Frontera Beat',  'Tijuana',          'Baja California',  'Grupero',   'Música grupera y banda para toda ocasión en Baja California.',      false, false, true,  0.0,  0, go5, 'pending',  0, now() - interval '3 weeks'),
    (g6, 'LA Fiesta Band', 'Los Angeles',      'California',       'Latin Pop', 'Latin pop and salsa band for weddings and corporate events.',        true,  true,  true,  4.7, 21, go6, 'approved', 0, now() - interval '6 months'),
    (g7, 'Tejano Express', 'Houston',          'Texas',            'Tejano',    'Authentic tejano music for all occasions across Texas.',             true,  false, true,  4.4, 12, go7, 'approved', 0, now() - interval '4 months'),
    (g8, 'NY Salsa Kings', 'New York City',    'New York',         'Salsa',     'New York salsa band with over 15 years of live experience.',        false, false, true,  4.1,  5, go8, 'none',     0, now() - interval '2 months')
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
    verification_status = EXCLUDED.verification_status,
    strike_count        = EXCLUDED.strike_count;

  -- ── Profiles talentos ───────────────────────────────────────────────────────
  INSERT INTO public.profiles (id, full_name, role, state, country, phone, verification_status, admin_verified, created_at)
  VALUES
    (t1, 'Carlos Rivera', 'talent', 'CDMX',            'México', '5552001001', 'approved', true,  now() - interval '10 months'),
    (t2, 'Valeria Núñez', 'talent', 'Jalisco',          'México', '3332002002', 'none',     false, now() - interval '6 months'),
    (t3, 'Andrés Flores', 'talent', 'Nuevo León',       'México', '8182003003', 'pending',  false, now() - interval '3 months'),
    (t4, 'Paola Medina',  'talent', 'CDMX',            'México', '5552004004', 'none',     false, now() - interval '2 months'),
    (t5, 'Óscar Reyes',   'talent', 'Baja California',  'México', '6642005005', 'none',     false, now() - interval '1 month')
  ON CONFLICT (id) DO UPDATE SET
    full_name           = EXCLUDED.full_name,
    role                = EXCLUDED.role,
    state               = EXCLUDED.state,
    country             = EXCLUDED.country,
    phone               = EXCLUDED.phone,
    verification_status = EXCLUDED.verification_status,
    admin_verified      = EXCLUDED.admin_verified;

  -- ── job_board_profiles para talentos ────────────────────────────────────────
  INSERT INTO public.job_board_profiles (
    user_id, instrument_or_role, bio,
    experience_years, rating, total_jobs,
    availability_status, is_visible
  )
  VALUES
    (t1, 'Guitarrista',   'Guitarrista profesional con 8 años de experiencia en eventos y grabaciones en estudio.', 8, 4.9, 24, 'available', true),
    (t2, 'Cantante',      'Vocalista versátil en pop, balada romántica y música regional.',                         5, 4.6, 15, 'available', true),
    (t3, 'Bajista',       'Bajista eléctrico y acústico para cualquier género musical.',                            3, 4.3,  8, 'available', true),
    (t4, 'Percusionista', 'Percusionista con experiencia en bodas, quinceañeras y eventos privados.',               6, 4.7, 19, 'busy',      true),
    (t5, 'DJ',            'DJ con más de 200 eventos realizados. Especialidad: electrónica y reggaetón.',           4, 4.5, 47, 'available', true)
  ON CONFLICT (user_id) DO UPDATE SET
    instrument_or_role  = EXCLUDED.instrument_or_role,
    bio                 = EXCLUDED.bio,
    experience_years    = EXCLUDED.experience_years,
    rating              = EXCLUDED.rating,
    total_jobs          = EXCLUDED.total_jobs,
    availability_status = EXCLUDED.availability_status,
    is_visible          = EXCLUDED.is_visible;

  RAISE NOTICE '8 grupos y 5 talentos de prueba creados/actualizados ✅';
  RAISE NOTICE 'Grupos MX: CDMX(1) · Jalisco(1) · Nuevo León(1) · Puebla(1) · Baja California(1)';
  RAISE NOTICE 'Grupos USA: California(1) · Texas(1) · New York(1)';
  RAISE NOTICE 'Talentos MX: CDMX(2) · Jalisco(1) · Nuevo León(1) · Baja California(1)';
END;
$$;

-- ── Verificación ─────────────────────────────────────────────────────────────
SELECT
  'GRUPO'  AS tipo,
  g.name   AS nombre,
  g.state  AS estado,
  g.is_verified::text  AS verificado,
  g.is_active::text    AS activo,
  g.rating::text       AS rating
FROM public.groups g
JOIN public.profiles p ON p.id = g.owner_id
WHERE p.email LIKE '%@mhtest.dev' OR g.owner_id IN (
  SELECT id FROM auth.users WHERE email LIKE '%@mhtest.dev'
)
UNION ALL
SELECT
  'TALENTO',
  p.full_name,
  p.state,
  p.admin_verified::text,
  'true',
  j.rating::text
FROM public.profiles p
LEFT JOIN public.job_board_profiles j ON j.user_id = p.id
WHERE p.id IN (SELECT id FROM auth.users WHERE email LIKE '%@mhtest.dev')
  AND p.role = 'talent'
ORDER BY 1, 2;
