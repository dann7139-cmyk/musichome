-- ══════════════════════════════════════════════════════════════════════════════
-- 42_cancel_fix_and_event_notifications.sql
-- 1. Arregla client_cancel_reservation para permitir cancelar estado 'accepted'
-- 2. Amplía el CHECK de payment_status (agrega 'remaining_pending')
-- 3. Función notify_today_events() — notificaciones el día del evento
-- 4. Cron job diario para disparar notificaciones (requiere pg_cron habilitado)
-- Ejecutar en Supabase SQL Editor.
-- ══════════════════════════════════════════════════════════════════════════════

-- ── 1. Fix client_cancel_reservation: incluir 'accepted' ─────────────────────
CREATE OR REPLACE FUNCTION public.client_cancel_reservation(
  p_reservation_id UUID
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_res       RECORD;
  v_owner_id  UUID;
BEGIN
  -- Verificar que la reserva pertenece al cliente actual
  SELECT * INTO v_res
  FROM public.reservations
  WHERE id = p_reservation_id
    AND client_id = auth.uid();

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Reserva no encontrada o sin permiso';
  END IF;

  -- Permitir cancelar en cualquier estado pre-pago
  IF v_res.status NOT IN (
    'pending', 'pending_payment', 'pending_group_confirmation', 'accepted', 'confirmed'
  ) THEN
    RAISE EXCEPTION 'No se puede cancelar una reserva con estado: %', v_res.status;
  END IF;

  -- Si el anticipo ya fue confirmado, no permitir cancelación directa
  IF v_res.payment_status IN ('deposit_paid', 'fully_paid') THEN
    RAISE EXCEPTION 'No se puede cancelar: el anticipo ya fue confirmado. Contacta soporte.';
  END IF;

  -- Cancelar la reserva
  UPDATE public.reservations
  SET status = 'cancelled'
  WHERE id = p_reservation_id;

  -- Notificar al dueño del grupo
  SELECT owner_id INTO v_owner_id
  FROM public.groups
  WHERE id = v_res.group_id;

  IF v_owner_id IS NOT NULL THEN
    INSERT INTO public.notifications (user_id, type, title, message, reference_id)
    VALUES (
      v_owner_id,
      'reservation',
      '❌ Reserva cancelada',
      'El cliente canceló la reserva del ' || v_res.event_date || '.',
      p_reservation_id
    );
  END IF;
END;
$$;

GRANT EXECUTE ON FUNCTION public.client_cancel_reservation(UUID) TO authenticated;

-- ── 2. Ampliar CHECK de payment_status ────────────────────────────────────────
-- Agrega 'remaining_pending' que usa charge-remaining cuando el cobro falla.
ALTER TABLE public.reservations
  DROP CONSTRAINT IF EXISTS reservations_payment_status_check;

ALTER TABLE public.reservations
  ADD CONSTRAINT reservations_payment_status_check
  CHECK (payment_status IN (
    'unpaid',
    'deposit_pending',
    'deposit_paid',
    'remaining_pending',
    'fully_paid'
  ));

-- ── 3. Función: notificaciones el día del evento ──────────────────────────────
-- Envía:
--   • Al dueño del grupo + integrantes: mensaje motivacional de ánimo
--   • Al cliente: "tu grupo se está alistando" (2 h antes aprox. si se corre a las 8am)
CREATE OR REPLACE FUNCTION public.notify_today_events()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_rec           RECORD;
  v_member_id     UUID;
  v_group_name    TEXT;
  v_client_name   TEXT;
BEGIN
  -- Iterar sobre reservas activas de hoy
  FOR v_rec IN
    SELECT
      r.id            AS reservation_id,
      r.client_id,
      r.group_id,
      r.event_date,
      r.event_time,
      g.name          AS group_name,
      g.owner_id,
      p.full_name     AS client_name
    FROM public.reservations r
    JOIN public.groups       g ON g.id = r.group_id
    JOIN public.profiles     p ON p.id = r.client_id
    WHERE r.event_date = CURRENT_DATE::text
      AND r.status IN ('confirmed', 'accepted', 'in_progress')
  LOOP
    v_group_name  := v_rec.group_name;
    v_client_name := v_rec.client_name;

    -- ── Notificar al dueño del grupo ──────────────────────────────────────────
    INSERT INTO public.notifications (user_id, type, title, message, reference_id)
    VALUES (
      v_rec.owner_id,
      'event_reminder_24h',
      '🎵 ¡Hoy es el evento!',
      '¡' || v_group_name || ' brilla hoy! El evento con ' || v_client_name ||
      ' es hoy' || COALESCE(' a las ' || v_rec.event_time, '') ||
      '. ¡Mucha energía y éxito! 🎶',
      v_rec.reservation_id
    )
    ON CONFLICT DO NOTHING;

    -- ── Notificar a cada integrante del grupo ─────────────────────────────────
    FOR v_member_id IN
      SELECT ji.invited_user_id
      FROM public.job_invitations ji
      WHERE ji.group_id        = v_rec.group_id
        AND ji.status          = 'accepted'
        AND ji.event_id        IS NULL
        AND ji.invited_user_id != v_rec.owner_id
    LOOP
      INSERT INTO public.notifications (user_id, type, title, message, reference_id)
      VALUES (
        v_member_id,
        'event_reminder_24h',
        '🎵 ¡Hoy es el evento!',
        '¡Hoy toca con ' || v_group_name || '! El evento es hoy' ||
        COALESCE(' a las ' || v_rec.event_time, '') ||
        '. ¡Dalo todo, el equipo cuenta contigo! 🔥',
        v_rec.reservation_id
      )
      ON CONFLICT DO NOTHING;
    END LOOP;

    -- ── Notificar al cliente ───────────────────────────────────────────────────
    INSERT INTO public.notifications (user_id, type, title, message, reference_id)
    VALUES (
      v_rec.client_id,
      'event_reminder_24h',
      '🎶 ¡Tu evento es hoy!',
      v_group_name || ' se está alistando para hacer de tu evento algo inolvidable' ||
      COALESCE(' a las ' || v_rec.event_time, '') || '. ¡Prepárate! 🎉',
      v_rec.reservation_id
    )
    ON CONFLICT DO NOTHING;

  END LOOP;
END;
$$;

GRANT EXECUTE ON FUNCTION public.notify_today_events() TO authenticated;

-- ── 4. Cron job diario a las 8:00 AM UTC ─────────────────────────────────────
-- Requiere pg_cron habilitado en Supabase (Dashboard > Database > Extensions)
-- Si no está disponible en tu plan, ejecuta notify_today_events() manualmente
-- o llámala desde una Edge Function programada en el Dashboard.
SELECT cron.schedule(
  'notify-today-events',          -- nombre del job
  '0 8 * * *',                    -- todos los días a las 8:00 AM UTC
  $$ SELECT public.notify_today_events(); $$
);

SELECT 'client_cancel_reservation actualizado (incluye accepted) ✅' AS status;
SELECT 'payment_status CHECK constraint ampliado ✅' AS status;
SELECT 'notify_today_events() creada ✅' AS status;
SELECT 'pg_cron job programado a las 8:00 AM UTC ✅' AS status;
