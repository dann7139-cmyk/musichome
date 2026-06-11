-- ════════════════════════════════════════════════════════════════════
-- 58_event_day_reminders.sql
-- Sistema de recordatorios automáticos para el día del evento.
-- Envía notificaciones a cliente y grupo: mañana del día, 3h antes, 1h antes.
-- Requiere pg_cron habilitado en Supabase (Extensions → pg_cron).
-- ════════════════════════════════════════════════════════════════════

-- 1. Agregar columnas para rastrear qué recordatorios ya fueron enviados
ALTER TABLE public.reservations
  ADD COLUMN IF NOT EXISTS reminder_morning_sent BOOLEAN DEFAULT FALSE,
  ADD COLUMN IF NOT EXISTS reminder_3h_sent      BOOLEAN DEFAULT FALSE,
  ADD COLUMN IF NOT EXISTS reminder_1h_sent      BOOLEAN DEFAULT FALSE;

-- 2. Función principal de recordatorios
DROP FUNCTION IF EXISTS public.send_event_reminders();
CREATE OR REPLACE FUNCTION public.send_event_reminders()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  res          RECORD;
  event_ts     TIMESTAMPTZ;
  mins_until   INTEGER;
  grp_name     TEXT;
  cli_name     TEXT;
BEGIN
  -- Iterar reservas confirmadas con evento hoy (o mañana para morning)
  FOR res IN
    SELECT
      r.*,
      g.name      AS grp_name,
      g.owner_id  AS grp_owner_id,
      p.full_name AS cli_name
    FROM public.reservations r
    LEFT JOIN public.groups   g ON g.id = r.group_id
    LEFT JOIN public.profiles p ON p.id = r.client_id
    WHERE r.event_date BETWEEN CURRENT_DATE AND CURRENT_DATE + 1
      AND r.status IN ('confirmed', 'deposit_paid', 'in_progress')
      AND r.event_time IS NOT NULL
  LOOP
    -- Calcular timestamp y minutos restantes
    event_ts   := (res.event_date::TEXT || 'T' || res.event_time || ':00')::TIMESTAMPTZ;
    mins_until := EXTRACT(EPOCH FROM (event_ts - NOW()))::INTEGER / 60;

    grp_name := COALESCE(res.grp_name, 'el grupo');
    cli_name := COALESCE(res.cli_name, 'tu cliente');

    -- ── RECORDATORIO MAÑANA DEL EVENTO (>3h, una sola vez) ──────────
    IF NOT res.reminder_morning_sent
       AND mins_until BETWEEN 240 AND 1440 THEN

      -- Al cliente
      INSERT INTO public.notifications (user_id, type, title, body, data)
      VALUES (
        res.client_id,
        'event_reminder_24h',
        '🎉 ¡Tu evento es hoy!',
        '¡Hoy es el gran día! ' || grp_name || ' llegará a las ' || res.event_time ||
        '. Asegúrate de que el espacio esté listo y accesible para el equipo.'
        || ' Te garantizamos una experiencia musical que jamás olvidarás. ✨',
        jsonb_build_object('reservation_id', res.id)
      );

      -- Al dueño del grupo
      INSERT INTO public.notifications (user_id, type, title, body, data)
      VALUES (
        res.grp_owner_id,
        'event_reminder_24h',
        '🎵 ¡Hoy tocan! Prepárense',
        '¡Es el día del evento! El cliente ' || cli_name || ' los espera a las ' || res.event_time ||
        ' en ' || COALESCE(res.address, 'la dirección acordada') ||
        '. Revisen su equipo, carguen baterías y lleguen 30 min antes. ¡Hagan historia hoy! 🎸',
        jsonb_build_object('reservation_id', res.id)
      );

      UPDATE public.reservations SET reminder_morning_sent = TRUE WHERE id = res.id;

    -- ── RECORDATORIO 3 HORAS ANTES ──────────────────────────────────
    ELSIF NOT res.reminder_3h_sent
       AND mins_until BETWEEN 150 AND 210 THEN

      -- Al cliente
      INSERT INTO public.notifications (user_id, type, title, body, data)
      VALUES (
        res.client_id,
        'event_reminder_24h',
        '⏰ ¡Faltan 3 horas para tu evento!',
        grp_name || ' se está preparando para llegar puntual a las ' || res.event_time ||
        '. Confirma que el espacio esté despejado y el acceso esté disponible.'
        || ' La puntualidad de ambas partes garantiza una noche perfecta. 🌟',
        jsonb_build_object('reservation_id', res.id)
      );

      -- Al grupo
      INSERT INTO public.notifications (user_id, type, title, body, data)
      VALUES (
        res.grp_owner_id,
        'event_reminder_24h',
        '🎸 ¡3 horas para el show!',
        '¡Afinen los instrumentos! En 3 horas comienza el evento en ' ||
        COALESCE(res.address, 'la dirección del cliente') ||
        '. Revisen el setlist, carguen el equipo y salgan con tiempo.'
        || ' ¡El cliente los espera con emoción! 🔥',
        jsonb_build_object('reservation_id', res.id)
      );

      UPDATE public.reservations SET reminder_3h_sent = TRUE WHERE id = res.id;

    -- ── RECORDATORIO 1 HORA ANTES ───────────────────────────────────
    ELSIF NOT res.reminder_1h_sent
       AND mins_until BETWEEN 30 AND 90 THEN

      -- Al cliente
      INSERT INTO public.notifications (user_id, type, title, body, data)
      VALUES (
        res.client_id,
        'event_reminder_24h',
        '🚀 ¡El grupo está en camino!',
        '¡En menos de 1 hora comienza la magia! ' || grp_name ||
        ' ya se dirige hacia ti. Ten todo listo para recibirlos.'
        || ' Esta noche será inolvidable, ¡te lo prometemos! 🎶✨',
        jsonb_build_object('reservation_id', res.id)
      );

      -- Al grupo
      INSERT INTO public.notifications (user_id, type, title, body, data)
      VALUES (
        res.grp_owner_id,
        'event_reminder_24h',
        '🏃 ¡Es la hora de partir!',
        '¡El evento empieza en 1 hora! Sal ahora hacia ' ||
        COALESCE(res.address, 'la dirección del evento') ||
        '. El cliente ' || cli_name ||
        ' los espera con toda la emoción del mundo.'
        || ' ¡Lleguen, conecten y denlo todo! 🎤🔥',
        jsonb_build_object('reservation_id', res.id)
      );

      UPDATE public.reservations SET reminder_1h_sent = TRUE WHERE id = res.id;

    END IF;

  END LOOP;
END;
$$;

-- 3. Programar la función cada 30 minutos con pg_cron
-- Primero eliminar si ya existe
SELECT cron.unschedule('send-event-reminders') WHERE EXISTS (
  SELECT 1 FROM cron.job WHERE jobname = 'send-event-reminders'
);

SELECT cron.schedule(
  'send-event-reminders',
  '*/30 * * * *',
  $$SELECT public.send_event_reminders()$$
);

-- 4. Resetear flags de recordatorio al inicio de cada día (para reservas futuras)
-- Esto es automático ya que las columnas tienen DEFAULT FALSE en filas nuevas.
-- Para reservas existentes que se reprogramen, se puede resetear manualmente.

SELECT '58_event_day_reminders: OK ✅' AS status;
