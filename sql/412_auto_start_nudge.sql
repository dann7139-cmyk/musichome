-- ============================================================
-- sql/412_auto_start_nudge.sql
-- A5 · auto_start_due_events: Caso 0 "¿ya empezaron?" al owner
--
-- Nudge al grupo cuando: ya marcó llegada + la hora del evento pasó
-- + aún NO se cumplen los 10 min del auto-start. Reusa el type
-- 'event_auto_started' (ya permitido en el constraint, no se toca).
-- Dedupe con NOT EXISTS + marcador data->>'nudge' = 'true' para no
-- chocar con la notificación del auto-start real (mismo type).
-- Caso 1 (auto-start) y Caso 2 (no-show) quedan EXACTAMENTE igual.
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
  v_nudges_sent INT := 0;
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

    -- ── CASO 0 [412]: Grupo llegó, hora pasada, dentro de la gracia de
    --    10 min → nudge "¿ya empezaron?" al owner (antes del auto-start) ──
    IF v_res.group_arrived_at IS NOT NULL
       AND v_event_ts + INTERVAL '10 minutes' > NOW()
       AND NOT EXISTS (
         SELECT 1 FROM public.notifications
         WHERE data->>'reservation_id' = v_res.id::text
           AND type = 'event_auto_started'
           AND data->>'nudge' = 'true'
       )
    THEN
      IF v_res.owner_id IS NOT NULL THEN
        INSERT INTO public.notifications (user_id, type, title, body, data)
        VALUES (
          v_res.owner_id,
          'event_auto_started',
          '🎸 ¿Ya empezaron a tocar?',
          'Marca el inicio de tu evento en la app.',
          jsonb_build_object(
            'reservation_id', v_res.id,
            'screen',         'EventTimer',
            'nudge',          true
          )
        );
        v_nudges_sent := v_nudges_sent + 1;
      END IF;
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

  IF v_started > 0 OR v_alerts_sent > 0 OR v_nudges_sent > 0 THEN
    RAISE NOTICE '[auto-start-events] Iniciados: %, alertas no-show: %, nudges: %',
      v_started, v_alerts_sent, v_nudges_sent;
  END IF;

  RETURN v_started;
END;
$$;

GRANT EXECUTE ON FUNCTION public.auto_start_due_events() TO service_role;

-- (El cron 'auto-start-events' cada 5 min ya está registrado — no se toca.)

-- ── Verificaciones ────────────────────────────────────────────────────────────
-- V1: la función contiene el nudge y conserva los casos 1 y 2
SELECT
  routine_definition LIKE '%¿Ya empezaron a tocar?%'          AS con_nudge,
  routine_definition LIKE '%iniciada automáticamente%'         AS caso1_intacto,
  routine_definition LIKE '%event_no_show_alert%'              AS caso2_intacto
FROM information_schema.routines
WHERE routine_schema = 'public' AND routine_name = 'auto_start_due_events';
-- Esperado: true | true | true

SELECT '412_auto_start_nudge.sql ejecutado ✅' AS status;
