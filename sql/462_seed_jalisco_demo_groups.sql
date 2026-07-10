-- ============================================================
-- sql/462_seed_jalisco_demo_groups.sql
--
-- Grupos de PRUEBA en Jalisco (con foto) para poblar los 3
-- carruseles del explorador (Destacados / Recomendados / Populares).
--
-- Cada grupo tiene su propio dueño (auth.users + profiles).
-- Idempotente (ON CONFLICT). Reejecutable sin duplicar.
--
-- ROLLBACK:
--   DELETE FROM auth.users WHERE email LIKE 'jaldemo%@mhtest.dev';
--   (borra en cascada profiles y groups por owner_id)
-- ============================================================

DO $$
DECLARE
  rec  RECORD;
  uid  UUID;
  gid  UUID;
BEGIN
  FOR rec IN
    SELECT * FROM (VALUES
      ('jaldemo1@mhtest.dev', 'Roberto Nava',   'Mariachi Sol de Jalisco',  'Guadalajara', 'Mariachi', 4.9, 64, true,  'https://picsum.photos/seed/mariachi-sol/500/560'),
      ('jaldemo2@mhtest.dev', 'Diego Fuentes',  'Banda Perla Tapatía',      'Zapopan',     'Banda',    4.8, 51, true,  'https://picsum.photos/seed/banda-perla/500/560'),
      ('jaldemo3@mhtest.dev', 'Hugo Alcaraz',   'Norteño Los Alteños',      'Tlaquepaque', 'Norteño',  4.7, 43, true,  'https://picsum.photos/seed/nortenos-altos/500/560'),
      ('jaldemo4@mhtest.dev', 'Iván Robles',    'Versátil GDL Live',        'Guadalajara', 'Versátil', 4.6, 38, true,  'https://picsum.photos/seed/versatil-gdl/500/560'),
      ('jaldemo5@mhtest.dev', 'Sofía Mendoza',  'Trío Serenata Tapatía',    'Guadalajara', 'Trío',     4.5, 29, false, 'https://picsum.photos/seed/trio-serenata/500/560'),
      ('jaldemo6@mhtest.dev', 'Karla Ibarra',   'Cumbia Zapopan',           'Zapopan',     'Cumbia',   4.4, 22, false, 'https://picsum.photos/seed/cumbia-zapo/500/560'),
      ('jaldemo7@mhtest.dev', 'Marco Villa',    'DJ Set Guadalajara',       'Guadalajara', 'DJ',       4.6, 31, true,  'https://picsum.photos/seed/dj-gdl/500/560'),
      ('jaldemo8@mhtest.dev', 'Luis Cárdenas',  'Rock Estudio GDL',         'Guadalajara', 'Rock',     4.3, 18, false, 'https://picsum.photos/seed/rock-gdl/500/560')
    ) AS t(email, owner_name, gname, city, genre, rating, reviews, verified, img)
  LOOP
    uid := COALESCE((SELECT id FROM auth.users WHERE email = rec.email), gen_random_uuid());

    -- Usuario auth
    INSERT INTO auth.users (
      id, email, encrypted_password,
      email_confirmed_at, created_at, updated_at,
      raw_app_meta_data, raw_user_meta_data,
      aud, role, is_super_admin
    )
    VALUES (
      uid, rec.email, crypt('Test1234!', gen_salt('bf')),
      now(), now(), now(),
      '{"provider":"email","providers":["email"]}', '{}',
      'authenticated', 'authenticated', false
    )
    ON CONFLICT (id) DO NOTHING;

    -- Perfil (dueño)
    INSERT INTO public.profiles (
      id, full_name, role, state, country,
      verification_status, admin_verified, created_at
    )
    VALUES (
      uid, rec.owner_name, 'group', 'Jalisco', 'México',
      CASE WHEN rec.verified THEN 'approved' ELSE 'none' END, rec.verified,
      now() - interval '2 months'
    )
    ON CONFLICT (id) DO UPDATE SET
      full_name = EXCLUDED.full_name,
      role      = EXCLUDED.role,
      state     = EXCLUDED.state,
      country   = EXCLUDED.country;

    -- Grupo
    gid := COALESCE((SELECT id FROM public.groups WHERE owner_id = uid), gen_random_uuid());

    INSERT INTO public.groups (
      id, name, city, state, genre, description, profile_image,
      is_verified, admin_verified, is_active,
      rating, total_reviews, owner_id,
      verification_status, strike_count, created_at
    )
    VALUES (
      gid, rec.gname, rec.city, 'Jalisco', rec.genre,
      'Grupo de prueba en Jalisco para demostrar el explorador.', rec.img,
      rec.verified, rec.verified, true,
      rec.rating, rec.reviews, uid,
      CASE WHEN rec.verified THEN 'approved' ELSE 'none' END, 0,
      now() - interval '2 months'
    )
    ON CONFLICT (id) DO UPDATE SET
      name                = EXCLUDED.name,
      city                = EXCLUDED.city,
      state               = EXCLUDED.state,
      genre               = EXCLUDED.genre,
      description         = EXCLUDED.description,
      profile_image       = EXCLUDED.profile_image,
      is_verified         = EXCLUDED.is_verified,
      admin_verified      = EXCLUDED.admin_verified,
      is_active           = EXCLUDED.is_active,
      rating              = EXCLUDED.rating,
      total_reviews       = EXCLUDED.total_reviews,
      verification_status = EXCLUDED.verification_status;
  END LOOP;

  RAISE NOTICE '8 grupos de prueba en Jalisco creados/actualizados ✅';
END;
$$;

-- ── Verificación ─────────────────────────────────────────────────────────────
SELECT name AS grupo, city AS ciudad, genre, rating, total_reviews, is_verified, profile_image
FROM public.groups
WHERE state = 'Jalisco' AND name IN (
  'Mariachi Sol de Jalisco','Banda Perla Tapatía','Norteño Los Alteños','Versátil GDL Live',
  'Trío Serenata Tapatía','Cumbia Zapopan','DJ Set Guadalajara','Rock Estudio GDL'
)
ORDER BY rating DESC;
