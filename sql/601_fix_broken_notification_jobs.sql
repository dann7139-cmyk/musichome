-- ============================================================
-- sql/601_fix_broken_notification_jobs.sql
-- ✅ APLICADO A PRODUCCIÓN 2026-09-03 — 5 BUGS REALES, TODOS FALLANDO EN
-- PRODUCCIÓN TODOS LOS DÍAS (confirmado en cron.job_run_details ANTES de
-- tocar nada: notify-today-events fallaba cada mañana a las 8am,
-- engagement-inactive-groups y engagement-weekend-groups cada tarde,
-- engagement-clients-available y engagement-weekend-clients cada vez que
-- corrían — TODOS con status='failed' y el error real en return_message).
--
-- PETICIÓN REAL DEL USUARIO (2026-09-03): "revisa que las notificaciones
-- de temporizador jalen... y todas las demás notificaciones va." Este
-- archivo es la segunda mitad de esa revisión (la primera fue sql/600,
-- el temporizador de descansos) — un barrido de TODOS los cron jobs de
-- notificaciones buscando fallas reales, no solo el que pidió primero.
--
-- 5 CAUSAS DISTINTAS ENCONTRADAS:
--
-- 1. notify_today_events() — `WHERE r.event_date = CURRENT_DATE::text`
--    comparaba una columna DATE contra un TEXT — error de tipo, la
--    función tronaba en cada ejecución (cron diario 8am). Además
--    insertaba solo en las columnas legado (message/reference_id), no en
--    las que la app realmente usa para enrutar el tap (data.reservation_id)
--    ni en `body` (el texto real del push) — se corrigió para escribir
--    ambos juegos de columnas. Se agregó también el caso
--    'event_reminder_24h' a NotificationsScreen.tsx (antes caía al
--    manejador genérico sin ruta clara a EventTimer).
--
-- 2. queue_push_notification() — sin protección contra p_user_id NULL.
--    22 grupos en producción tienen owner_id NULL (dato real, no de
--    prueba) — cualquier función que intentara notificarlos truena por
--    violar el NOT NULL de notifications.user_id, y como PL/pgSQL no
--    aísla cada INSERT del loop, la función completa aborta a medias
--    (los grupos procesados ANTES del NULL sí alcanzan a notificarse,
--    pero los de DESPUÉS en esa misma corrida no). Se agregó un guard
--    universal (`IF p_user_id IS NULL THEN RETURN`) que protege a TODOS
--    los que llamen esta función, no solo a los 2 de abajo.
--
-- 3. notify_inactive_groups() — mismo problema de owner_id NULL. Se
--    agregó `AND g.owner_id IS NOT NULL` al filtro (más limpio que
--    depender solo del guard de (2), evita iteraciones desperdiciadas).
--
-- 4. notify_weekend_groups() — mismo problema, mismo fix.
--
-- 5. notifications_type_check — 4 tipos usados por funciones YA
--    ESCRITAS (probablemente desde que se crearon) nunca estuvieron en
--    la lista permitida del CHECK constraint: 'engagement_inactive_group'
--    (usado por notify_inactive_groups), 'engagement_groups_available'
--    (notify_clients_available_groups), 'engagement_weekend_reminder'
--    (notify_weekend_clients), 'engagement_activate_now'
--    (notify_weekend_groups). Estas 4 funciones JAMÁS habían logrado
--    insertar una sola notificación exitosa — agregados los 4 tipos.
--
-- Probado en transacción autorevertible: reserva sintética de HOY real
-- notificó a cliente+dueño+integrante con body real (no vacío) y
-- data.reservation_id correcto; queue_push_notification con user_id NULL
-- ya no truena; notify_inactive_groups y notify_weekend_groups
-- sobrevivieron un grupo real con owner_id NULL sin abortar. 0 residuo
-- verificado. Aplicado para real después, verificado en vivo que las 5
-- correcciones quedaron en las funciones desplegadas.
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
  'extra_hour_payment_expired','review_received','extra_hours_offer','sound_coordination_needed',
  'engagement_inactive_group','engagement_groups_available','engagement_weekend_reminder','engagement_activate_now'
])) NOT VALID;
ALTER TABLE public.notifications VALIDATE CONSTRAINT notifications_type_check;

CREATE OR REPLACE FUNCTION public.queue_push_notification(
  p_user_id uuid, p_type text, p_title text, p_body text, p_data jsonb DEFAULT '{}'::jsonb
) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
BEGIN
  IF p_user_id IS NULL THEN RETURN; END IF;
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
      r.id AS reservation_id, r.client_id, r.group_id, r.event_date, r.event_time,
      g.name AS group_name, g.owner_id, p.full_name AS client_name
    FROM public.reservations r
    JOIN public.groups       g ON g.id = r.group_id
    JOIN public.profiles     p ON p.id = r.client_id
    WHERE r.event_date = CURRENT_DATE
      AND r.status IN ('confirmed', 'accepted', 'in_progress')
  LOOP
    v_group_name  := v_rec.group_name;
    v_client_name := v_rec.client_name;

    IF v_rec.owner_id IS NOT NULL THEN
      INSERT INTO public.notifications (user_id, type, title, message, body, reference_id, data)
      VALUES (
        v_rec.owner_id, 'event_reminder_24h', '🎵 ¡Hoy es el evento!',
        '¡' || v_group_name || ' brilla hoy! El evento con ' || v_client_name ||
        ' es hoy' || COALESCE(' a las ' || v_rec.event_time, '') || '. ¡Mucha energía y éxito! 🎶',
        '¡' || v_group_name || ' brilla hoy! El evento con ' || v_client_name ||
        ' es hoy' || COALESCE(' a las ' || v_rec.event_time, '') || '. ¡Mucha energía y éxito! 🎶',
        v_rec.reservation_id,
        jsonb_build_object('reservation_id', v_rec.reservation_id, 'screen', 'EventTimer')
      )
      ON CONFLICT DO NOTHING;
    END IF;

    FOR v_member_id IN
      SELECT ji.invited_user_id FROM public.job_invitations ji
      WHERE ji.group_id = v_rec.group_id AND ji.status = 'accepted'
        AND ji.event_id IS NULL AND ji.invited_user_id != v_rec.owner_id
    LOOP
      INSERT INTO public.notifications (user_id, type, title, message, body, reference_id, data)
      VALUES (
        v_member_id, 'event_reminder_24h', '🎵 ¡Hoy es el evento!',
        '¡Hoy toca con ' || v_group_name || '! El evento es hoy' ||
        COALESCE(' a las ' || v_rec.event_time, '') || '. ¡Dalo todo, el equipo cuenta contigo! 🔥',
        '¡Hoy toca con ' || v_group_name || '! El evento es hoy' ||
        COALESCE(' a las ' || v_rec.event_time, '') || '. ¡Dalo todo, el equipo cuenta contigo! 🔥',
        v_rec.reservation_id,
        jsonb_build_object('reservation_id', v_rec.reservation_id, 'screen', 'EventTimer')
      )
      ON CONFLICT DO NOTHING;
    END LOOP;

    IF v_rec.client_id IS NOT NULL THEN
      INSERT INTO public.notifications (user_id, type, title, message, body, reference_id, data)
      VALUES (
        v_rec.client_id, 'event_reminder_24h', '🎶 ¡Tu evento es hoy!',
        v_group_name || ' se está alistando para hacer de tu evento algo inolvidable' ||
        COALESCE(' a las ' || v_rec.event_time, '') || '. ¡Prepárate! 🎉',
        v_group_name || ' se está alistando para hacer de tu evento algo inolvidable' ||
        COALESCE(' a las ' || v_rec.event_time, '') || '. ¡Prepárate! 🎉',
        v_rec.reservation_id,
        jsonb_build_object('reservation_id', v_rec.reservation_id, 'screen', 'EventTimer')
      )
      ON CONFLICT DO NOTHING;
    END IF;
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
      AND  g.owner_id IS NOT NULL
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
      v_group.owner_id, 'engagement_inactive_group', '🎵 Tienes clientes buscando música',
      'Han pasado ' || p_days || ' días sin actividad. ' || 'Activa "Disponible ahora" para recibir solicitudes cerca de ti.',
      jsonb_build_object('screen', 'GroupHome', 'action', 'activate_availability')
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
    WHERE  g.is_active = TRUE AND g.owner_id IS NOT NULL
  LOOP
    IF public.already_notified_recently(v_group.owner_id, 'engagement_activate_now', 36) THEN
      CONTINUE;
    END IF;
    IF COALESCE(v_group.availability, 'available') != 'available' THEN
      v_title := '🔓 Activa tu disponibilidad este finde';
      v_body  := 'Hay clientes buscando música para el fin de semana. ' || 'Activa "Disponible ahora" y empieza a recibir solicitudes.';
    ELSE
      IF v_is_fri THEN
        v_title := '📅 Este fin de semana hay eventos disponibles';
        v_body  := '¡Es viernes! Los clientes ya están buscando grupos para mañana y el domingo. ' || 'Revisa las solicitudes en tu zona.';
      ELSE
        v_title := '🎤 ¡Es sábado! Hay clientes buscando';
        v_body  := 'Clientes cerca de ti buscan música para hoy. ' || 'Revisa las solicitudes express antes de que otro grupo las tome.';
      END IF;
    END IF;
    PERFORM public.queue_push_notification(
      v_group.owner_id, 'engagement_activate_now', v_title, v_body,
      jsonb_build_object('screen', 'OpenRequests', 'availability', v_group.availability)
    );
    v_count := v_count + 1;
  END LOOP;
  RETURN v_count;
END;
$function$;

COMMIT;

SELECT '601_fix_broken_notification_jobs — APLICADO A PRODUCCIÓN 2026-09-03' AS status;
