-- ============================================================
-- DARICEFY - 03_rls_policies.sql
-- Ejecutar TERCERO en Supabase SQL Editor
-- (Después de 00_fix_columnas_existentes.sql si ya tenías tablas)
-- ============================================================

-- Habilitar RLS en todas las tablas
ALTER TABLE public.profiles ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.groups ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.packages ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.reservations ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.countries ENABLE ROW LEVEL SECURITY;

DO $$ BEGIN
  ALTER TABLE public.extra_hours ENABLE ROW LEVEL SECURITY;
EXCEPTION WHEN undefined_table THEN NULL; END $$;

DO $$ BEGIN
  ALTER TABLE public.event_breaks ENABLE ROW LEVEL SECURITY;
EXCEPTION WHEN undefined_table THEN NULL; END $$;

DO $$ BEGIN
  ALTER TABLE public.verification_requests ENABLE ROW LEVEL SECURITY;
EXCEPTION WHEN undefined_table THEN NULL; END $$;

DO $$ BEGIN
  ALTER TABLE public.reviews ENABLE ROW LEVEL SECURITY;
EXCEPTION WHEN undefined_table THEN NULL; END $$;

DO $$ BEGIN
  ALTER TABLE public.motivational_messages ENABLE ROW LEVEL SECURITY;
EXCEPTION WHEN undefined_table THEN NULL; END $$;

DO $$ BEGIN
  ALTER TABLE public.audio_tracks ENABLE ROW LEVEL SECURITY;
EXCEPTION WHEN undefined_table THEN NULL; END $$;

DO $$ BEGIN
  ALTER TABLE public.track_purchases ENABLE ROW LEVEL SECURITY;
EXCEPTION WHEN undefined_table THEN NULL; END $$;

DO $$ BEGIN
  ALTER TABLE public.merchandise ENABLE ROW LEVEL SECURITY;
EXCEPTION WHEN undefined_table THEN NULL; END $$;

DO $$ BEGIN
  ALTER TABLE public.merch_orders ENABLE ROW LEVEL SECURITY;
EXCEPTION WHEN undefined_table THEN NULL; END $$;

-- ─────────────────────────────────────────────────
-- PROFILES
-- ─────────────────────────────────────────────────
DROP POLICY IF EXISTS "profiles_select_own" ON public.profiles;
CREATE POLICY "profiles_select_own"
  ON public.profiles FOR SELECT
  USING (auth.uid() = id);

DROP POLICY IF EXISTS "profiles_update_own" ON public.profiles;
CREATE POLICY "profiles_update_own"
  ON public.profiles FOR UPDATE
  USING (auth.uid() = id);

DROP POLICY IF EXISTS "profiles_insert_own" ON public.profiles;
CREATE POLICY "profiles_insert_own"
  ON public.profiles FOR INSERT
  WITH CHECK (auth.uid() = id);

DROP POLICY IF EXISTS "profiles_admin_select" ON public.profiles;
CREATE POLICY "profiles_admin_select"
  ON public.profiles FOR SELECT
  USING (
    EXISTS (SELECT 1 FROM public.profiles p WHERE p.id = auth.uid() AND p.role = 'admin')
  );

-- ─────────────────────────────────────────────────
-- COUNTRIES (lectura pública, escritura solo admin)
-- ─────────────────────────────────────────────────
DROP POLICY IF EXISTS "countries_select_all" ON public.countries;
CREATE POLICY "countries_select_all"
  ON public.countries FOR SELECT
  USING (true);

DROP POLICY IF EXISTS "countries_admin_all" ON public.countries;
CREATE POLICY "countries_admin_all"
  ON public.countries FOR ALL
  USING (
    EXISTS (SELECT 1 FROM public.profiles WHERE id = auth.uid() AND role = 'admin')
  );

-- ─────────────────────────────────────────────────
-- GROUPS
-- ─────────────────────────────────────────────────
DROP POLICY IF EXISTS "groups_select_active" ON public.groups;
CREATE POLICY "groups_select_active"
  ON public.groups FOR SELECT
  USING (COALESCE(is_active, true) = TRUE);

DROP POLICY IF EXISTS "groups_owner_all" ON public.groups;
CREATE POLICY "groups_owner_all"
  ON public.groups FOR ALL
  USING (owner_id = auth.uid());

DROP POLICY IF EXISTS "groups_admin_all" ON public.groups;
CREATE POLICY "groups_admin_all"
  ON public.groups FOR ALL
  USING (
    EXISTS (SELECT 1 FROM public.profiles WHERE id = auth.uid() AND role = 'admin')
  );

-- ─────────────────────────────────────────────────
-- PACKAGES
-- ─────────────────────────────────────────────────
DROP POLICY IF EXISTS "packages_select_active" ON public.packages;
CREATE POLICY "packages_select_active"
  ON public.packages FOR SELECT
  USING (COALESCE(is_active, true) = TRUE);

DROP POLICY IF EXISTS "packages_owner_all" ON public.packages;
CREATE POLICY "packages_owner_all"
  ON public.packages FOR ALL
  USING (
    EXISTS (SELECT 1 FROM public.groups WHERE id = group_id AND owner_id = auth.uid())
  );

DROP POLICY IF EXISTS "packages_admin_all" ON public.packages;
CREATE POLICY "packages_admin_all"
  ON public.packages FOR ALL
  USING (
    EXISTS (SELECT 1 FROM public.profiles WHERE id = auth.uid() AND role = 'admin')
  );

-- ─────────────────────────────────────────────────
-- RESERVATIONS
-- ─────────────────────────────────────────────────
DROP POLICY IF EXISTS "reservations_client_own" ON public.reservations;
CREATE POLICY "reservations_client_own"
  ON public.reservations FOR SELECT
  USING (client_id = auth.uid());

DROP POLICY IF EXISTS "reservations_client_insert" ON public.reservations;
CREATE POLICY "reservations_client_insert"
  ON public.reservations FOR INSERT
  WITH CHECK (client_id = auth.uid());

DROP POLICY IF EXISTS "reservations_group_own" ON public.reservations;
CREATE POLICY "reservations_group_own"
  ON public.reservations FOR SELECT
  USING (
    EXISTS (SELECT 1 FROM public.groups WHERE id = group_id AND owner_id = auth.uid())
  );

DROP POLICY IF EXISTS "reservations_group_update" ON public.reservations;
CREATE POLICY "reservations_group_update"
  ON public.reservations FOR UPDATE
  USING (
    EXISTS (SELECT 1 FROM public.groups WHERE id = group_id AND owner_id = auth.uid())
  );

DROP POLICY IF EXISTS "reservations_admin_all" ON public.reservations;
CREATE POLICY "reservations_admin_all"
  ON public.reservations FOR ALL
  USING (
    EXISTS (SELECT 1 FROM public.profiles WHERE id = auth.uid() AND role = 'admin')
  );

-- ─────────────────────────────────────────────────
-- VERIFICATION REQUESTS
-- ─────────────────────────────────────────────────
DO $$ BEGIN
  DROP POLICY IF EXISTS "verreq_group_own" ON public.verification_requests;
  CREATE POLICY "verreq_group_own"
    ON public.verification_requests FOR SELECT
    USING (
      EXISTS (SELECT 1 FROM public.groups WHERE id = group_id AND owner_id = auth.uid())
    );

  DROP POLICY IF EXISTS "verreq_group_insert" ON public.verification_requests;
  CREATE POLICY "verreq_group_insert"
    ON public.verification_requests FOR INSERT
    WITH CHECK (
      EXISTS (SELECT 1 FROM public.groups WHERE id = group_id AND owner_id = auth.uid())
    );

  DROP POLICY IF EXISTS "verreq_admin_all" ON public.verification_requests;
  CREATE POLICY "verreq_admin_all"
    ON public.verification_requests FOR ALL
    USING (
      EXISTS (SELECT 1 FROM public.profiles WHERE id = auth.uid() AND role = 'admin')
    );
EXCEPTION WHEN undefined_table THEN
  RAISE NOTICE 'Tabla verification_requests no existe, omitiendo políticas';
END $$;

-- ─────────────────────────────────────────────────
-- REVIEWS
-- ─────────────────────────────────────────────────
DO $$ BEGIN
  DROP POLICY IF EXISTS "reviews_select_all" ON public.reviews;
  CREATE POLICY "reviews_select_all"
    ON public.reviews FOR SELECT USING (true);

  DROP POLICY IF EXISTS "reviews_client_insert" ON public.reviews;
  CREATE POLICY "reviews_client_insert"
    ON public.reviews FOR INSERT
    WITH CHECK (client_id = auth.uid());
EXCEPTION WHEN undefined_table THEN
  RAISE NOTICE 'Tabla reviews no existe, omitiendo políticas';
END $$;

-- ─────────────────────────────────────────────────
-- MOTIVATIONAL MESSAGES
-- ─────────────────────────────────────────────────
DO $$ BEGIN
  DROP POLICY IF EXISTS "motiv_select_all" ON public.motivational_messages;
  CREATE POLICY "motiv_select_all"
    ON public.motivational_messages FOR SELECT USING (true);

  DROP POLICY IF EXISTS "motiv_admin_all" ON public.motivational_messages;
  CREATE POLICY "motiv_admin_all"
    ON public.motivational_messages FOR ALL
    USING (EXISTS (SELECT 1 FROM public.profiles WHERE id = auth.uid() AND role = 'admin'));
EXCEPTION WHEN undefined_table THEN
  RAISE NOTICE 'Tabla motivational_messages no existe, omitiendo políticas';
END $$;

-- ─────────────────────────────────────────────────
-- AUDIO TRACKS / MERCHANDISE
-- ─────────────────────────────────────────────────
DO $$ BEGIN
  DROP POLICY IF EXISTS "tracks_select_active" ON public.audio_tracks;
  CREATE POLICY "tracks_select_active"
    ON public.audio_tracks FOR SELECT USING (COALESCE(is_active, true) = TRUE);

  DROP POLICY IF EXISTS "tracks_owner_all" ON public.audio_tracks;
  CREATE POLICY "tracks_owner_all"
    ON public.audio_tracks FOR ALL
    USING (EXISTS (SELECT 1 FROM public.groups WHERE id = group_id AND owner_id = auth.uid()));
EXCEPTION WHEN undefined_table THEN
  RAISE NOTICE 'Tabla audio_tracks no existe, omitiendo políticas';
END $$;

DO $$ BEGIN
  DROP POLICY IF EXISTS "merch_select_active" ON public.merchandise;
  CREATE POLICY "merch_select_active"
    ON public.merchandise FOR SELECT USING (COALESCE(is_active, true) = TRUE);

  DROP POLICY IF EXISTS "merch_owner_all" ON public.merchandise;
  CREATE POLICY "merch_owner_all"
    ON public.merchandise FOR ALL
    USING (EXISTS (SELECT 1 FROM public.groups WHERE id = group_id AND owner_id = auth.uid()));
EXCEPTION WHEN undefined_table THEN
  RAISE NOTICE 'Tabla merchandise no existe, omitiendo políticas';
END $$;

-- ─────────────────────────────────────────────────
-- EXTRA HOURS
-- ─────────────────────────────────────────────────
DO $$ BEGIN
  DROP POLICY IF EXISTS "extrahours_related_users" ON public.extra_hours;
  CREATE POLICY "extrahours_related_users"
    ON public.extra_hours FOR SELECT
    USING (
      EXISTS (
        SELECT 1 FROM public.reservations r
        WHERE r.id = reservation_id
          AND (r.client_id = auth.uid() OR
               EXISTS (SELECT 1 FROM public.groups WHERE id = r.group_id AND owner_id = auth.uid()))
      )
    );
EXCEPTION WHEN undefined_table THEN
  RAISE NOTICE 'Tabla extra_hours no existe, omitiendo políticas';
END $$;

SELECT 'Políticas RLS creadas correctamente ✅' AS status;
