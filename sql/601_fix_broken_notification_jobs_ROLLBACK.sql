-- ============================================================
-- sql/601_fix_broken_notification_jobs_ROLLBACK.sql
-- JAMÁS correr salvo emergencia deliberada.
-- Revierte sql/601 a las versiones ANTERIORES, que estaban ROTAS (ver
-- sql/601 para el detalle de cada bug). Solo tiene sentido correr esto
-- si el fix introdujo un problema nuevo peor que los 5 originales.
-- ============================================================

BEGIN;

ALTER TABLE public.notifications DROP CONSTRAINT notifications_type_check;
ALTER TABLE public.notifications ADD CONSTRAINT notifications_type_check CHECK (type = ANY (ARRAY[
  'reservation','payment','review','verification','system','financial','admin_alert','admin','general',
  'booking','booking_received','booking_accepted','booking_confirmed','booking_rejected','booking_auto_cancelled',
  'booking_expired_no_payment','booking_cancelled','deposit_received','payment_released','payment_received',
  'payment_mismatch','payout','wallet','event_reminder_24h','event_upcoming_24h','event_reminder_morning',
  'event_reminder_1h','event_reminder_3h','event_reminder_2h','event_reminder_15m','event_completed',
  'event_started','overtime_requested','event_auto_started','event_no_show_alert','event_finalized',
  'break_starting_soon','break_ending_soon','break_started','break_ended','dispute_opened','dispute_received',
  'dispute','job_invitation','new_quote_request','quote_received','quote_accepted','quote_cancelled',
  'quote_sent_to_client','quote_expired','chat','ad_space_available','high_demand','no_ads_in_city',
  'first_ad_reminder','ad_payment_confirmed','ad_approved','ad_rejected','ad_expiring_soon','ad_expired',
  'new_city_groups','group_nearby','bid_displaced','bid_expiring_soon','bid_expiry_reminder','zone_demand',
  'express_dispatch','fraud_alert','referral_reward','request_expired_proximity','quote_expired_proximity',
  'extra_hour_proposed','extra_hour_approved_by_client','extra_hour_payment_confirmed','extra_hour_rejected_by_client',
  'extra_hour_requested','extra_hour_rejected','extra_hour_payment_required','extra_hour_expired',
  'extra_hour_payment_expired','review_received','extra_hours_offer','sound_coordination_needed'
])) NOT VALID;
ALTER TABLE public.notifications VALIDATE CONSTRAINT notifications_type_check;

CREATE OR REPLACE FUNCTION public.queue_push_notification(
  p_user_id uuid, p_type text, p_title text, p_body text, p_data jsonb DEFAULT '{}'::jsonb
) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
BEGIN
  INSERT INTO public.notifications (user_id, type, title, body, data)
  VALUES (p_user_id, p_type, p_title, p_body, p_data);
END;
$function$;

CREATE OR REPLACE FUNCTION public.notify_today_events()
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE
  v_rec           RECORD;
  v_member_id     UUID;
  v_group_name    TEXT;
  v_client_name   TEXT;
BEGIN
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
$function$;

CREATE OR REPLACE FUNCTION public.notify_inactive_groups(p_days integer DEFAULT 7)
RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE
  v_group RECORD;
  v_count INT := 0;
BEGIN
  FOR v_group IN
    SELECT g.owner_id, g.name, g.city
    FROM   public.groups g
    WHERE  g.is_active = TRUE
      AND NOT EXISTS (
        SELECT 1 FROM public.reservations r
        WHERE  r.group_id    = g.id
          AND  r.created_at  > NOW() - (p_days || ' days')::INTERVAL
          AND  r.status NOT IN ('cancelled', 'rejected', 'expired')
      )
      AND NOT EXISTS (
        SELECT 1 FROM public.quotes q
        WHERE  q.group_id   = g.id
          AND  q.created_at > NOW() - (p_days || ' days')::INTERVAL
      )
  LOOP
    IF public.already_notified_recently(v_group.owner_id, 'engagement_inactive_group', 72) THEN
      CONTINUE;
    END IF;

    PERFORM public.queue_push_notification(
      v_group.owner_id,
      'engagement_inactive_group',
      '🎵 Tienes clientes buscando música',
      'Han pasado ' || p_days || ' días sin actividad. '
        || 'Activa "Disponible ahora" para recibir solicitudes cerca de ti.',
      jsonb_build_object(
        'screen', 'GroupHome',
        'action', 'activate_availability'
      )
    );

    v_count := v_count + 1;
  END LOOP;

  RETURN v_count;
END;
$function$;

CREATE OR REPLACE FUNCTION public.notify_weekend_groups()
RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE
  v_group   RECORD;
  v_count   INT := 0;
  v_is_fri  BOOLEAN;
  v_title   TEXT;
  v_body    TEXT;
BEGIN
  v_is_fri := EXTRACT(DOW FROM NOW() AT TIME ZONE 'America/Mexico_City') = 5;

  FOR v_group IN
    SELECT g.owner_id, g.name, g.availability
    FROM   public.groups g
    WHERE  g.is_active = TRUE
  LOOP
    IF public.already_notified_recently(v_group.owner_id, 'engagement_activate_now', 36) THEN
      CONTINUE;
    END IF;

    IF COALESCE(v_group.availability, 'available') != 'available' THEN
      v_title := '🔓 Activa tu disponibilidad este finde';
      v_body  := 'Hay clientes buscando música para el fin de semana. '
               || 'Activa "Disponible ahora" y empieza a recibir solicitudes.';
    ELSE
      IF v_is_fri THEN
        v_title := '📅 Este fin de semana hay eventos disponibles';
        v_body  := '¡Es viernes! Los clientes ya están buscando grupos para mañana y el domingo. '
                 || 'Revisa las solicitudes en tu zona.';
      ELSE
        v_title := '🎤 ¡Es sábado! Hay clientes buscando';
        v_body  := 'Clientes cerca de ti buscan música para hoy. '
                 || 'Revisa las solicitudes express antes de que otro grupo las tome.';
      END IF;
    END IF;

    PERFORM public.queue_push_notification(
      v_group.owner_id,
      'engagement_activate_now',
      v_title,
      v_body,
      jsonb_build_object(
        'screen',       'OpenRequests',
        'availability', v_group.availability
      )
    );

    v_count := v_count + 1;
  END LOOP;

  RETURN v_count;
END;
$function$;

COMMIT;

SELECT '601_fix_broken_notification_jobs — REVERTIDO (versiones anteriores, ROTAS, restauradas)' AS status;
