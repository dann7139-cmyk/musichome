-- ============================================================
-- sql/600_fix_notify_break_transitions_ROLLBACK.sql
-- JAMÁS correr salvo emergencia deliberada.
-- Revierte sql/600 a la versión ANTERIOR, que estaba ROTA (referenciaba
-- la columna inexistente `ji.event_request_id` y truena con error de
-- SQL en cuanto cualquier reserva en curso golpea una frontera de
-- descanso). Solo tiene sentido correr esto si el fix de sql/600
-- introdujo un problema nuevo peor que el original — no para "deshacer
-- una mejora".
-- ============================================================

BEGIN;

CREATE OR REPLACE FUNCTION public.notify_break_transitions()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_res    RECORD;
  v_b      RECORD;
  v_member      RECORD;
  v_extras      INT;
  v_vuelve      TEXT;
  v_base_breaks INT;
  v_tanda       TEXT;
BEGIN
  IF NOT pg_try_advisory_xact_lock(9182736450) THEN
    RETURN;
  END IF;

  FOR v_res IN
    SELECT r.id, r.client_id, r.group_id, r.event_started_at,
           r.event_id, r.event_request_id,
           COALESCE(r.break_type, 'B') AS break_type,
           COALESCE(r.hours_count, 3)  AS hours_count,
           g.owner_id, g.name AS group_name
    FROM  public.reservations r
    JOIN  public.groups       g ON g.id = r.group_id
    WHERE r.status           = 'in_progress'
      AND r.event_started_at IS NOT NULL
      AND r.event_ended_at   IS NULL
      AND r.event_started_at > NOW() - INTERVAL '24 hours'
  LOOP

    SELECT COALESCE(SUM(hours_added), 0) INTO v_extras
    FROM   public.extra_hours
    WHERE  reservation_id = v_res.id
      AND  status IN ('accepted', 'paid');

    FOR v_b IN
      SELECT * FROM public.event_break_boundaries(
        v_res.event_started_at, v_res.hours_count, v_res.break_type, v_extras)
    LOOP

      IF v_b.break_start > NOW()
         AND v_b.break_start <= NOW() + INTERVAL '5 minutes'
         AND NOT EXISTS (
           SELECT 1 FROM public.notifications
           WHERE type = 'break_starting_soon'
             AND data->>'reservation_id' = v_res.id::text
             AND data->>'break_index'    = v_b.break_index::text
         )
      THEN
        IF v_res.client_id IS NOT NULL THEN
          INSERT INTO public.notifications (user_id, type, title, body, data)
          VALUES (
            v_res.client_id, 'break_starting_soon',
            '☕ Ya mero es el descanso',
            v_res.group_name || ' tomará su descanso de 15 min en unos minutos.',
            jsonb_build_object('reservation_id', v_res.id,
                               'break_index', v_b.break_index, 'screen', 'EventTimer')
          );
        END IF;
        IF v_res.owner_id IS NOT NULL THEN
          INSERT INTO public.notifications (user_id, type, title, body, data)
          VALUES (
            v_res.owner_id, 'break_starting_soon',
            '🎶 Última canción de la tanda',
            'Descanso en 5 minutos. Cierren con todo.',
            jsonb_build_object('reservation_id', v_res.id,
                               'break_index', v_b.break_index, 'screen', 'EventTimer')
          );
        END IF;
        FOR v_member IN
          SELECT DISTINCT ji.invited_user_id AS user_id
          FROM   public.job_invitations ji
          WHERE  ji.status           = 'accepted'
            AND  ji.invited_user_id != v_res.owner_id
            AND (
                  (ji.group_id = v_res.group_id
                   AND ji.event_id IS NULL AND ji.event_request_id IS NULL)
               OR (v_res.event_id IS NOT NULL AND ji.event_id = v_res.event_id)
               OR (v_res.event_request_id IS NOT NULL
                   AND ji.event_request_id = v_res.event_request_id)
            )
        LOOP
          INSERT INTO public.notifications (user_id, type, title, body, data)
          VALUES (
            v_member.user_id, 'break_starting_soon',
            '🎶 Última canción de la tanda',
            'Descanso en 5 minutos. Cierren con todo.',
            jsonb_build_object('reservation_id', v_res.id,
                               'break_index', v_b.break_index, 'screen', 'EventTimer')
          );
        END LOOP;
      END IF;

      IF v_b.break_start <= NOW()
         AND v_b.break_end  >  NOW()
         AND NOT EXISTS (
           SELECT 1 FROM public.notifications
           WHERE type = 'break_started'
             AND data->>'reservation_id' = v_res.id::text
             AND data->>'break_index'    = v_b.break_index::text
         )
      THEN
        v_vuelve := TO_CHAR(v_b.break_end AT TIME ZONE 'America/Mexico_City', 'HH12:MI');

        IF v_res.client_id IS NOT NULL THEN
          INSERT INTO public.notifications (user_id, type, title, body, data)
          VALUES (
            v_res.client_id, 'break_started',
            '☕ El grupo está en su descanso',
            'Descanso de 15 min — ' || v_res.group_name || ' vuelve a tocar a las ' || v_vuelve || '.',
            jsonb_build_object('reservation_id', v_res.id,
                               'break_index', v_b.break_index, 'screen', 'EventTimer')
          );
        END IF;
        IF v_res.owner_id IS NOT NULL THEN
          INSERT INTO public.notifications (user_id, type, title, body, data)
          VALUES (
            v_res.owner_id, 'break_started',
            '☕ Ya es tu descanso',
            '15 minutos para recargar. Vuelven a las ' || v_vuelve || '.',
            jsonb_build_object('reservation_id', v_res.id,
                               'break_index', v_b.break_index, 'screen', 'EventTimer')
          );
        END IF;
        FOR v_member IN
          SELECT DISTINCT ji.invited_user_id AS user_id
          FROM   public.job_invitations ji
          WHERE  ji.status           = 'accepted'
            AND  ji.invited_user_id != v_res.owner_id
            AND (
                  (ji.group_id = v_res.group_id
                   AND ji.event_id IS NULL AND ji.event_request_id IS NULL)
               OR (v_res.event_id IS NOT NULL AND ji.event_id = v_res.event_id)
               OR (v_res.event_request_id IS NOT NULL
                   AND ji.event_request_id = v_res.event_request_id)
            )
        LOOP
          INSERT INTO public.notifications (user_id, type, title, body, data)
          VALUES (
            v_member.user_id, 'break_started',
            '☕ Ya es tu descanso',
            '15 minutos para recargar. Vuelven a las ' || v_vuelve || '.',
            jsonb_build_object('reservation_id', v_res.id,
                               'break_index', v_b.break_index, 'screen', 'EventTimer')
          );
        END LOOP;
      END IF;

      IF v_b.break_end > NOW()
         AND v_b.break_end <= NOW() + INTERVAL '3 minutes'
         AND NOT EXISTS (
           SELECT 1 FROM public.notifications
           WHERE type = 'break_ending_soon'
             AND data->>'reservation_id' = v_res.id::text
             AND data->>'break_index'    = v_b.break_index::text
         )
      THEN
        IF v_res.client_id IS NOT NULL THEN
          INSERT INTO public.notifications (user_id, type, title, body, data)
          VALUES (
            v_res.client_id, 'break_ending_soon',
            '🎵 El descanso está por terminar',
            'En 3 minutos el grupo vuelve a tocar. ¡Prepárate!',
            jsonb_build_object('reservation_id', v_res.id,
                               'break_index', v_b.break_index, 'screen', 'EventTimer')
          );
        END IF;
        IF v_res.owner_id IS NOT NULL THEN
          INSERT INTO public.notifications (user_id, type, title, body, data)
          VALUES (
            v_res.owner_id, 'break_ending_soon',
            '⏰ Descanso por terminar',
            'En 3 minutos vuelven a tocar. ¡Afinen y prepárense!',
            jsonb_build_object('reservation_id', v_res.id,
                               'break_index', v_b.break_index, 'screen', 'EventTimer')
          );
        END IF;
        FOR v_member IN
          SELECT DISTINCT ji.invited_user_id AS user_id
          FROM   public.job_invitations ji
          WHERE  ji.status           = 'accepted'
            AND  ji.invited_user_id != v_res.owner_id
            AND (
                  (ji.group_id = v_res.group_id
                   AND ji.event_id IS NULL AND ji.event_request_id IS NULL)
               OR (v_res.event_id IS NOT NULL AND ji.event_id = v_res.event_id)
               OR (v_res.event_request_id IS NOT NULL
                   AND ji.event_request_id = v_res.event_request_id)
            )
        LOOP
          INSERT INTO public.notifications (user_id, type, title, body, data)
          VALUES (
            v_member.user_id, 'break_ending_soon',
            '⏰ Descanso por terminar',
            'En 3 minutos vuelven a tocar. ¡Afinen y prepárense!',
            jsonb_build_object('reservation_id', v_res.id,
                               'break_index', v_b.break_index, 'screen', 'EventTimer')
          );
        END LOOP;
      END IF;

      IF v_b.break_end <= NOW()
         AND v_b.break_end >  NOW() - INTERVAL '5 minutes'
         AND NOT EXISTS (
           SELECT 1 FROM public.notifications
           WHERE type = 'break_ended'
             AND data->>'reservation_id' = v_res.id::text
             AND data->>'break_index'    = v_b.break_index::text
         )
      THEN
        v_base_breaks := CASE v_res.break_type
                           WHEN 'A' THEN GREATEST(v_res.hours_count::int - 1, 0)
                           WHEN 'B' THEN 1
                           ELSE 0
                         END;
        IF v_b.is_extra THEN
          v_tanda := 'hora extra ' || (v_b.break_index - v_base_breaks + 1)::text;
        ELSE
          v_tanda := CASE v_b.break_index
                       WHEN 0 THEN 'segunda hora'
                       WHEN 1 THEN 'tercera hora'
                       WHEN 2 THEN 'cuarta hora'
                       WHEN 3 THEN 'quinta hora'
                       ELSE (v_b.break_index + 2)::text || 'ª hora'
                     END;
        END IF;

        IF v_res.client_id IS NOT NULL THEN
          INSERT INTO public.notifications (user_id, type, title, body, data)
          VALUES (
            v_res.client_id, 'break_ended',
            CASE WHEN v_b.is_extra
              THEN '🔥 ¡La ' || v_tanda || ' inició!'
              ELSE '🎵 ¡La ' || v_tanda || ' inició!' END,
            CASE WHEN v_b.is_extra
              THEN v_res.group_name || ' sigue tocando para ti. ¡Disfrútala!'
              ELSE v_res.group_name || ' está de vuelta en el escenario. ¡A disfrutar!' END,
            jsonb_build_object('reservation_id', v_res.id,
                               'break_index', v_b.break_index, 'screen', 'EventTimer')
          );
        END IF;
        IF v_res.owner_id IS NOT NULL THEN
          INSERT INTO public.notifications (user_id, type, title, body, data)
          VALUES (
            v_res.owner_id, 'break_ended',
            CASE WHEN v_b.is_extra
              THEN '🔥 ¡La ' || v_tanda || ' inició!'
              ELSE '🎸 ¡La ' || v_tanda || ' inició!' END,
            CASE WHEN v_b.is_extra
              THEN '¡El cliente quiere más música! A darlo todo.'
              ELSE 'De vuelta al escenario. ¡A darle!' END,
            jsonb_build_object('reservation_id', v_res.id,
                               'break_index', v_b.break_index, 'screen', 'EventTimer')
          );
        END IF;
        FOR v_member IN
          SELECT DISTINCT ji.invited_user_id AS user_id
          FROM   public.job_invitations ji
          WHERE  ji.status           = 'accepted'
            AND  ji.invited_user_id != v_res.owner_id
            AND (
                  (ji.group_id = v_res.group_id
                   AND ji.event_id IS NULL AND ji.event_request_id IS NULL)
               OR (v_res.event_id IS NOT NULL AND ji.event_id = v_res.event_id)
               OR (v_res.event_request_id IS NOT NULL
                   AND ji.event_request_id = v_res.event_request_id)
            )
        LOOP
          INSERT INTO public.notifications (user_id, type, title, body, data)
          VALUES (
            v_member.user_id, 'break_ended',
            CASE WHEN v_b.is_extra
              THEN '🔥 ¡La ' || v_tanda || ' inició!'
              ELSE '🎸 ¡La ' || v_tanda || ' inició!' END,
            CASE WHEN v_b.is_extra
              THEN '¡El cliente quiere más música! A darlo todo.'
              ELSE 'De vuelta al escenario. ¡A darle!' END,
            jsonb_build_object('reservation_id', v_res.id,
                               'break_index', v_b.break_index, 'screen', 'EventTimer')
          );
        END LOOP;
      END IF;

    END LOOP;
  END LOOP;
END;
$function$;

COMMIT;

SELECT '600_fix_notify_break_transitions — REVERTIDO (versión anterior, ROTA, restaurada)' AS status;
