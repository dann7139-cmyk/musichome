-- ============================================================
-- sql/421_break_ended_notification.sql
-- Notificación al TERMINAR el descanso — "volvieron a tocar"
-- (inicio de la siguiente tanda) → cliente + grupo
--
-- Cuarta ventana del cron notify-break-transitions. Ciclo completo
-- (aplica a CADA descanso del evento, dedupe por break_index):
--   break_starting_soon (5 min antes)          → cliente + grupo (v2)
--   break_started       (al iniciar descanso)  → cliente + grupo
--   break_ending_soon   (3 min antes de volver) → cliente + grupo
--   break_ended         (al volver a tocar)    → cliente + grupo  ← NUEVA
--
-- Mensajes numerados por tanda: "¡La segunda/tercera/cuarta hora
-- inició!" para bloques base, y "🔥 ¡La hora extra N inició!" para
-- extras. La 1ª hora la cubre la notificación de inicio de evento
-- ("🎵 ¡Tu evento ha iniciado!") que ya existe.
--
-- NOTA: al cubrir extras aquí, el effect client-side de "hora extra
-- iniciando" (EventTimerScreen L1128) SE ELIMINA en el mismo lote
-- para no duplicar.
--
-- REQUISITO: sql/419 (hotfix numeric) y sql/420 ya corridos.
-- ============================================================

-- ── PRE-CHECK: lista vigente ANTES del cambio ─────────────────────────────────
SELECT pg_get_constraintdef(c.oid) AS constraint_actual
FROM   pg_constraint c
WHERE  c.conname  = 'notifications_type_check'
  AND  c.conrelid = 'public.notifications'::regclass;


-- ══════════════════════════════════════════════════════════════
-- BLOQUE 1 — Constraint: +break_ended
-- ══════════════════════════════════════════════════════════════
BEGIN;

DO $$
BEGIN
  ALTER TABLE public.notifications
    DROP CONSTRAINT IF EXISTS notifications_type_check;

  ALTER TABLE public.notifications
    ADD CONSTRAINT notifications_type_check CHECK (type IN (
      -- Legacy / genéricos
      'reservation', 'payment', 'review', 'verification', 'system',
      'financial', 'admin_alert', 'admin', 'general',
      -- Reservas (booking flow)
      'booking', 'booking_received', 'booking_accepted', 'booking_confirmed',
      'booking_rejected', 'booking_auto_cancelled', 'booking_expired_no_payment',
      'booking_cancelled',
      -- Pagos y wallet
      'deposit_received', 'payment_released', 'payment_received',
      'payment_mismatch', 'payout', 'wallet',
      -- Recordatorios de evento
      'event_reminder_24h', 'event_upcoming_24h',
      'event_reminder_morning', 'event_reminder_1h',
      'event_reminder_3h',    'event_reminder_2h',
      'event_reminder_15m',
      -- Ciclo de vida del evento
      'event_completed', 'event_started', 'overtime_requested',
      'event_auto_started', 'event_no_show_alert', 'event_finalized',
      -- Descansos server-side (419 + 420 + 421)
      'break_starting_soon', 'break_ending_soon',
      'break_started',
      'break_ended',                   -- ← NUEVO (421)
      -- Disputas
      'dispute_opened', 'dispute_received', 'dispute',
      -- Bolsa de trabajo
      'job_invitation',
      -- Cotizaciones
      'new_quote_request', 'quote_received',
      'quote_accepted',    'quote_cancelled', 'quote_sent_to_client',
      'quote_expired',
      -- Chat
      'chat',
      -- Marketing / visibilidad (grupos)
      'ad_space_available', 'high_demand', 'no_ads_in_city', 'first_ad_reminder',
      -- Anuncios (publicados por grupo)
      'ad_payment_confirmed', 'ad_approved', 'ad_rejected',
      'ad_expiring_soon',     'ad_expired',
      -- Re-engagement (clientes)
      'new_city_groups', 'group_nearby',
      -- Competencia de bids
      'bid_displaced', 'bid_expiring_soon', 'bid_expiry_reminder',
      -- Zona / demanda express
      'zone_demand', 'express_dispatch',
      -- Admin / KYC / anti-fraude
      'fraud_alert', 'referral_reward',
      -- Proximidad al evento (349)
      'request_expired_proximity', 'quote_expired_proximity',
      -- Horas extra (353-401)
      'extra_hour_proposed',
      'extra_hour_approved_by_client',
      'extra_hour_payment_confirmed',
      'extra_hour_rejected_by_client',
      'extra_hour_requested',
      'extra_hour_rejected',
      'extra_hour_payment_required',
      'extra_hour_expired',
      'extra_hour_payment_expired',
      -- Calificaciones (408)
      'review_received',
      -- Horas extra offer (EventTimer)
      'extra_hours_offer'
    )) NOT VALID;

  RAISE NOTICE '[421] break_ended agregado ✅';
END;
$$;

COMMIT;


-- ══════════════════════════════════════════════════════════════
-- BLOQUE 2 — notify_break_transitions() v3: CUATRO ventanas
-- ══════════════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION public.notify_break_transitions()
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public
AS $$
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

      -- ── break_starting_soon: ~5 min antes → grupo + cliente ──────────
      IF v_b.break_start > NOW()
         AND v_b.break_start <= NOW() + INTERVAL '5 minutes'
         AND NOT EXISTS (
           SELECT 1 FROM public.notifications
           WHERE type = 'break_starting_soon'
             AND data->>'reservation_id' = v_res.id::text
             AND data->>'break_index'    = v_b.break_index::text
         )
      THEN
        -- Cliente [421v2]: aviso previo del descanso
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
                  -- Integrantes permanentes del grupo
                  (ji.group_id = v_res.group_id
                   AND ji.event_id IS NULL AND ji.event_request_id IS NULL)
                  -- Talentos invitados a ESTE evento
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

      -- ── break_started: primer minuto del descanso → grupo + cliente ──
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
                  -- Integrantes permanentes del grupo
                  (ji.group_id = v_res.group_id
                   AND ji.event_id IS NULL AND ji.event_request_id IS NULL)
                  -- Talentos invitados a ESTE evento
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

      -- ── break_ending_soon: ~3 min antes de volver → grupo + cliente ──
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
                  -- Integrantes permanentes del grupo
                  (ji.group_id = v_res.group_id
                   AND ji.event_id IS NULL AND ji.event_request_id IS NULL)
                  -- Talentos invitados a ESTE evento
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

      -- ── break_ended [421]: inició la siguiente hora/tanda → grupo + cliente ──
      --    Numerada: base = "segunda/tercera/... hora"; extras = "hora extra N".
      IF v_b.break_end <= NOW()
         AND v_b.break_end >  NOW() - INTERVAL '5 minutes'
         AND NOT EXISTS (
           SELECT 1 FROM public.notifications
           WHERE type = 'break_ended'
             AND data->>'reservation_id' = v_res.id::text
             AND data->>'break_index'    = v_b.break_index::text
         )
      THEN
        -- Descansos base según tipo (para numerar las extras)
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
                  -- Integrantes permanentes del grupo
                  (ji.group_id = v_res.group_id
                   AND ji.event_id IS NULL AND ji.event_request_id IS NULL)
                  -- Talentos invitados a ESTE evento
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
$$;

GRANT EXECUTE ON FUNCTION public.notify_break_transitions() TO service_role;

-- (El cron 'notify-break-transitions' ya existe — no se toca.)

-- ── Verificaciones ────────────────────────────────────────────────────────────
SELECT pg_get_constraintdef(c.oid) LIKE '%break_ended%' AS break_ended_ok
FROM   pg_constraint c
WHERE  c.conname  = 'notifications_type_check'
  AND  c.conrelid = 'public.notifications'::regclass;
-- Esperado: true

SELECT
  routine_definition LIKE '%break_starting_soon%' AS v1_5min_antes,
  routine_definition LIKE '%break_started%'       AS v2_inicio,
  routine_definition LIKE '%break_ending_soon%'   AS v3_3min_antes,
  routine_definition LIKE '%break_ended%'         AS v4_volvieron
FROM information_schema.routines
WHERE routine_schema = 'public' AND routine_name = 'notify_break_transitions';
-- Esperado: true | true | true | true

SELECT '421_break_ended_notification.sql ejecutado ✅' AS status;
