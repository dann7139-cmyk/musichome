-- ============================================================
-- sql/449_auto_finalize_stuck_events.sql
-- RED DE SEGURIDAD G3: finaliza eventos que quedaron 'in_progress' porque
-- el grupo cerró la app y nunca se disparó finishEvent() (client-side).
-- Espejo de auto_start_due_events (344), pero del lado del CIERRE.
--
-- QUÉ HACE (solo ciclo de vida):
--   · status='completed', event_ended_at=NOW(), actual_duration_minutes
--   · event_finalized → cliente + owner + integrantes/talentos (dedupe)
--
-- QUÉ NO HACE (a propósito):
--   · NO libera pago, NO toca group_wallets, NO toca payout_status.
--   · NO toca el candado GPS (release_half_on_arrival) ni el 50%.
--   El dinero lo sigue manejando release_all_eligible_payments (237) en su
--   corte normal de 15 h, que respeta 'blocked'/disputa. Dejar el dinero en
--   UN solo cron evita carreras y pagos automáticos de eventos dudosos.
--
-- CUÁNDO finaliza: solo si (inicio + duración contratada + extras + holgura
-- de descansos + 2 h de gracia) ya pasó → nunca corta un evento en curso.
--
-- México = UTC-6 fijo. Advisory lock: una corrida a la vez.
-- ============================================================

BEGIN;

CREATE OR REPLACE FUNCTION public.auto_finalize_stuck_events()
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_res          RECORD;
  v_member       RECORD;
  v_extras       NUMERIC;
  v_expected_end TIMESTAMPTZ;
  v_dur          INT;
  v_finalized    INT := 0;
BEGIN
  -- Solo una corrida simultánea
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
      AND r.event_started_at > NOW() - INTERVAL '7 days'   -- pre-filtro barato
  LOOP

    -- Horas extra aceptadas/pagadas (mismo criterio que el timer)
    SELECT COALESCE(SUM(hours_added), 0) INTO v_extras
    FROM   public.extra_hours
    WHERE  reservation_id = v_res.id
      AND  status IN ('accepted', 'paid');

    -- Fin esperado (sobreestimado a propósito para NUNCA cortar en vivo):
    --   inicio + (horas contratadas + extras) + 1 h holgura descansos + 2 h gracia
    v_expected_end := v_res.event_started_at
      + ((v_res.hours_count + v_extras) || ' hours')::interval
      + INTERVAL '1 hour'
      + INTERVAL '2 hours';

    IF v_expected_end >= NOW() THEN
      CONTINUE;   -- todavía podría estar en curso → no tocar
    END IF;

    -- ── Cerrar ciclo de vida (NO toca payout/wallet/GPS) ──────────────
    v_dur := GREATEST(0, EXTRACT(EPOCH FROM (NOW() - v_res.event_started_at))::INT / 60);
    UPDATE public.reservations
    SET status                  = 'completed',
        event_ended_at          = NOW(),
        actual_duration_minutes = COALESCE(actual_duration_minutes, v_dur),
        updated_at              = NOW()
    WHERE id = v_res.id;

    -- ── event_finalized → cliente ────────────────────────────────────
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

    -- ── event_finalized → owner del grupo ────────────────────────────
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

    -- ── event_finalized → integrantes + talentos de ESTE evento (regla 421) ──
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
$$;

GRANT EXECUTE ON FUNCTION public.auto_finalize_stuck_events() TO service_role;

-- ── Cron: cada 15 min ─────────────────────────────────────────────────────────
DO $$ BEGIN
  PERFORM cron.unschedule('auto-finalize-stuck-events');
EXCEPTION WHEN OTHERS THEN NULL;
END; $$;

SELECT cron.schedule(
  'auto-finalize-stuck-events',
  '*/15 * * * *',
  $$SELECT public.auto_finalize_stuck_events();$$
);

COMMIT;

-- ── VERIFICACIONES (correr por separado después del COMMIT) ─────────────────────
-- V1: la función NO toca dinero/GPS (solo ciclo de vida)
SELECT
  prosecdef                                       AS is_security_definer,
  prosrc LIKE '%event_finalized%'                 AS manda_finalized,        -- true
  prosrc NOT LIKE '%release_half_on_arrival%'     AS no_toca_gps,            -- true
  prosrc NOT LIKE '%group_wallets%'               AS no_toca_wallet,         -- true
  prosrc NOT LIKE '%release_group_earnings%'      AS no_libera_pago,         -- true
  prosrc NOT LIKE '%payout_status%'               AS no_toca_payout          -- true
FROM pg_proc
WHERE proname = 'auto_finalize_stuck_events';
-- Esperado: true | true | true | true | true | true

-- V2: cron registrado cada 15 min
SELECT jobname, schedule, active FROM cron.job WHERE jobname = 'auto-finalize-stuck-events';
-- Esperado: */15 * * * * | t

-- V3 (read-only): candidatos actuales que se cerrarían (revisa que ninguno siga en vivo)
SELECT r.folio, r.event_started_at, r.hours_count,
       (r.event_started_at + ((COALESCE(r.hours_count,3)) || ' hours')::interval
        + INTERVAL '3 hours') AS se_cerraria_tras
FROM reservations r
WHERE r.status = 'in_progress' AND r.event_started_at IS NOT NULL
  AND r.event_ended_at IS NULL
  AND r.event_started_at > NOW() - INTERVAL '7 days';

SELECT '449_auto_finalize_stuck_events.sql ejecutado ✅' AS status;
