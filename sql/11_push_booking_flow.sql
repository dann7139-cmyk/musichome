-- ============================================================
-- DARICEFY - 11_push_booking_flow.sql
-- Push Notifications + 50% Booking Flow + Event Completion
-- Run AFTER 10_job_board.sql
-- ============================================================

-- ─────────────────────────────────────────────────
-- 1. push_tokens TABLE
--    One row per device. A user can have multiple devices.
--    Token must be globally unique (one device = one user at a time).
-- ─────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.push_tokens (
  id         UUID    PRIMARY KEY DEFAULT gen_random_uuid(),
  created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

ALTER TABLE public.push_tokens
  ADD COLUMN IF NOT EXISTS user_id  UUID NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE;
ALTER TABLE public.push_tokens
  ADD COLUMN IF NOT EXISTS token    TEXT NOT NULL;
ALTER TABLE public.push_tokens
  ADD COLUMN IF NOT EXISTS platform TEXT NOT NULL DEFAULT 'ios';

DO $$ BEGIN
  ALTER TABLE public.push_tokens
    ADD CONSTRAINT push_tokens_token_unique UNIQUE (token);
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

DO $$ BEGIN
  ALTER TABLE public.push_tokens
    ADD CONSTRAINT push_tokens_platform_check
    CHECK (platform IN ('ios', 'android', 'web'));
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

-- ─────────────────────────────────────────────────
-- 2. EXTEND notifications TABLE
--    Add push_sent_at so the Edge Function knows what to deliver
--    and what was already dispatched.
-- ─────────────────────────────────────────────────
ALTER TABLE public.notifications
  ADD COLUMN IF NOT EXISTS push_sent_at TIMESTAMP WITH TIME ZONE;

-- ─────────────────────────────────────────────────
-- 3. EXTEND reservations TABLE (safe additions only)
--    booking_expiration_at     — 24h deadline for group to confirm
--    client_confirmed_complete — client must explicitly approve completion
--
--    NOTE: deposit_amount, remaining_amount, payment_status, payment_authorized
--    already exist in this table — do NOT re-add them.
-- ─────────────────────────────────────────────────
ALTER TABLE public.reservations
  ADD COLUMN IF NOT EXISTS booking_expiration_at     TIMESTAMP WITH TIME ZONE;
ALTER TABLE public.reservations
  ADD COLUMN IF NOT EXISTS client_confirmed_complete BOOLEAN NOT NULL DEFAULT FALSE;

-- Add pending_group_confirmation to the status constraint.
-- Drop the old constraint (defined in 08_events_table.sql) and re-add
-- with the extra value — all previous valid values are preserved.
ALTER TABLE public.reservations
  DROP CONSTRAINT IF EXISTS reservations_status_check;

ALTER TABLE public.reservations
  ADD CONSTRAINT reservations_status_check
  CHECK (status IN (
    -- Legacy (backward compat)
    'pending',
    'in_progress',
    'rejected',
    -- Active statuses
    'pending_payment',
    'pending_provider_confirmation',
    'pending_group_confirmation',     -- ← NEW: waiting for group to accept
    'confirmed',
    'completed',
    'cancelled',
    'expired'
  ));

-- ─────────────────────────────────────────────────
-- 4. INDEXES
-- ─────────────────────────────────────────────────
CREATE INDEX IF NOT EXISTS idx_push_tokens_user_id
  ON public.push_tokens(user_id);

-- Partial index: only pending_group_confirmation rows with an expiration
CREATE INDEX IF NOT EXISTS idx_reservations_expiry
  ON public.reservations(booking_expiration_at)
  WHERE status = 'pending_group_confirmation'
    AND booking_expiration_at IS NOT NULL;

-- Index for notifications not yet pushed
CREATE INDEX IF NOT EXISTS idx_notifications_unsent_push
  ON public.notifications(created_at)
  WHERE push_sent_at IS NULL;

-- ─────────────────────────────────────────────────
-- 5. RLS: push_tokens
-- ─────────────────────────────────────────────────
ALTER TABLE public.push_tokens ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "push_tokens_select" ON public.push_tokens;
CREATE POLICY "push_tokens_select"
  ON public.push_tokens FOR SELECT
  USING (user_id = auth.uid());

DROP POLICY IF EXISTS "push_tokens_insert" ON public.push_tokens;
CREATE POLICY "push_tokens_insert"
  ON public.push_tokens FOR INSERT
  WITH CHECK (user_id = auth.uid());

DROP POLICY IF EXISTS "push_tokens_delete" ON public.push_tokens;
CREATE POLICY "push_tokens_delete"
  ON public.push_tokens FOR DELETE
  USING (user_id = auth.uid());

DROP POLICY IF EXISTS "push_tokens_admin" ON public.push_tokens;
CREATE POLICY "push_tokens_admin"
  ON public.push_tokens FOR ALL
  USING (
    EXISTS (SELECT 1 FROM public.profiles WHERE id = auth.uid() AND role = 'admin')
  );

-- ─────────────────────────────────────────────────
-- 6. RPC: register_push_token
--    Upserts a token. If the same device logs in with a different account,
--    the token is reassigned to the new user.
-- ─────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.register_push_token(
  p_token    TEXT,
  p_platform TEXT DEFAULT 'ios'
)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  INSERT INTO public.push_tokens (user_id, token, platform)
  VALUES (auth.uid(), p_token, p_platform)
  ON CONFLICT (token)
  DO UPDATE SET
    user_id  = auth.uid(),
    platform = EXCLUDED.platform;
END;
$$;

-- ─────────────────────────────────────────────────
-- 7. HELPER: queue_push_notification
--    Centralised insert into notifications so every trigger
--    goes through one place.
-- ─────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.queue_push_notification(
  p_user_id UUID,
  p_type    TEXT,
  p_title   TEXT,
  p_body    TEXT,
  p_data    JSONB DEFAULT '{}'
)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  INSERT INTO public.notifications (user_id, type, title, body, data)
  VALUES (p_user_id, p_type, p_title, p_body, p_data);
END;
$$;

-- ─────────────────────────────────────────────────
-- 8. TRIGGER: booking lifecycle notifications
--    Fires AFTER INSERT or UPDATE on reservations.
--    Handles all notification events for the booking flow.
-- ─────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.notify_booking_events()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_group_owner_id UUID;
  v_client_name    TEXT;
  v_group_name     TEXT;
BEGIN
  -- Resolve group owner + display names
  SELECT g.owner_id, g.name
  INTO   v_group_owner_id, v_group_name
  FROM   public.groups g
  WHERE  g.id = NEW.group_id;

  SELECT p.full_name
  INTO   v_client_name
  FROM   public.profiles p
  WHERE  p.id = NEW.client_id;

  -- ── INSERT: client created a booking ──────────────────────────────────────
  IF TG_OP = 'INSERT' THEN
    PERFORM public.queue_push_notification(
      v_group_owner_id,
      'booking_received',
      'Nueva solicitud de reserva',
      COALESCE(v_client_name, 'Un cliente') || ' quiere reservar a ' ||
        COALESCE(v_group_name, 'tu grupo'),
      jsonb_build_object(
        'reservation_id', NEW.id,
        'client_id',      NEW.client_id,
        'event_date',     NEW.event_date
      )
    );
    RETURN NEW;
  END IF;

  -- ── UPDATE: status changed ─────────────────────────────────────────────────
  IF TG_OP = 'UPDATE' AND (OLD.status IS DISTINCT FROM NEW.status
                          OR OLD.client_confirmed_complete IS DISTINCT FROM NEW.client_confirmed_complete)
  THEN

    -- Group confirmed the booking → notify client
    IF NEW.status = 'confirmed' AND OLD.status != 'confirmed' THEN
      PERFORM public.queue_push_notification(
        NEW.client_id,
        'booking_confirmed',
        '¡Reserva confirmada!',
        COALESCE(v_group_name, 'El grupo') || ' confirmó tu reserva para el ' ||
          TO_CHAR(NEW.event_date::DATE, 'DD/MM/YYYY'),
        jsonb_build_object('reservation_id', NEW.id)
      );

    -- Group rejected → notify client (refund will be processed)
    ELSIF NEW.status = 'rejected' AND OLD.status != 'rejected' THEN
      PERFORM public.queue_push_notification(
        NEW.client_id,
        'booking_rejected',
        'Reserva no aceptada',
        COALESCE(v_group_name, 'El grupo') ||
          ' no pudo aceptar tu solicitud. Tu depósito será reembolsado.',
        jsonb_build_object('reservation_id', NEW.id)
      );

    -- Auto-cancelled (group didn't respond in 24h) → notify client
    ELSIF NEW.status = 'cancelled' AND OLD.status = 'pending_group_confirmation' THEN
      PERFORM public.queue_push_notification(
        NEW.client_id,
        'booking_auto_cancelled',
        'Reserva cancelada automáticamente',
        'El grupo no respondió dentro de las 24 horas. Tu depósito será reembolsado.',
        jsonb_build_object('reservation_id', NEW.id)
      );

    -- Client confirmed event complete → notify group + client
    ELSIF NEW.status = 'completed' AND NEW.client_confirmed_complete = TRUE
      AND OLD.client_confirmed_complete = FALSE
    THEN
      -- Notify group: payment is released
      PERFORM public.queue_push_notification(
        v_group_owner_id,
        'event_completed',
        'Evento completado',
        'El cliente confirmó el evento. El pago restante ha sido liberado.',
        jsonb_build_object('reservation_id', NEW.id)
      );
      -- Notify client: confirmation receipt
      PERFORM public.queue_push_notification(
        NEW.client_id,
        'payment_released',
        'Pago liberado',
        '¡Gracias! El pago restante fue liberado a ' ||
          COALESCE(v_group_name, 'el grupo') || '.',
        jsonb_build_object('reservation_id', NEW.id)
      );

    END IF;
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trigger_notify_booking_events ON public.reservations;
CREATE TRIGGER trigger_notify_booking_events
  AFTER INSERT OR UPDATE ON public.reservations
  FOR EACH ROW EXECUTE FUNCTION public.notify_booking_events();

-- ─────────────────────────────────────────────────
-- 9. RPC: set_booking_expiration
--    Called after the 50% deposit is confirmed by Stripe.
--    Sets status → pending_group_confirmation and starts the 24h clock.
-- ─────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.set_booking_expiration(
  p_reservation_id UUID,
  p_deposit_amount DECIMAL(10,2)
)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_total DECIMAL(10,2);
BEGIN
  SELECT total_price INTO v_total
  FROM public.reservations
  WHERE id = p_reservation_id AND client_id = auth.uid();

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Reservation not found or access denied';
  END IF;

  UPDATE public.reservations
  SET
    status                = 'pending_group_confirmation',
    deposit_amount        = p_deposit_amount,
    remaining_amount      = v_total - p_deposit_amount,
    booking_expiration_at = NOW() + INTERVAL '24 hours'
  WHERE id = p_reservation_id;
END;
$$;

-- ─────────────────────────────────────────────────
-- 10. RPC: group_confirm_booking
--     Group owner accepts the booking within 24h.
-- ─────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.group_confirm_booking(
  p_reservation_id UUID
)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_res RECORD;
BEGIN
  SELECT r.*, g.owner_id
  INTO   v_res
  FROM   public.reservations r
  JOIN   public.groups g ON g.id = r.group_id
  WHERE  r.id = p_reservation_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Reservation not found';
  END IF;

  IF v_res.owner_id != auth.uid() THEN
    RAISE EXCEPTION 'Only the group owner can confirm this booking';
  END IF;

  IF v_res.status != 'pending_group_confirmation' THEN
    RAISE EXCEPTION 'Booking is not pending confirmation. Current status: %', v_res.status;
  END IF;

  -- If expired, reject instead of confirm
  IF v_res.booking_expiration_at IS NOT NULL AND v_res.booking_expiration_at < NOW() THEN
    RAISE EXCEPTION 'Booking confirmation window has expired';
  END IF;

  UPDATE public.reservations
  SET status = 'confirmed'
  WHERE id = p_reservation_id;
END;
$$;

-- ─────────────────────────────────────────────────
-- 11. RPC: group_reject_booking
--     Group owner declines. Triggers refund notification.
-- ─────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.group_reject_booking(
  p_reservation_id UUID
)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_res RECORD;
BEGIN
  SELECT r.*, g.owner_id
  INTO   v_res
  FROM   public.reservations r
  JOIN   public.groups g ON g.id = r.group_id
  WHERE  r.id = p_reservation_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Reservation not found';
  END IF;

  IF v_res.owner_id != auth.uid() THEN
    RAISE EXCEPTION 'Only the group owner can reject this booking';
  END IF;

  IF v_res.status != 'pending_group_confirmation' THEN
    RAISE EXCEPTION 'Booking is not pending confirmation. Current status: %', v_res.status;
  END IF;

  UPDATE public.reservations
  SET status = 'rejected'
  WHERE id = p_reservation_id;
END;
$$;

-- ─────────────────────────────────────────────────
-- 12. RPC: client_confirm_event_complete
--     Only the client can mark the event as done.
--     This releases the remaining 50% to the group (via Edge Function).
-- ─────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.client_confirm_event_complete(
  p_reservation_id UUID
)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_res RECORD;
BEGIN
  SELECT * INTO v_res
  FROM   public.reservations
  WHERE  id = p_reservation_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Reservation not found';
  END IF;

  IF v_res.client_id != auth.uid() THEN
    RAISE EXCEPTION 'Only the booking client can confirm event completion';
  END IF;

  IF v_res.status != 'confirmed' THEN
    RAISE EXCEPTION 'Reservation must be confirmed before completion. Current: %', v_res.status;
  END IF;

  IF v_res.client_confirmed_complete = TRUE THEN
    RAISE EXCEPTION 'Event already confirmed as completed';
  END IF;

  UPDATE public.reservations
  SET
    status                    = 'completed',
    client_confirmed_complete = TRUE,
    event_ended_at            = COALESCE(event_ended_at, NOW())
  WHERE id = p_reservation_id;
  -- The notify_booking_events trigger fires here automatically.
  -- The Edge Function (release-remaining-payment) listens for
  -- 'event_completed' notifications to execute the Stripe transfer.
END;
$$;

-- ─────────────────────────────────────────────────
-- 13. CRON FUNCTION: auto_cancel_expired_bookings
--     Safe to call repeatedly — only touches expired rows.
--     Returns the count of bookings cancelled this run.
--     Schedule: every 15 minutes via pg_cron or Edge Function cron.
-- ─────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.auto_cancel_expired_bookings()
RETURNS INTEGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_count INTEGER := 0;
  v_row   RECORD;
BEGIN
  FOR v_row IN
    SELECT id, client_id, group_id
    FROM   public.reservations
    WHERE  status                = 'pending_group_confirmation'
      AND  booking_expiration_at IS NOT NULL
      AND  booking_expiration_at < NOW()
  LOOP
    UPDATE public.reservations
    SET    status = 'cancelled'
    WHERE  id = v_row.id;
    -- Notification is sent by the trigger above (status → cancelled from pending_group_confirmation)
    v_count := v_count + 1;
  END LOOP;

  RETURN v_count;
END;
$$;

-- ─────────────────────────────────────────────────
-- 14. CRON FUNCTION: send_event_reminders
--     Sends a 24h-before-event notification to client + group.
--     Uses notifications table to avoid duplicate sends.
--     Schedule: every hour via pg_cron or Edge Function cron.
-- ─────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.send_event_reminders()
RETURNS INTEGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_count INTEGER := 0;
  v_row   RECORD;
  v_group_owner_id UUID;
  v_group_name     TEXT;
BEGIN
  FOR v_row IN
    SELECT r.id, r.client_id, r.group_id, r.event_date, r.event_time
    FROM   public.reservations r
    WHERE  r.status = 'confirmed'
      -- Event is between 23h and 25h from now (1h window so we don't miss it)
      AND  (r.event_date::TIMESTAMP + COALESCE(r.event_time, '00:00:00'::TIME))
           BETWEEN NOW() + INTERVAL '23 hours' AND NOW() + INTERVAL '25 hours'
      -- Not already reminded (no notification of this type for this reservation)
      AND NOT EXISTS (
        SELECT 1 FROM public.notifications n
        WHERE  n.user_id = r.client_id
          AND  n.type    = 'event_reminder_24h'
          AND  n.data ->> 'reservation_id' = r.id::TEXT
      )
  LOOP
    -- Resolve group info
    SELECT g.owner_id, g.name
    INTO   v_group_owner_id, v_group_name
    FROM   public.groups g
    WHERE  g.id = v_row.group_id;

    -- Remind client
    PERFORM public.queue_push_notification(
      v_row.client_id,
      'event_reminder_24h',
      'Tu evento es mañana',
      '¡Tu evento con ' || COALESCE(v_group_name, 'el grupo') || ' es mañana!',
      jsonb_build_object('reservation_id', v_row.id)
    );

    -- Remind group owner
    PERFORM public.queue_push_notification(
      v_group_owner_id,
      'event_reminder_24h',
      'Evento mañana',
      'Tienes un evento programado para mañana. Confirma tu asistencia.',
      jsonb_build_object('reservation_id', v_row.id)
    );

    v_count := v_count + 1;
  END LOOP;

  RETURN v_count;
END;
$$;

-- ─────────────────────────────────────────────────
-- CRON JOB SETUP (requires pg_cron extension in Supabase)
-- Enable pg_cron in Supabase Dashboard → Database → Extensions → pg_cron
-- Then run these lines ONCE manually:
-- ─────────────────────────────────────────────────
-- SELECT cron.schedule('auto-cancel-bookings',   '*/15 * * * *', $$SELECT auto_cancel_expired_bookings()$$);
-- SELECT cron.schedule('event-reminders',        '0 * * * *',    $$SELECT send_event_reminders()$$);

SELECT 'Push Notifications + Booking Flow creado correctamente ✅' AS status;
