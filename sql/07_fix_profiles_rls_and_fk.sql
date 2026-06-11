-- ============================================================
-- 07: Fix profiles RLS + FK constraint + group_unavailability
-- ============================================================
-- Run this in Supabase SQL Editor

-- ⚠️ FIRST: Drop the recursive policy if it was already created
DROP POLICY IF EXISTS "profiles_group_read_clients" ON public.profiles;

-- 1. Allow ANY authenticated user to read basic profile info (full_name, phone)
--    This avoids recursion. Only exposes name/phone, not email or sensitive data.
--    Use a security definer function to bypass RLS safely.
CREATE OR REPLACE FUNCTION public.get_profile_basic(uid UUID)
RETURNS TABLE(id UUID, full_name TEXT, phone TEXT)
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT p.id, p.full_name, p.phone FROM profiles p WHERE p.id = uid;
$$;

-- Alternative simpler approach: allow all authenticated users to SELECT profiles
-- (profiles only contain name, phone, role - no sensitive data)
DROP POLICY IF EXISTS "profiles_authenticated_read" ON public.profiles;
CREATE POLICY "profiles_authenticated_read"
  ON public.profiles FOR SELECT
  USING (auth.uid() IS NOT NULL);

-- 2. Create the named FK constraint if it doesn't exist
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.table_constraints
    WHERE constraint_name = 'fk_reservations_client_profile'
      AND table_name = 'reservations'
  ) THEN
    IF EXISTS (
      SELECT 1 FROM information_schema.table_constraints
      WHERE constraint_name = 'reservations_client_id_fkey'
        AND table_name = 'reservations'
    ) THEN
      ALTER TABLE public.reservations
        RENAME CONSTRAINT reservations_client_id_fkey TO fk_reservations_client_profile;
    ELSE
      ALTER TABLE public.reservations
        ADD CONSTRAINT fk_reservations_client_profile
        FOREIGN KEY (client_id) REFERENCES public.profiles(id);
    END IF;
  END IF;
END $$;

-- 3. Ensure RLS is enabled on group_unavailability
ALTER TABLE IF EXISTS public.group_unavailability ENABLE ROW LEVEL SECURITY;

-- 4. RLS policies for group_unavailability
DROP POLICY IF EXISTS "group_unavailability_group_select" ON public.group_unavailability;
CREATE POLICY "group_unavailability_group_select"
  ON public.group_unavailability FOR SELECT
  USING (
    EXISTS (SELECT 1 FROM public.groups WHERE id = group_id AND owner_id = auth.uid())
  );

DROP POLICY IF EXISTS "group_unavailability_group_insert" ON public.group_unavailability;
CREATE POLICY "group_unavailability_group_insert"
  ON public.group_unavailability FOR INSERT
  WITH CHECK (
    EXISTS (SELECT 1 FROM public.groups WHERE id = group_id AND owner_id = auth.uid())
  );

DROP POLICY IF EXISTS "group_unavailability_group_delete" ON public.group_unavailability;
CREATE POLICY "group_unavailability_group_delete"
  ON public.group_unavailability FOR DELETE
  USING (
    EXISTS (SELECT 1 FROM public.groups WHERE id = group_id AND owner_id = auth.uid())
  );

DROP POLICY IF EXISTS "group_unavailability_group_update" ON public.group_unavailability;
CREATE POLICY "group_unavailability_group_update"
  ON public.group_unavailability FOR UPDATE
  USING (
    EXISTS (SELECT 1 FROM public.groups WHERE id = group_id AND owner_id = auth.uid())
  );

-- Allow clients to read group unavailability (needed for BookingScreen calendar)
DROP POLICY IF EXISTS "group_unavailability_client_read" ON public.group_unavailability;
CREATE POLICY "group_unavailability_client_read"
  ON public.group_unavailability FOR SELECT
  USING (true);

-- Allow admins full access
DROP POLICY IF EXISTS "group_unavailability_admin_all" ON public.group_unavailability;
CREATE POLICY "group_unavailability_admin_all"
  ON public.group_unavailability FOR ALL
  USING (
    EXISTS (SELECT 1 FROM public.profiles WHERE id = auth.uid() AND role = 'admin')
  );
