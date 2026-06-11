-- ============================================================
-- DARICEFY - 12_fix_create_booking_with_event.sql
-- Fixes PGRST203: drops ALL overloaded versions of
-- create_booking_with_event and creates exactly ONE.
-- ============================================================

-- ─────────────────────────────────────────────────
-- STEP 1: Drop ALL existing overloads of the function.
-- We query pg_proc to find every version regardless of signature,
-- then drop each one. This is the only safe way to clear all overloads.
-- ─────────────────────────────────────────────────
DO $$
DECLARE
  r RECORD;
BEGIN
  FOR r IN
    SELECT p.oid::regprocedure::TEXT AS sig
    FROM   pg_proc p
    JOIN   pg_namespace n ON n.oid = p.pronamespace
    WHERE  p.proname = 'create_booking_with_event'
      AND  n.nspname = 'public'
  LOOP
    EXECUTE 'DROP FUNCTION IF EXISTS ' || r.sig || ' CASCADE';
    RAISE NOTICE 'Dropped: %', r.sig;
  END LOOP;
END;
$$;

-- ─────────────────────────────────────────────────
-- STEP 2: Create the ONE definitive version.
--
-- Parameters (exactly as specified):
--   p_client_id   UUID
--   p_group_id    UUID
--   p_package_id  UUID
--   p_event_date  DATE
--   p_event_time  TIME
--   p_address     TEXT
--   p_total_price NUMERIC
--   p_notes       TEXT DEFAULT NULL
--   p_break_type  TEXT DEFAULT NULL
--
-- Returns JSONB with both reservation_id and event_id so the
-- client can immediately call set_booking_expiration(reservation_id, ...).
--
-- Status flow:
--   pending_payment           ← created here (before Stripe)
--   pending_group_confirmation ← set by set_booking_expiration (after 50% paid)
--   confirmed / rejected      ← group responds
--
-- The calculate_commission BEFORE INSERT trigger automatically sets
-- platform_commission and group_earnings — no need to pass them here.
-- ─────────────────────────────────────────────────
CREATE FUNCTION public.create_booking_with_event(
  p_client_id   UUID,
  p_group_id    UUID,
  p_package_id  UUID,
  p_event_date  DATE,
  p_event_time  TIME,
  p_address     TEXT,
  p_total_price NUMERIC,
  p_notes       TEXT DEFAULT NULL,
  p_break_type  TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_event_id       UUID;
  v_reservation_id UUID;
BEGIN
  -- 1. Create the parent event record (status: active)
  INSERT INTO public.events (client_id, event_date, event_time, address, status)
  VALUES (p_client_id, p_event_date, p_event_time, p_address, 'active')
  RETURNING id INTO v_event_id;

  -- 2. Create the reservation linked to that event.
  --    Status starts at 'pending_payment' — the client must pay the
  --    50% deposit before the group is notified.
  --    platform_commission and group_earnings are intentionally omitted:
  --    the calculate_commission BEFORE INSERT trigger sets them automatically.
  INSERT INTO public.reservations (
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
    status
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
    'pending_payment'
  )
  RETURNING id INTO v_reservation_id;

  -- Return both IDs so the client can:
  --   1. Store reservation_id for the Stripe flow
  --   2. Store event_id for event management
  RETURN jsonb_build_object(
    'reservation_id', v_reservation_id,
    'event_id',       v_event_id
  );
END;
$$;

SELECT 'create_booking_with_event corregida correctamente ✅' AS status;
