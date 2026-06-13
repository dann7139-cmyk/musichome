-- ============================================================
-- sql/344_auto_start_events.sql
--
-- TANDA 2: Auto-inicio de eventos en background
--
-- DISEÑO:
--   Función auto_start_due_events() llamada por cron cada 5 min.
--   Condiciones para auto-iniciar:
--     1. status = 'confirmed' Y event_started_at IS NULL
--     2. group_arrived_at IS NOT NULL  (grupo marcó llegada)
--     3. Hora del evento + 10 min de gracia ya pasó
--     4. El evento fue hace menos de 6 h (no iniciar eventos muy viejos)
--
--   Break type: último break_type usado por ese grupo en eventos completados.
--   Default 'B' (15 min único descanso) si no hay historial.
--   Razón: 'B' es el más universal y es el default que ya usa la app.
--
--   Edge case — sin llegada:
--     Si group_arrived_at IS NULL y el evento ya lleva > 30 min:
--       → NO auto-iniciar
--       → Notifica al admin con tipo 'event_no_show_alert'
--       → Solo una alerta por reserva (idempotente)
--
-- NOTIFICACIONES AL AUTO-INICIAR:
--   - Grupo: "⏰ Tu evento inició automáticamente · Abre la app"
--   - Cliente: "🎵 ¡Tu evento ha iniciado!"
-- ============================================================

CREATE OR REPLACE FUNCTION public.auto_start_due_events()
RETURNS INT
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_res         RECORD;
  v_event_ts    TIMESTAMPTZ;
  v_break_type  TEXT;
  v_started     INT := 0;
  v_alerts_sent INT := 0;
  v_admin_id    UUID;
BEGIN
  -- Advisory lock: solo 1 proceso a la vez
  IF NOT pg_try_advisory_xact_lock(7654321098) THEN
    RETURN 0;
  END IF;

  -- ID del admin para alertas de no-show (primer admin disponible)
  SELECT id INTO v_admin_id
  FROM   public.profiles
  WHERE  role = 'admin'
  LIMIT  1;

  FOR v_res IN
    SELECT
      r.id,
      r.client_id,
      r.group_id,
      r.event_date,
      r.event_time,
      r.group_arrived_at,
      g.owner_id,
      g.name AS group_name
    FROM  public.reservations r
    JOIN  public.groups       g ON g.id = r.group_id
    WHERE r.status            = 'confirmed'
      AND r.event_started_at  IS NULL
      AND r.event_ended_at    IS NULL
      AND r.event_time        IS NOT NULL
      -- Pre-filtro barato: solo eventos de hoy y ayer
      AND r.event_date BETWEEN CURRENT_DATE - 1 AND CURRENT_DATE
  LOOP

    -- Parse timestamp resiliente
    BEGIN
      v_event_ts := (
        v_res.event_date::text || 'T' || LEFT(v_res.event_time::text, 5) || ':00'
      )::TIMESTAMP AT TIME ZONE 'America/Mexico_City';
    EXCEPTION WHEN OTHERS THEN
      RAISE WARNING '[auto-start-events] Fecha inválida en reserva %', v_res.id;
      CONTINUE;
    END;

    -- Solo eventos cuya hora ya pasó
    IF v_event_ts > NOW() THEN
      CONTINUE;
    END IF;

    -- Ventana máxima: no iniciar eventos de hace más de 6 h
    IF v_event_ts < NOW() - INTERVAL '6 hours' THEN
      CONTINUE;
    END IF;

    -- ── CASO 1: Grupo llegó → auto-iniciar si pasaron 10 min ──
    IF v_res.group_arrived_at IS NOT NULL
       AND v_event_ts + INTERVAL '10 minutes' <= NOW()
    THEN

      -- Último break_type usado por este grupo en eventos completados
      SELECT break_type INTO v_break_type
      FROM   public.reservations
      WHERE  group_id    = v_res.group_id
        AND  break_type  IS NOT NULL
        AND  status      = 'completed'
      ORDER  BY event_date DESC
      LIMIT  1;

      v_break_type := COALESCE(v_break_type, 'B');

      -- Iniciar el evento
      UPDATE public.reservations
      SET
        status           = 'in_progress',
        event_started_at = v_event_ts + INTERVAL '10 minutes',  -- hora estimada de inicio
        break_type       = v_break_type
      WHERE id = v_res.id;

      -- Push al grupo
      IF v_res.owner_id IS NOT NULL THEN
        INSERT INTO public.notifications (user_id, type, title, body, data)
        VALUES (
          v_res.owner_id,
          'event_auto_started',
          '⏰ Tu evento inició automáticamente',
          'El evento comenzó. Abre la app para ver el timer y registrar el inicio oficial.',
          jsonb_build_object(
            'reservation_id', v_res.id,
            'screen',         'EventTimer',
            'auto_started',   true
          )
        );
      END IF;

      -- Push al cliente
      IF v_res.client_id IS NOT NULL THEN
        INSERT INTO public.notifications (user_id, type, title, body, data)
        VALUES (
          v_res.client_id,
          'event_auto_started',
          '🎵 ¡Tu evento ha iniciado!',
          v_res.group_name || ' ya está tocando. ¡Disfrútalo!',
          jsonb_build_object(
            'reservation_id', v_res.id,
            'screen',         'LiveEvent'
          )
        );
      END IF;

      v_started := v_started + 1;
      RAISE NOTICE '[auto-start-events] Reserva % iniciada automáticamente con break_type=%',
        v_res.id, v_break_type;

    -- ── CASO 2: Grupo NO llegó y pasaron > 30 min → alerta al admin ──
    ELSIF v_res.group_arrived_at IS NULL
          AND v_event_ts + INTERVAL '30 minutes' <= NOW()
          AND NOT EXISTS (
            SELECT 1 FROM public.notifications
            WHERE data->>'reservation_id' = v_res.id::text
              AND type = 'event_no_show_alert'
          )
    THEN
      -- Alerta al admin
      IF v_admin_id IS NOT NULL THEN
        INSERT INTO public.notifications (user_id, type, title, body, data)
        VALUES (
          v_admin_id,
          'event_no_show_alert',
          '⚠️ Posible no-show: ' || v_res.group_name,
          'El grupo no marcó llegada y el evento debió iniciar hace más de 30 min. Reserva: ' || v_res.id::text,
          jsonb_build_object(
            'reservation_id', v_res.id,
            'group_id',       v_res.group_id,
            'event_ts',       v_event_ts,
            'screen',         'AdminVerifications'
          )
        );
        v_alerts_sent := v_alerts_sent + 1;
      END IF;

      RAISE WARNING '[auto-start-events] Posible no-show: reserva %, grupo %, evento a las %',
        v_res.id, v_res.group_id, v_event_ts;
    END IF;

  END LOOP;

  IF v_started > 0 OR v_alerts_sent > 0 THEN
    RAISE NOTICE '[auto-start-events] Iniciados: %, alertas no-show: %', v_started, v_alerts_sent;
  END IF;

  RETURN v_started;
END;
$$;

GRANT EXECUTE ON FUNCTION public.auto_start_due_events() TO service_role;


-- ── Cron: cada 5 minutos ──────────────────────────────────────────────────────
DO $$ BEGIN
  PERFORM cron.unschedule('auto-start-events');
EXCEPTION WHEN OTHERS THEN NULL;
END; $$;

SELECT cron.schedule(
  'auto-start-events',
  '*/5 * * * *',
  $$SELECT public.auto_start_due_events();$$
);


-- ── Verificación ──────────────────────────────────────────────────────────────
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'auto-start-events') THEN
    RAISE NOTICE '[344] Cron auto-start-events registrado (cada 5 min) ✅';
    RAISE NOTICE '[344] Condiciones: grupo llegó + 10 min de gracia + dentro de 6 h ✅';
    RAISE NOTICE '[344] Sin llegada + 30 min → alerta al admin (no auto-inicia) ✅';
  ELSE
    RAISE WARNING '[344] ALERTA: cron auto-start-events NO encontrado';
  END IF;
END;
$$;

-- Vista previa: reservas que iniciarían ahora si corriera la función
SELECT
  r.id,
  r.event_date,
  r.event_time,
  r.group_arrived_at IS NOT NULL AS grupo_llego,
  g.name AS grupo,
  (r.event_date::text || 'T' || LEFT(r.event_time::text, 5) || ':00')::TIMESTAMP
    AT TIME ZONE 'America/Mexico_City'                             AS event_ts_mx
FROM   public.reservations r
JOIN   public.groups g ON g.id = r.group_id
WHERE  r.status           = 'confirmed'
  AND  r.event_started_at IS NULL
  AND  r.event_date BETWEEN CURRENT_DATE - 1 AND CURRENT_DATE
ORDER  BY r.event_date, r.event_time;

SELECT '344_auto_start_events.sql ejecutado ✅' AS status;
