-- ============================================================
-- DARICEFY - 10_job_board.sql
-- Job Board: talent profiles + group invitations + notifications
-- Run AFTER 09_categories.sql
-- ============================================================

-- ─────────────────────────────────────────────────
-- 1. notifications TABLE (general purpose — used by job board now,
--    reusable for future features)
-- ─────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.notifications (
  id         UUID    PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id    UUID    NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  type       TEXT    NOT NULL,
  title      TEXT    NOT NULL,
  body       TEXT    NOT NULL DEFAULT '',
  data       JSONB            DEFAULT '{}',
  is_read    BOOLEAN NOT NULL DEFAULT FALSE,
  created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

-- ─────────────────────────────────────────────────
-- 2. job_board_profiles TABLE
--    One profile per user (UNIQUE on user_id).
--    Idempotent: CREATE + ADD COLUMN IF NOT EXISTS pattern.
-- ─────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.job_board_profiles (
  id         UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
  updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

ALTER TABLE public.job_board_profiles
  ADD COLUMN IF NOT EXISTS user_id            UUID    REFERENCES public.profiles(id) ON DELETE CASCADE;
ALTER TABLE public.job_board_profiles
  ADD COLUMN IF NOT EXISTS instrument_or_role TEXT    NOT NULL DEFAULT '';
ALTER TABLE public.job_board_profiles
  ADD COLUMN IF NOT EXISTS bio                TEXT;
ALTER TABLE public.job_board_profiles
  ADD COLUMN IF NOT EXISTS experience_years   INTEGER NOT NULL DEFAULT 0;
ALTER TABLE public.job_board_profiles
  ADD COLUMN IF NOT EXISTS rating             DECIMAL(3,2) NOT NULL DEFAULT 5.0;
ALTER TABLE public.job_board_profiles
  ADD COLUMN IF NOT EXISTS total_jobs         INTEGER NOT NULL DEFAULT 0;
ALTER TABLE public.job_board_profiles
  ADD COLUMN IF NOT EXISTS availability_status TEXT   NOT NULL DEFAULT 'available';
ALTER TABLE public.job_board_profiles
  ADD COLUMN IF NOT EXISTS is_visible         BOOLEAN NOT NULL DEFAULT TRUE;

-- Constraints (safe to re-run)
DO $$ BEGIN
  ALTER TABLE public.job_board_profiles
    ADD CONSTRAINT jbp_user_id_unique UNIQUE (user_id);
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

DO $$ BEGIN
  ALTER TABLE public.job_board_profiles
    ADD CONSTRAINT jbp_availability_check
    CHECK (availability_status IN ('available', 'busy'));
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

DO $$ BEGIN
  ALTER TABLE public.job_board_profiles
    ADD CONSTRAINT jbp_rating_check
    CHECK (rating >= 0.0 AND rating <= 5.0);
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

DO $$ BEGIN
  ALTER TABLE public.job_board_profiles
    ADD CONSTRAINT jbp_experience_check
    CHECK (experience_years >= 0);
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

-- ─────────────────────────────────────────────────
-- 3. job_invitations TABLE
--    group_id  → the group that is sending the invite
--    invited_user_id → the individual talent (not a group member)
--    event_id  → nullable (not all invitations are for a specific event yet)
-- ─────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.job_invitations (
  id         UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
  updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

ALTER TABLE public.job_invitations
  ADD COLUMN IF NOT EXISTS group_id                UUID REFERENCES public.groups(id) ON DELETE CASCADE;
ALTER TABLE public.job_invitations
  ADD COLUMN IF NOT EXISTS invited_user_id         UUID REFERENCES public.profiles(id) ON DELETE CASCADE;
ALTER TABLE public.job_invitations
  ADD COLUMN IF NOT EXISTS event_id                UUID REFERENCES public.events(id) ON DELETE SET NULL;
ALTER TABLE public.job_invitations
  ADD COLUMN IF NOT EXISTS proposed_payment_amount DECIMAL(10,2);
ALTER TABLE public.job_invitations
  ADD COLUMN IF NOT EXISTS message                 TEXT;
ALTER TABLE public.job_invitations
  ADD COLUMN IF NOT EXISTS status                  TEXT NOT NULL DEFAULT 'pending';

DO $$ BEGIN
  ALTER TABLE public.job_invitations
    ADD CONSTRAINT jinv_status_check
    CHECK (status IN ('pending', 'accepted', 'rejected'));
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

-- Prevent duplicate invitations: one per (group, user, event) when event is set
CREATE UNIQUE INDEX IF NOT EXISTS idx_jinv_unique_with_event
  ON public.job_invitations (group_id, invited_user_id, event_id)
  WHERE event_id IS NOT NULL;

-- Prevent duplicate invitations: one per (group, user) when no event is set
CREATE UNIQUE INDEX IF NOT EXISTS idx_jinv_unique_no_event
  ON public.job_invitations (group_id, invited_user_id)
  WHERE event_id IS NULL;

-- ─────────────────────────────────────────────────
-- 4. TRIGGERS: updated_at
--    set_updated_at() already exists from 02_triggers_y_funciones.sql
-- ─────────────────────────────────────────────────
DROP TRIGGER IF EXISTS set_jbp_updated_at  ON public.job_board_profiles;
CREATE TRIGGER set_jbp_updated_at
  BEFORE UPDATE ON public.job_board_profiles
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

DROP TRIGGER IF EXISTS set_jinv_updated_at ON public.job_invitations;
CREATE TRIGGER set_jinv_updated_at
  BEFORE UPDATE ON public.job_invitations
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

-- ─────────────────────────────────────────────────
-- 5. TRIGGER: auto-notification when invitation is sent
-- ─────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.notify_on_job_invitation()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
  v_group_name TEXT;
BEGIN
  SELECT name INTO v_group_name
  FROM public.groups
  WHERE id = NEW.group_id;

  INSERT INTO public.notifications (user_id, type, title, body, data)
  VALUES (
    NEW.invited_user_id,
    'job_invitation',
    'Nueva invitación de trabajo',
    COALESCE(v_group_name, 'Un grupo') || ' te invitó a colaborar en un evento',
    jsonb_build_object(
      'invitation_id',           NEW.id,
      'group_id',                NEW.group_id,
      'event_id',                NEW.event_id,
      'proposed_payment_amount', NEW.proposed_payment_amount
    )
  );

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trigger_notify_job_invitation ON public.job_invitations;
CREATE TRIGGER trigger_notify_job_invitation
  AFTER INSERT ON public.job_invitations
  FOR EACH ROW EXECUTE FUNCTION public.notify_on_job_invitation();

-- ─────────────────────────────────────────────────
-- 6. INDEXES
-- ─────────────────────────────────────────────────
CREATE INDEX IF NOT EXISTS idx_jbp_user_id       ON public.job_board_profiles(user_id);
CREATE INDEX IF NOT EXISTS idx_jbp_role          ON public.job_board_profiles(instrument_or_role);
CREATE INDEX IF NOT EXISTS idx_jbp_availability  ON public.job_board_profiles(availability_status);
CREATE INDEX IF NOT EXISTS idx_jbp_visible       ON public.job_board_profiles(is_visible);
CREATE INDEX IF NOT EXISTS idx_jbp_rating        ON public.job_board_profiles(rating DESC);

CREATE INDEX IF NOT EXISTS idx_jinv_group_id     ON public.job_invitations(group_id);
CREATE INDEX IF NOT EXISTS idx_jinv_invited_user ON public.job_invitations(invited_user_id);
CREATE INDEX IF NOT EXISTS idx_jinv_event_id     ON public.job_invitations(event_id);
CREATE INDEX IF NOT EXISTS idx_jinv_status       ON public.job_invitations(status);

CREATE INDEX IF NOT EXISTS idx_notif_user_id     ON public.notifications(user_id);
CREATE INDEX IF NOT EXISTS idx_notif_is_read     ON public.notifications(is_read);
CREATE INDEX IF NOT EXISTS idx_notif_type        ON public.notifications(type);
CREATE INDEX IF NOT EXISTS idx_notif_created_at  ON public.notifications(created_at DESC);

-- ─────────────────────────────────────────────────
-- 7. RLS
-- ─────────────────────────────────────────────────
ALTER TABLE public.job_board_profiles ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.job_invitations    ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.notifications      ENABLE ROW LEVEL SECURITY;

-- ── job_board_profiles ──
-- Any authenticated user can read visible profiles; owner always sees their own
DROP POLICY IF EXISTS "jbp_select" ON public.job_board_profiles;
CREATE POLICY "jbp_select"
  ON public.job_board_profiles FOR SELECT
  USING (is_visible = TRUE OR user_id = auth.uid());

-- Users can only create their own profile
DROP POLICY IF EXISTS "jbp_insert" ON public.job_board_profiles;
CREATE POLICY "jbp_insert"
  ON public.job_board_profiles FOR INSERT
  WITH CHECK (user_id = auth.uid());

-- Users can only edit their own profile
DROP POLICY IF EXISTS "jbp_update" ON public.job_board_profiles;
CREATE POLICY "jbp_update"
  ON public.job_board_profiles FOR UPDATE
  USING (user_id = auth.uid());

-- Users can delete their own profile
DROP POLICY IF EXISTS "jbp_delete" ON public.job_board_profiles;
CREATE POLICY "jbp_delete"
  ON public.job_board_profiles FOR DELETE
  USING (user_id = auth.uid());

-- ── job_invitations ──
-- Group owner sees invitations they sent; invited user sees invitations they received
DROP POLICY IF EXISTS "jinv_select" ON public.job_invitations;
CREATE POLICY "jinv_select"
  ON public.job_invitations FOR SELECT
  USING (
    invited_user_id = auth.uid()
    OR EXISTS (
      SELECT 1 FROM public.groups
      WHERE id = group_id AND owner_id = auth.uid()
    )
  );

-- Only group owners can send invitations
DROP POLICY IF EXISTS "jinv_insert" ON public.job_invitations;
CREATE POLICY "jinv_insert"
  ON public.job_invitations FOR INSERT
  WITH CHECK (
    EXISTS (
      SELECT 1 FROM public.groups
      WHERE id = group_id AND owner_id = auth.uid()
    )
  );

-- Only the invited user can accept or reject
DROP POLICY IF EXISTS "jinv_update" ON public.job_invitations;
CREATE POLICY "jinv_update"
  ON public.job_invitations FOR UPDATE
  USING (invited_user_id = auth.uid())
  WITH CHECK (status IN ('accepted', 'rejected'));

-- Group owner can retract a pending invitation
DROP POLICY IF EXISTS "jinv_delete" ON public.job_invitations;
CREATE POLICY "jinv_delete"
  ON public.job_invitations FOR DELETE
  USING (
    EXISTS (
      SELECT 1 FROM public.groups
      WHERE id = group_id AND owner_id = auth.uid()
    )
  );

-- Admin full access
DROP POLICY IF EXISTS "jinv_admin" ON public.job_invitations;
CREATE POLICY "jinv_admin"
  ON public.job_invitations FOR ALL
  USING (
    EXISTS (SELECT 1 FROM public.profiles WHERE id = auth.uid() AND role = 'admin')
  );

-- ── notifications ──
-- Users only see and update their own notifications
DROP POLICY IF EXISTS "notif_select" ON public.notifications;
CREATE POLICY "notif_select"
  ON public.notifications FOR SELECT
  USING (user_id = auth.uid());

DROP POLICY IF EXISTS "notif_update" ON public.notifications;
CREATE POLICY "notif_update"
  ON public.notifications FOR UPDATE
  USING (user_id = auth.uid());

DROP POLICY IF EXISTS "notif_admin" ON public.notifications;
CREATE POLICY "notif_admin"
  ON public.notifications FOR ALL
  USING (
    EXISTS (SELECT 1 FROM public.profiles WHERE id = auth.uid() AND role = 'admin')
  );

-- ─────────────────────────────────────────────────
-- 8. RPC: search_talents
--    Returns visible profiles joined with profile name/avatar.
--    p_role: optional ILIKE filter on instrument_or_role.
--    p_availability: optional filter ('available' | 'busy' | NULL for all).
-- ─────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.search_talents(
  p_role         TEXT DEFAULT NULL,
  p_availability TEXT DEFAULT NULL
)
RETURNS TABLE (
  id                  UUID,
  user_id             UUID,
  full_name           TEXT,
  avatar_url          TEXT,
  instrument_or_role  TEXT,
  bio                 TEXT,
  experience_years    INTEGER,
  rating              NUMERIC,
  total_jobs          INTEGER,
  availability_status TEXT,
  created_at          TIMESTAMP WITH TIME ZONE
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT
    jbp.id,
    jbp.user_id,
    p.full_name,
    p.avatar_url,
    jbp.instrument_or_role,
    jbp.bio,
    jbp.experience_years,
    jbp.rating::NUMERIC,
    jbp.total_jobs,
    jbp.availability_status,
    jbp.created_at
  FROM job_board_profiles jbp
  JOIN profiles p ON p.id = jbp.user_id
  WHERE jbp.is_visible = TRUE
    AND (p_role         IS NULL OR jbp.instrument_or_role ILIKE '%' || p_role || '%')
    AND (p_availability IS NULL OR jbp.availability_status = p_availability)
  ORDER BY
    jbp.availability_status ASC,   -- 'available' sorts before 'busy'
    jbp.rating              DESC,
    jbp.total_jobs          DESC;
$$;

SELECT 'Job Board creado correctamente ✅' AS status;
