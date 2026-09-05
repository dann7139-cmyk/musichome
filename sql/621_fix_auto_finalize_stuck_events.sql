-- 621_fix_auto_finalize_stuck_events.sql
-- Hallazgo real y serio (2026-09-05, auditoría del temporizador/descansos
-- pedida por el usuario): auto_finalize_stuck_events() — la red de
-- seguridad que cierra un evento cuando el grupo nunca llamó a
-- complete_event() (app cerrada, celular muerto, etc.) — referenciaba
-- job_invitations.event_request_id, una columna que NO EXISTE en esa
-- tabla (solo existe en reservations). Esto hacía que la función tronara
-- CADA VEZ que de verdad intentaba cerrar un evento atorado, sin manejo
-- de excepción — así que ningún evento atorado se había cerrado jamás por
-- esta vía desde que existe la función. Corrige la condición para usar el
-- mismo criterio, ya correcto, de notify_break_transitions (ji.event_id,
-- sin event_request_id).

CREATE OR REPLACE FUNCTION public.auto_finalize_stuck_events()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_res          RECORD;
  v_member       RECORD;
  v_extras       NUMERIC;
  v_expected_end TIMESTAMPTZ;
  v_dur          INT;
  v_finalized    INT := 0;
BEGIN
  IF NOT pg_try_advisory_xact_lock(7461920385) THEN
    RETURN jsonb_build_object('ok', true, 'skipped', 'locked');
  END IF;

  FOR v_res IN
    SELECT r.id, r.client_id, r.group_id, r.event_started_at,
           r.event_id, r.event_request_id,
           COALESCE(r.hours_count, 3) AS hours_count,
           g.owner_id, g.name AS group_name
    FROM  public.reservations r
    JOIN  public.groups       g ON g.id = r.group_id
    WHERE r.status           = 'in_progress'
      AND r.event_started_at IS NOT NULL
      AND r.event_ended_at   IS NULL
      AND r.event_started_at > NOW() - INTERVAL '7 days'
  LOOP

    SELECT COALESCE(SUM(hours_added), 0) INTO v_extras
    FROM   public.extra_hours
    WHERE  reservation_id = v_res.id
      AND  status IN ('accepted', 'paid');

    v_expected_end := v_res.event_started_at
      + ((v_res.hours_count + v_extras) || ' hours')::interval
      + INTERVAL '1 hour'
      + INTERVAL '2 hours';

    IF v_expected_end >= NOW() THEN
      CONTINUE;
    END IF;

    v_dur := GREATEST(0, EXTRACT(EPOCH FROM (NOW() - v_res.event_started_at))::INT / 60);
    UPDATE public.reservations
    SET status                  = 'completed',
        event_ended_at          = NOW(),
        actual_duration_minutes = COALESCE(actual_duration_minutes, v_dur),
        updated_at              = NOW()
    WHERE id = v_res.id;

    IF v_res.client_id IS NOT NULL AND NOT EXISTS (
      SELECT 1 FROM public.notifications
      WHERE type = 'event_finalized' AND user_id = v_res.client_id
        AND data->>'reservation_id' = v_res.id::text
    ) THEN
      INSERT INTO public.notifications (user_id, type, title, body, data)
      VALUES (v_res.client_id, 'event_finalized',
        '🎉 ¡Tu evento ha terminado!',
        '¿Cómo estuvo ' || COALESCE(v_res.group_name, 'el grupo') || '? Deja tu calificación.',
        jsonb_build_object('reservation_id', v_res.id, 'target_screen', 'EventTimer', 'auto_finalized', true));
    END IF;

    IF v_res.owner_id IS NOT NULL AND NOT EXISTS (
      SELECT 1 FROM public.notifications
      WHERE type = 'event_finalized' AND user_id = v_res.owner_id
        AND data->>'reservation_id' = v_res.id::text
    ) THEN
      INSERT INTO public.notifications (user_id, type, title, body, data)
      VALUES (v_res.owner_id, 'event_finalized',
        '✅ Evento finalizado',
        'El evento se cerró automáticamente. Tu pago se procesará como siempre.',
        jsonb_build_object('reservation_id', v_res.id, 'target_screen', 'EventTimer', 'auto_finalized', true));
    END IF;

    -- Fix: sin event_request_id (no existe en job_invitations)
    FOR v_member IN
      SELECT DISTINCT ji.invited_user_id AS user_id
      FROM   public.job_invitations ji
      WHERE  ji.status           = 'accepted'
        AND  ji.invited_user_id != v_res.owner_id
        AND (
              (ji.group_id = v_res.group_id AND ji.event_id IS NULL)
           OR (v_res.event_id IS NOT NULL AND ji.event_id = v_res.event_id)
        )
    LOOP
      IF NOT EXISTS (
        SELECT 1 FROM public.notifications
        WHERE type = 'event_finalized' AND user_id = v_member.user_id
          AND data->>'reservation_id' = v_res.id::text
      ) THEN
        INSERT INTO public.notifications (user_id, type, title, body, data)
        VALUES (v_member.user_id, 'event_finalized',
          '✅ Evento finalizado',
          'El evento se cerró. Revisa tus ganancias en la app.',
          jsonb_build_object('reservation_id', v_res.id, 'target_screen', 'EventTimer', 'auto_finalized', true));
      END IF;
    END LOOP;

    v_finalized := v_finalized + 1;
  END LOOP;

  RETURN jsonb_build_object('ok', true, 'finalized', v_finalized);
END;
$function$;
