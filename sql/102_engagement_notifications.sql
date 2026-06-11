-- ════════════════════════════════════════════════════════════════════════════
-- 102_engagement_notifications.sql
-- Notificaciones de engagement para aumentar actividad en la plataforma.
-- NO modifica reservas ni pagos.
--
-- FUNCIONES:
--   1. notify_groups_with_nearby_requests()  — grupos con solicitudes express en su ciudad
--   2. notify_inactive_groups()              — grupos sin actividad reciente
--   3. notify_clients_available_groups()     — clientes sin reserva próxima
--   4. notify_weekend_clients()              — recordatorio viernes/sábado a clientes
--   5. notify_weekend_groups()               — activación fin de semana a grupos
--
-- CRONS (hora UTC, zona GDL = UTC-6):
--   Viernes 17:00 GDL  = 23:00 UTC  → clientes + grupos
--   Sábado  10:00 GDL  = 16:00 UTC  → clientes + grupos
--   Diario  12:00 GDL  = 18:00 UTC  → grupos inactivos
--   Cada 30 min                      → grupos con solicitudes express cerca
--
-- Ejecutar DESPUÉS de 101_push_notifications_complete.sql
-- ════════════════════════════════════════════════════════════════════════════

-- ── Agregar nuevos tipos de engagement al constraint ─────────────────────────
ALTER TABLE public.notifications
  DROP CONSTRAINT IF EXISTS notifications_type_check;

ALTER TABLE public.notifications
  ADD CONSTRAINT notifications_type_check
  CHECK (type IN (
    -- Tipos base
    'reservation', 'payment', 'review', 'verification', 'system',
    'financial', 'admin_alert',
    -- Reservas
    'booking', 'booking_received', 'booking_accepted', 'booking_confirmed',
    'booking_rejected', 'booking_auto_cancelled', 'booking_expired_no_payment',
    'booking_cancelled',
    -- Pagos
    'deposit_received', 'payment_released',
    -- Eventos
    'event_reminder_24h', 'event_completed', 'event_started',
    -- Overtime / Disputas
    'overtime_requested', 'dispute_opened', 'dispute_received',
    -- Bolsa / Cotizaciones
    'job_invitation', 'new_quote_request', 'quote_received',
    'quote_accepted', 'quote_cancelled',
    -- ── ENGAGEMENT (nuevos) ──────────────────────────────────────────────
    'engagement_nearby_requests',   -- grupo: hay solicitudes express en tu zona
    'engagement_inactive_group',    -- grupo: llevas días sin actividad
    'engagement_activate_now',      -- grupo: activa disponibilidad este finde
    'engagement_groups_available',  -- cliente: hay grupos disponibles
    'engagement_weekend_reminder',  -- cliente: reserva para el fin de semana
    'engagement_rebook'             -- cliente: ¿repites el evento?
  ));

-- ════════════════════════════════════════════════════════════════════════════
-- HELPER: ¿El usuario ya recibió este tipo de notificación recientemente?
-- Evita spam: retorna TRUE si ya se envió en las últimas p_hours horas.
-- ════════════════════════════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION public.already_notified_recently(
  p_user_id UUID,
  p_type    TEXT,
  p_hours   INT DEFAULT 24
)
RETURNS BOOLEAN
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM   public.notifications
    WHERE  user_id    = p_user_id
      AND  type       = p_type
      AND  created_at > NOW() - (p_hours || ' hours')::INTERVAL
  );
$$;

-- ════════════════════════════════════════════════════════════════════════════
-- 1. notify_groups_with_nearby_requests()
--    Para grupos cuya ciudad tiene solicitudes express abiertas.
--    Corre cada 30 min; solo notifica si no recibió esta alerta en 4h.
-- ════════════════════════════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION public.notify_groups_with_nearby_requests()
RETURNS INT
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_group   RECORD;
  v_count   INT := 0;
  v_req_cnt INT;
BEGIN
  FOR v_group IN
    SELECT DISTINCT
      g.owner_id,
      g.name,
      g.city,
      COUNT(er.id) AS open_requests
    FROM   public.groups g
    JOIN   public.event_requests er
           ON  LOWER(er.location_city) ILIKE '%' || LOWER(COALESCE(g.city, '')) || '%'
           AND er.status    = 'open'
           AND er.expires_at > NOW()
    WHERE  g.is_active   = TRUE
      AND  g.city        IS NOT NULL
      AND  COALESCE(g.availability, 'available') = 'available'
    GROUP BY g.owner_id, g.name, g.city
    HAVING COUNT(er.id) > 0
  LOOP
    -- No más de una notificación de este tipo cada 4 horas por grupo
    IF public.already_notified_recently(v_group.owner_id, 'engagement_nearby_requests', 4) THEN
      CONTINUE;
    END IF;

    PERFORM public.queue_push_notification(
      v_group.owner_id,
      'engagement_nearby_requests',
      '⚡ Hay ' || v_group.open_requests || ' solicitud' ||
        CASE WHEN v_group.open_requests > 1 THEN 'es' ELSE '' END || ' en tu zona',
      'Clientes en ' || v_group.city || ' buscan música ahora. ¡Acepta antes que otro grupo!',
      jsonb_build_object(
        'screen',        'OpenRequests',
        'city',          v_group.city,
        'open_requests', v_group.open_requests
      )
    );

    v_count := v_count + 1;
  END LOOP;

  RETURN v_count;
END;
$$;

GRANT EXECUTE ON FUNCTION public.notify_groups_with_nearby_requests() TO service_role;

-- ════════════════════════════════════════════════════════════════════════════
-- 2. notify_inactive_groups()
--    Grupos activos que llevan más de p_days días sin reservas ni cotizaciones.
--    Mensaje de reactivación + recordatorio de disponibilidad.
-- ════════════════════════════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION public.notify_inactive_groups(
  p_days INT DEFAULT 7
)
RETURNS INT
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_group RECORD;
  v_count INT := 0;
BEGIN
  FOR v_group IN
    SELECT g.owner_id, g.name, g.city
    FROM   public.groups g
    WHERE  g.is_active = TRUE
      -- Sin reservas recientes
      AND NOT EXISTS (
        SELECT 1 FROM public.reservations r
        WHERE  r.group_id    = g.id
          AND  r.created_at  > NOW() - (p_days || ' days')::INTERVAL
          AND  r.status NOT IN ('cancelled', 'rejected', 'expired')
      )
      -- Sin cotizaciones recientes
      AND NOT EXISTS (
        SELECT 1 FROM public.quotes q
        WHERE  q.group_id   = g.id
          AND  q.created_at > NOW() - (p_days || ' days')::INTERVAL
      )
  LOOP
    -- Máximo una vez cada 72 horas
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
$$;

GRANT EXECUTE ON FUNCTION public.notify_inactive_groups(INT) TO service_role;

-- ════════════════════════════════════════════════════════════════════════════
-- 3. notify_clients_available_groups()
--    Clientes que han usado la plataforma pero NO tienen reserva confirmada
--    próxima. Les avisa que hay grupos disponibles.
-- ════════════════════════════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION public.notify_clients_available_groups()
RETURNS INT
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_client    RECORD;
  v_grp_count INT;
  v_count     INT := 0;
BEGIN
  -- Contar grupos activos disponibles ahora
  SELECT COUNT(*) INTO v_grp_count
  FROM   public.groups
  WHERE  is_active   = TRUE
    AND  COALESCE(availability, 'available') = 'available';

  -- Sin grupos disponibles no hay nada que notificar
  IF v_grp_count = 0 THEN RETURN 0; END IF;

  FOR v_client IN
    SELECT p.id, p.full_name
    FROM   public.profiles p
    WHERE  p.role = 'client'
      -- Tienen al menos una reserva previa (usuarios activos)
      AND EXISTS (
        SELECT 1 FROM public.reservations r
        WHERE  r.client_id = p.id
      )
      -- Sin reserva confirmada en los próximos 30 días
      AND NOT EXISTS (
        SELECT 1 FROM public.reservations r
        WHERE  r.client_id  = p.id
          AND  r.status     IN ('confirmed', 'pending_group_confirmation', 'pending_payment')
          AND  r.event_date >= CURRENT_DATE
          AND  r.event_date <= CURRENT_DATE + 30
      )
  LOOP
    -- Máximo una vez cada 48 horas por cliente
    IF public.already_notified_recently(v_client.id, 'engagement_groups_available', 48) THEN
      CONTINUE;
    END IF;

    PERFORM public.queue_push_notification(
      v_client.id,
      'engagement_groups_available',
      '🎶 Hay ' || v_grp_count || ' grupo' ||
        CASE WHEN v_grp_count > 1 THEN 's' ELSE '' END || ' disponibles cerca',
      'Reserva música para tu próximo evento antes de que se llenen.',
      jsonb_build_object(
        'screen',       'Música',
        'groups_count', v_grp_count
      )
    );

    v_count := v_count + 1;
  END LOOP;

  RETURN v_count;
END;
$$;

GRANT EXECUTE ON FUNCTION public.notify_clients_available_groups() TO service_role;

-- ════════════════════════════════════════════════════════════════════════════
-- 4. notify_weekend_clients()
--    Recordatorio de fin de semana para clientes sin reserva próxima.
--    Enviado viernes tarde + sábado mañana.
-- ════════════════════════════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION public.notify_weekend_clients()
RETURNS INT
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_client  RECORD;
  v_is_fri  BOOLEAN;
  v_count   INT := 0;
  v_title   TEXT;
  v_body    TEXT;
BEGIN
  v_is_fri := EXTRACT(DOW FROM NOW() AT TIME ZONE 'America/Mexico_City') = 5;

  IF v_is_fri THEN
    v_title := '🎉 ¿Planes para este fin de semana?';
    v_body  := 'Aún hay grupos disponibles para el sábado. ¡Reserva hoy antes de que se llenen!';
  ELSE
    v_title := '🎸 ¡Es sábado! Haz tu evento especial';
    v_body  := 'Hay grupos disponibles para esta noche. Reserva en minutos y sorprende a tus invitados.';
  END IF;

  FOR v_client IN
    SELECT p.id
    FROM   public.profiles p
    WHERE  p.role = 'client'
      AND EXISTS (
        SELECT 1 FROM public.reservations r WHERE r.client_id = p.id
      )
      AND NOT EXISTS (
        SELECT 1 FROM public.reservations r
        WHERE  r.client_id  = p.id
          AND  r.status     IN ('confirmed', 'pending_group_confirmation')
          AND  r.event_date BETWEEN CURRENT_DATE AND CURRENT_DATE + 3
      )
  LOOP
    -- Solo una vez por fin de semana (36 horas entre viernes y sábado)
    IF public.already_notified_recently(v_client.id, 'engagement_weekend_reminder', 36) THEN
      CONTINUE;
    END IF;

    PERFORM public.queue_push_notification(
      v_client.id,
      'engagement_weekend_reminder',
      v_title,
      v_body,
      jsonb_build_object('screen', 'Música')
    );

    v_count := v_count + 1;
  END LOOP;

  RETURN v_count;
END;
$$;

GRANT EXECUTE ON FUNCTION public.notify_weekend_clients() TO service_role;

-- ════════════════════════════════════════════════════════════════════════════
-- 5. notify_weekend_groups()
--    Activa grupos el fin de semana: recuerda que hay clientes buscando.
--    También empuja a grupos con availability != 'available' a activarse.
-- ════════════════════════════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION public.notify_weekend_groups()
RETURNS INT
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
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
    -- 36h entre notificaciones de fin de semana por grupo
    IF public.already_notified_recently(v_group.owner_id, 'engagement_activate_now', 36) THEN
      CONTINUE;
    END IF;

    -- Mensaje según si ya están disponibles o no
    IF COALESCE(v_group.availability, 'available') != 'available' THEN
      -- Grupo no disponible → empujarlo a activarse
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
$$;

GRANT EXECUTE ON FUNCTION public.notify_weekend_groups() TO service_role;

-- ════════════════════════════════════════════════════════════════════════════
-- PROGRAMAR CRONS
-- Todos en UTC (GDL = UTC-6 CDT / UTC-7 CST)
-- ════════════════════════════════════════════════════════════════════════════

DO $$
BEGIN

  -- Solicitudes express cerca → cada 30 min
  BEGIN PERFORM cron.unschedule('engagement-nearby-requests'); EXCEPTION WHEN OTHERS THEN NULL; END;
  PERFORM cron.schedule(
    'engagement-nearby-requests',
    '*/30 * * * *',
    'SELECT public.notify_groups_with_nearby_requests()'
  );

  -- Grupos inactivos → diario a las 18:00 UTC (12:00 GDL)
  BEGIN PERFORM cron.unschedule('engagement-inactive-groups'); EXCEPTION WHEN OTHERS THEN NULL; END;
  PERFORM cron.schedule(
    'engagement-inactive-groups',
    '0 18 * * *',
    'SELECT public.notify_inactive_groups(7)'
  );

  -- Clientes sin reserva próxima → lunes, miércoles, viernes a las 18:00 UTC
  BEGIN PERFORM cron.unschedule('engagement-clients-available'); EXCEPTION WHEN OTHERS THEN NULL; END;
  PERFORM cron.schedule(
    'engagement-clients-available',
    '0 18 * * 1,3,5',
    'SELECT public.notify_clients_available_groups()'
  );

  -- Recordatorio fin de semana clientes → viernes 23:00 UTC (17:00 GDL) + sábado 16:00 UTC (10:00 GDL)
  BEGIN PERFORM cron.unschedule('engagement-weekend-clients'); EXCEPTION WHEN OTHERS THEN NULL; END;
  PERFORM cron.schedule(
    'engagement-weekend-clients',
    '0 23 * * 5',   -- viernes 17:00 GDL
    'SELECT public.notify_weekend_clients()'
  );

  BEGIN PERFORM cron.unschedule('engagement-weekend-clients-sat'); EXCEPTION WHEN OTHERS THEN NULL; END;
  PERFORM cron.schedule(
    'engagement-weekend-clients-sat',
    '0 16 * * 6',   -- sábado 10:00 GDL
    'SELECT public.notify_weekend_clients()'
  );

  -- Activación fin de semana grupos → viernes 22:00 UTC (16:00 GDL) + sábado 15:00 UTC (9:00 GDL)
  BEGIN PERFORM cron.unschedule('engagement-weekend-groups'); EXCEPTION WHEN OTHERS THEN NULL; END;
  PERFORM cron.schedule(
    'engagement-weekend-groups',
    '0 22 * * 5',   -- viernes 16:00 GDL
    'SELECT public.notify_weekend_groups()'
  );

  BEGIN PERFORM cron.unschedule('engagement-weekend-groups-sat'); EXCEPTION WHEN OTHERS THEN NULL; END;
  PERFORM cron.schedule(
    'engagement-weekend-groups-sat',
    '0 15 * * 6',   -- sábado 9:00 GDL
    'SELECT public.notify_weekend_groups()'
  );

EXCEPTION WHEN OTHERS THEN
  RAISE NOTICE 'Error registrando crons de engagement: %', SQLERRM;
END;
$$;

-- Verificar que quedaron registrados
SELECT jobname, schedule
FROM   cron.job
WHERE  jobname LIKE 'engagement-%'
ORDER  BY jobname;

SELECT '102_engagement_notifications: engagement push notifications ✅' AS status;
