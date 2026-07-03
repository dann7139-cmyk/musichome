-- ============================================================
-- sql/419_break_notifications_server.sql
-- Notificaciones de descanso SERVER-SIDE (reemplazan el effect
-- client-side de EventTimerScreen:1101-1125, eliminado en este lote)
--
--   · break_starting_soon → ~5 min antes del descanso → SOLO grupo
--     (owner + integrantes aceptados)
--   · break_ending_soon   → ~3 min antes de volver    → grupo + cliente
--
-- BLOQUE 1: constraint +2 types (patrón leer-prod, lección del 418)
-- BLOQUE 2: event_break_boundaries() — ESPEJO SQL de
--           generateBreakSchedule (src/utils/calculations.ts:280).
--           Si ese TS cambia, esta función DEBE cambiar igual.
-- BLOQUE 3: TEST DE PARIDAD — falla con EXCEPTION si el espejo
--           diverge del frontend (casos A, B, D y con extras).
-- BLOQUE 4: notify_break_transitions() + cron cada minuto.
--
-- REQUISITO: correr sql/418 ANTES (esta lista lo incluye; si el
-- pre-check no coincide, detente y repórtalo).
-- ============================================================

-- ── PRE-CHECK: lista vigente ANTES del cambio ─────────────────────────────────
-- Si prod tiene algún type que NO esté en el ALTER de abajo, DETENTE.
SELECT pg_get_constraintdef(c.oid) AS constraint_actual
FROM   pg_constraint c
WHERE  c.conname  = 'notifications_type_check'
  AND  c.conrelid = 'public.notifications'::regclass;


-- ══════════════════════════════════════════════════════════════
-- BLOQUE 1 — Constraint: +break_starting_soon, +break_ending_soon
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
      -- Descansos server-side (419) ← NUEVOS
      'break_starting_soon', 'break_ending_soon',
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

  RAISE NOTICE '[419] break_starting_soon + break_ending_soon agregados ✅';
END;
$$;

COMMIT;


-- ══════════════════════════════════════════════════════════════
-- BLOQUE 2 — event_break_boundaries()
-- ESPEJO de generateBreakSchedule (calculations.ts:280-338):
--   A: música 45 + descanso 15 por hora, la última hora sin descanso
--      → breaks en [45+j·60, 60+j·60], j=0..hours-2 · base = 60h−15
--   B: un descanso de 15 a la mitad → [(60h−15)/2, +15] · base = 60h
--   D: sin descansos · base = 60h
--   Extras: por cada una, break en [base + i·75, +15] (antes de su hora)
-- ══════════════════════════════════════════════════════════════
-- FIX 42883: reservations.hours_count es NUMERIC — la firma acepta NUMERIC
-- para que la resolución de tipos funcione desde SQL y desde el cron.
-- Se dropea la firma INT anterior para no dejar una sobrecarga ambigua.
DROP FUNCTION IF EXISTS public.event_break_boundaries(TIMESTAMPTZ, INT, TEXT, INT);

CREATE OR REPLACE FUNCTION public.event_break_boundaries(
  p_started_at TIMESTAMPTZ,
  p_hours      NUMERIC,
  p_break_type TEXT,
  p_extras     INT DEFAULT 0
)
RETURNS TABLE (
  break_index INT,
  break_start TIMESTAMPTZ,
  break_end   TIMESTAMPTZ,
  is_extra    BOOLEAN
)
LANGUAGE plpgsql IMMUTABLE
AS $$
DECLARE
  v_idx      INT := 0;
  v_h        INT := FLOOR(COALESCE(p_hours, 3))::INT;  -- horas contratadas (enteras)
  v_base_min NUMERIC;   -- minutos donde termina la parte base contratada
  v_half     NUMERIC;
  i          INT;
BEGIN
  IF p_break_type = 'A' THEN
    FOR i IN 0..(v_h - 2) LOOP
      break_index := v_idx;
      is_extra    := FALSE;
      break_start := p_started_at + ((45 + i * 60) || ' minutes')::interval;
      break_end   := p_started_at + ((60 + i * 60) || ' minutes')::interval;
      RETURN NEXT;
      v_idx := v_idx + 1;
    END LOOP;
    v_base_min := v_h * 60 - 15;

  ELSIF p_break_type = 'B' THEN
    v_half      := (v_h * 60 - 15) / 2.0;
    break_index := v_idx;
    is_extra    := FALSE;
    break_start := p_started_at + (v_half        || ' minutes')::interval;
    break_end   := p_started_at + ((v_half + 15) || ' minutes')::interval;
    RETURN NEXT;
    v_idx      := v_idx + 1;
    v_base_min := v_h * 60;

  ELSE  -- 'D' o desconocido: sin descansos base
    v_base_min := v_h * 60;
  END IF;

  -- Horas extra: 15 min de descanso antes de cada hora extra
  FOR i IN 0..(p_extras - 1) LOOP
    break_index := v_idx;
    is_extra    := TRUE;
    break_start := p_started_at + ((v_base_min + i * 75)      || ' minutes')::interval;
    break_end   := p_started_at + ((v_base_min + i * 75 + 15) || ' minutes')::interval;
    RETURN NEXT;
    v_idx := v_idx + 1;
  END LOOP;
END;
$$;


-- ══════════════════════════════════════════════════════════════
-- BLOQUE 3 — TEST DE PARIDAD contra generateBreakSchedule
-- Valores esperados calculados a mano desde calculations.ts.
-- Si algo no cuadra → EXCEPTION y el archivo NO se da por bueno.
-- ══════════════════════════════════════════════════════════════
DO $$
DECLARE
  t0    TIMESTAMPTZ := '2026-01-01T20:00:00Z';
  v_cnt INT;
BEGIN
  -- Caso A · 3h · 0 extras → 2 breaks: [+45,+60] y [+105,+120]
  SELECT COUNT(*) INTO v_cnt FROM event_break_boundaries(t0, 3, 'A', 0);
  IF v_cnt <> 2 THEN RAISE EXCEPTION 'PARIDAD A3h: esperaba 2 breaks, hay %', v_cnt; END IF;
  PERFORM 1 FROM event_break_boundaries(t0, 3, 'A', 0)
   WHERE break_index = 0 AND break_start = t0 + INTERVAL '45 min' AND break_end = t0 + INTERVAL '60 min';
  IF NOT FOUND THEN RAISE EXCEPTION 'PARIDAD A3h break#0: esperado [+45,+60]'; END IF;
  PERFORM 1 FROM event_break_boundaries(t0, 3, 'A', 0)
   WHERE break_index = 1 AND break_start = t0 + INTERVAL '105 min' AND break_end = t0 + INTERVAL '120 min';
  IF NOT FOUND THEN RAISE EXCEPTION 'PARIDAD A3h break#1: esperado [+105,+120]'; END IF;

  -- Caso B · 3h · 0 extras → 1 break a la mitad: [+82.5,+97.5]
  SELECT COUNT(*) INTO v_cnt FROM event_break_boundaries(t0, 3, 'B', 0);
  IF v_cnt <> 1 THEN RAISE EXCEPTION 'PARIDAD B3h: esperaba 1 break, hay %', v_cnt; END IF;
  PERFORM 1 FROM event_break_boundaries(t0, 3, 'B', 0)
   WHERE break_start = t0 + INTERVAL '82.5 min' AND break_end = t0 + INTERVAL '97.5 min';
  IF NOT FOUND THEN RAISE EXCEPTION 'PARIDAD B3h: esperado [+82.5,+97.5]'; END IF;

  -- Caso D · 3h · 0 extras → 0 breaks
  SELECT COUNT(*) INTO v_cnt FROM event_break_boundaries(t0, 3, 'D', 0);
  IF v_cnt <> 0 THEN RAISE EXCEPTION 'PARIDAD D3h: esperaba 0 breaks, hay %', v_cnt; END IF;

  -- Caso B · 3h · 2 extras → 3 breaks: [+82.5,+97.5], [+180,+195], [+255,+270]
  SELECT COUNT(*) INTO v_cnt FROM event_break_boundaries(t0, 3, 'B', 2);
  IF v_cnt <> 3 THEN RAISE EXCEPTION 'PARIDAD B3h+2ex: esperaba 3 breaks, hay %', v_cnt; END IF;
  PERFORM 1 FROM event_break_boundaries(t0, 3, 'B', 2)
   WHERE is_extra AND break_start = t0 + INTERVAL '180 min' AND break_end = t0 + INTERVAL '195 min';
  IF NOT FOUND THEN RAISE EXCEPTION 'PARIDAD B3h+2ex extra#0: esperado [+180,+195]'; END IF;
  PERFORM 1 FROM event_break_boundaries(t0, 3, 'B', 2)
   WHERE is_extra AND break_start = t0 + INTERVAL '255 min' AND break_end = t0 + INTERVAL '270 min';
  IF NOT FOUND THEN RAISE EXCEPTION 'PARIDAD B3h+2ex extra#1: esperado [+255,+270]'; END IF;

  -- Caso D · 3h · 1 extra → 1 break (¡D con extras SÍ tiene descanso!): [+180,+195]
  SELECT COUNT(*) INTO v_cnt FROM event_break_boundaries(t0, 3, 'D', 1);
  IF v_cnt <> 1 THEN RAISE EXCEPTION 'PARIDAD D3h+1ex: esperaba 1 break, hay %', v_cnt; END IF;
  PERFORM 1 FROM event_break_boundaries(t0, 3, 'D', 1)
   WHERE is_extra AND break_start = t0 + INTERVAL '180 min' AND break_end = t0 + INTERVAL '195 min';
  IF NOT FOUND THEN RAISE EXCEPTION 'PARIDAD D3h+1ex: esperado [+180,+195]'; END IF;

  -- Caso A · 2h · 1 extra → 2 breaks: [+45,+60] base y [+105,+120] extra
  --   (base A termina en 2·60−15 = 105 min)
  SELECT COUNT(*) INTO v_cnt FROM event_break_boundaries(t0, 2, 'A', 1);
  IF v_cnt <> 2 THEN RAISE EXCEPTION 'PARIDAD A2h+1ex: esperaba 2 breaks, hay %', v_cnt; END IF;
  PERFORM 1 FROM event_break_boundaries(t0, 2, 'A', 1)
   WHERE is_extra AND break_start = t0 + INTERVAL '105 min' AND break_end = t0 + INTERVAL '120 min';
  IF NOT FOUND THEN RAISE EXCEPTION 'PARIDAD A2h+1ex extra#0: esperado [+105,+120]'; END IF;

  -- Caso A · 1h · 0 extras → 0 breaks (una sola hora no lleva descanso)
  SELECT COUNT(*) INTO v_cnt FROM event_break_boundaries(t0, 1, 'A', 0);
  IF v_cnt <> 0 THEN RAISE EXCEPTION 'PARIDAD A1h: esperaba 0 breaks, hay %', v_cnt; END IF;

  RAISE NOTICE '[419] ✅ TEST DE PARIDAD OK — espejo consistente con generateBreakSchedule';
END;
$$;


-- ══════════════════════════════════════════════════════════════
-- BLOQUE 4 — notify_break_transitions() + cron cada minuto
-- ══════════════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION public.notify_break_transitions()
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_res    RECORD;
  v_b      RECORD;
  v_member RECORD;
  v_extras INT;
BEGIN
  -- Advisory lock: solo 1 corrida a la vez
  IF NOT pg_try_advisory_xact_lock(9182736450) THEN
    RETURN;
  END IF;

  -- SOLO eventos en curso (nunca cerrados, cancelados ni sin iniciar)
  FOR v_res IN
    SELECT r.id, r.client_id, r.group_id, r.event_started_at,
           COALESCE(r.break_type, 'B') AS break_type,
           COALESCE(r.hours_count, 3)  AS hours_count,
           g.owner_id
    FROM  public.reservations r
    JOIN  public.groups       g ON g.id = r.group_id
    WHERE r.status           = 'in_progress'
      AND r.event_started_at IS NOT NULL
      AND r.event_ended_at   IS NULL
      AND r.event_started_at > NOW() - INTERVAL '24 hours'
  LOOP

    -- Extras aceptadas/pagadas (mismo criterio que el frontend)
    SELECT COALESCE(SUM(hours_added), 0) INTO v_extras
    FROM   public.extra_hours
    WHERE  reservation_id = v_res.id
      AND  status IN ('accepted', 'paid');

    FOR v_b IN
      SELECT * FROM public.event_break_boundaries(
        v_res.event_started_at, v_res.hours_count, v_res.break_type, v_extras)
    LOOP

      -- ── break_starting_soon: ~5 min antes → SOLO grupo ──────────
      IF v_b.break_start > NOW()
         AND v_b.break_start <= NOW() + INTERVAL '5 minutes'
         AND NOT EXISTS (
           SELECT 1 FROM public.notifications
           WHERE type = 'break_starting_soon'
             AND data->>'reservation_id' = v_res.id::text
             AND data->>'break_index'    = v_b.break_index::text
         )
      THEN
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
          WHERE  ji.group_id         = v_res.group_id
            AND  ji.status           = 'accepted'
            AND  ji.invited_user_id != v_res.owner_id
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
        -- Cliente (conserva el aviso que ya recibía)
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
        -- Owner + integrantes
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
          WHERE  ji.group_id         = v_res.group_id
            AND  ji.status           = 'accepted'
            AND  ji.invited_user_id != v_res.owner_id
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

    END LOOP;
  END LOOP;
END;
$$;

GRANT EXECUTE ON FUNCTION public.notify_break_transitions() TO service_role;

-- ── Cron: cada minuto ─────────────────────────────────────────────────────────
DO $$ BEGIN
  PERFORM cron.unschedule('notify-break-transitions');
EXCEPTION WHEN OTHERS THEN NULL;
END; $$;

SELECT cron.schedule(
  'notify-break-transitions',
  '* * * * *',
  $$SELECT public.notify_break_transitions();$$
);

-- ── Verificaciones finales ────────────────────────────────────────────────────
-- V1: types en constraint
SELECT
  pg_get_constraintdef(c.oid) LIKE '%break_starting_soon%' AS starting_ok,
  pg_get_constraintdef(c.oid) LIKE '%break_ending_soon%'   AS ending_ok,
  pg_get_constraintdef(c.oid) LIKE '%''quote_expired''%'   AS quote_expired_intacto
FROM   pg_constraint c
WHERE  c.conname  = 'notifications_type_check'
  AND  c.conrelid = 'public.notifications'::regclass;
-- Esperado: true | true | true

-- V2: cron registrado
SELECT jobname, schedule FROM cron.job WHERE jobname = 'notify-break-transitions';
-- Esperado: * * * * *

SELECT '419_break_notifications_server.sql ejecutado ✅' AS status;
