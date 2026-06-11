-- ============================================================
-- DARICEFY - 08_events_table.sql
-- Multi-event structure migration
-- Run AFTER all previous migrations
-- ============================================================

-- ─────────────────────────────────────────────────
-- 1. CREATE events TABLE
-- ─────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.events (
  id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  client_id   UUID NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  event_date  DATE NOT NULL,
  address     TEXT NOT NULL,
  status      TEXT NOT NULL DEFAULT 'draft'
                CHECK (status IN ('draft', 'active', 'completed', 'cancelled')),
  created_at  TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
  updated_at  TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

-- ─────────────────────────────────────────────────
-- 2. MODIFY reservations TABLE
-- ─────────────────────────────────────────────────

-- Add event_id foreign key (nullable so existing rows are unaffected)
ALTER TABLE public.reservations
  ADD COLUMN IF NOT EXISTS event_id UUID REFERENCES public.events(id) ON DELETE SET NULL;

-- Add deposit_paid boolean (default FALSE so existing rows keep a valid value)
ALTER TABLE public.reservations
  ADD COLUMN IF NOT EXISTS deposit_paid BOOLEAN NOT NULL DEFAULT FALSE;

-- Update the status CHECK constraint to include new statuses.
-- Old statuses (pending, in_progress) are kept so existing rows stay valid.
ALTER TABLE public.reservations
  DROP CONSTRAINT IF EXISTS reservations_status_check;

ALTER TABLE public.reservations
  ADD CONSTRAINT reservations_status_check
  CHECK (status IN (
    -- Legacy (existing data)
    'pending',
    'in_progress',
    'rejected',
    -- New statuses
    'pending_payment',
    'pending_provider_confirmation',
    'confirmed',
    'completed',
    'cancelled',
    'expired'
  ));

-- ─────────────────────────────────────────────────
-- 3. TRIGGER: updated_at for events
-- ─────────────────────────────────────────────────
DROP TRIGGER IF EXISTS set_updated_at_events ON public.events;
CREATE TRIGGER set_updated_at_events
  BEFORE UPDATE ON public.events
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

-- ─────────────────────────────────────────────────
-- 4. INDEXES
-- ─────────────────────────────────────────────────
CREATE INDEX IF NOT EXISTS idx_events_client_id     ON public.events(client_id);
CREATE INDEX IF NOT EXISTS idx_events_status         ON public.events(status);
CREATE INDEX IF NOT EXISTS idx_events_date           ON public.events(event_date);
CREATE INDEX IF NOT EXISTS idx_reservations_event_id ON public.reservations(event_id);

-- ─────────────────────────────────────────────────
-- 5. RLS for events table
-- ─────────────────────────────────────────────────
ALTER TABLE public.events ENABLE ROW LEVEL SECURITY;

-- Client sees their own events
DROP POLICY IF EXISTS "events_client_select" ON public.events;
CREATE POLICY "events_client_select"
  ON public.events FOR SELECT
  USING (client_id = auth.uid());

-- Client creates events
DROP POLICY IF EXISTS "events_client_insert" ON public.events;
CREATE POLICY "events_client_insert"
  ON public.events FOR INSERT
  WITH CHECK (client_id = auth.uid());

-- Client updates their own events
DROP POLICY IF EXISTS "events_client_update" ON public.events;
CREATE POLICY "events_client_update"
  ON public.events FOR UPDATE
  USING (client_id = auth.uid());

-- Group can see events linked to their reservations
DROP POLICY IF EXISTS "events_group_select" ON public.events;
CREATE POLICY "events_group_select"
  ON public.events FOR SELECT
  USING (
    EXISTS (
      SELECT 1
      FROM public.reservations r
      JOIN public.groups g ON g.id = r.group_id
      WHERE r.event_id = events.id
        AND g.owner_id = auth.uid()
    )
  );

-- Admin full access
DROP POLICY IF EXISTS "events_admin_all" ON public.events;
CREATE POLICY "events_admin_all"
  ON public.events FOR ALL
  USING (
    EXISTS (SELECT 1 FROM public.profiles WHERE id = auth.uid() AND role = 'admin')
  );

-- ─────────────────────────────────────────────────
-- 6. RPC: create_booking_with_event
-- Atomically creates an event + a linked reservation.
-- Called from BookingScreen (client/BookingScreen.tsx).
-- The calculate_commission trigger runs on reservation INSERT
-- and sets platform_commission / group_earnings automatically.
-- ─────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.create_booking_with_event(
  p_client_id   UUID,
  p_group_id    UUID,
  p_package_id  UUID,
  p_event_date  DATE,
  p_event_time  TIME    DEFAULT NULL,
  p_address     TEXT    DEFAULT '',
  p_total_price DECIMAL DEFAULT 0,
  p_notes       TEXT    DEFAULT NULL,
  p_break_type  TEXT    DEFAULT 'A'
)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_event_id UUID;
BEGIN
  -- 1. Create the parent event record
  INSERT INTO events (client_id, event_date, address, status)
  VALUES (p_client_id, p_event_date, p_address, 'active')
  RETURNING id INTO v_event_id;

  -- 2. Create the reservation linked to that event.
  --    commission / earnings are set to 0 here; the
  --    calculate_commission BEFORE INSERT trigger overwrites them.
  INSERT INTO reservations (
    event_id,
    group_id,
    package_id,
    client_id,
    event_date,
    event_time,
    address,
    notes,
    break_type,
    total_price,
    platform_commission,
    group_earnings,
    status,
    deposit_paid
  )
  VALUES (
    v_event_id,
    p_group_id,
    p_package_id,
    p_client_id,
    p_event_date,
    p_event_time,
    p_address,
    p_notes,
    p_break_type,
    p_total_price,
    0,      -- overwritten by trigger
    0,      -- overwritten by trigger
    'pending_provider_confirmation',
    FALSE
  );

  RETURN v_event_id;
END;
$$;

-- ─────────────────────────────────────────────────
-- 7. Rebuild admin_dashboard_stats to handle new statuses
-- ─────────────────────────────────────────────────
DROP MATERIALIZED VIEW IF EXISTS admin_dashboard_stats;
CREATE MATERIALIZED VIEW admin_dashboard_stats AS
SELECT
  COUNT(*)                                                          AS total_reservations,
  COUNT(*) FILTER (WHERE status IN (
    'pending', 'pending_payment', 'pending_provider_confirmation'
  ))                                                                AS pending_reservations,
  COUNT(*) FILTER (WHERE status = 'confirmed')                      AS confirmed_reservations,
  COUNT(*) FILTER (WHERE status = 'in_progress')                    AS active_events,
  COUNT(*) FILTER (WHERE status = 'completed')                      AS completed_reservations,
  COALESCE(SUM(total_price), 0)                                     AS total_revenue,
  COALESCE(SUM(platform_commission), 0)                             AS total_commission,
  COALESCE(SUM(group_earnings), 0)                                  AS total_group_earnings,
  COALESCE(
    SUM(total_price) FILTER (
      WHERE created_at >= date_trunc('month', NOW())
    ), 0
  )                                                                 AS monthly_revenue,
  COALESCE(
    SUM(platform_commission) FILTER (
      WHERE created_at >= date_trunc('month', NOW())
    ), 0
  )                                                                 AS monthly_commission
FROM public.reservations;

-- Unique index required for REFRESH CONCURRENTLY (single-row view trick)
CREATE UNIQUE INDEX IF NOT EXISTS idx_admin_dashboard_stats_singleton
  ON admin_dashboard_stats ((1));

GRANT SELECT ON admin_dashboard_stats TO authenticated;

SELECT 'Estructura multi-evento creada correctamente ✅' AS status;
