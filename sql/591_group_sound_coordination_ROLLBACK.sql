-- Rollback de sql/591 — quita el trigger y las 2 funciones nuevas de
-- coordinación, y restaura admin_alerts()/admin_get_events_needing_review()
-- exactamente como estaban antes (hashes confirmados
-- 'ff6f4dde8e85624205e3fd082fec22df' / '2c055fffebc036a778321e10fa8659f0',
-- 2026-09-01).

BEGIN;

-- Restaura notifications.type CHECK exactamente como estaba (sin
-- 'sound_coordination_needed').
ALTER TABLE public.notifications DROP CONSTRAINT IF EXISTS notifications_type_check;
ALTER TABLE public.notifications ADD CONSTRAINT notifications_type_check
  CHECK ((type = ANY (ARRAY[
    'reservation'::text, 'payment'::text, 'review'::text, 'verification'::text, 'system'::text,
    'financial'::text, 'admin_alert'::text, 'admin'::text, 'general'::text, 'booking'::text,
    'booking_received'::text, 'booking_accepted'::text, 'booking_confirmed'::text, 'booking_rejected'::text,
    'booking_auto_cancelled'::text, 'booking_expired_no_payment'::text, 'booking_cancelled'::text,
    'deposit_received'::text, 'payment_released'::text, 'payment_received'::text, 'payment_mismatch'::text,
    'payout'::text, 'wallet'::text, 'event_reminder_24h'::text, 'event_upcoming_24h'::text,
    'event_reminder_morning'::text, 'event_reminder_1h'::text, 'event_reminder_3h'::text,
    'event_reminder_2h'::text, 'event_reminder_15m'::text, 'event_completed'::text, 'event_started'::text,
    'overtime_requested'::text, 'event_auto_started'::text, 'event_no_show_alert'::text, 'event_finalized'::text,
    'break_starting_soon'::text, 'break_ending_soon'::text, 'break_started'::text, 'break_ended'::text,
    'dispute_opened'::text, 'dispute_received'::text, 'dispute'::text, 'job_invitation'::text,
    'new_quote_request'::text, 'quote_received'::text, 'quote_accepted'::text, 'quote_cancelled'::text,
    'quote_sent_to_client'::text, 'quote_expired'::text, 'chat'::text, 'ad_space_available'::text,
    'high_demand'::text, 'no_ads_in_city'::text, 'first_ad_reminder'::text, 'ad_payment_confirmed'::text,
    'ad_approved'::text, 'ad_rejected'::text, 'ad_expiring_soon'::text, 'ad_expired'::text,
    'new_city_groups'::text, 'group_nearby'::text, 'bid_displaced'::text, 'bid_expiring_soon'::text,
    'bid_expiry_reminder'::text, 'zone_demand'::text, 'express_dispatch'::text, 'fraud_alert'::text,
    'referral_reward'::text, 'request_expired_proximity'::text, 'quote_expired_proximity'::text,
    'extra_hour_proposed'::text, 'extra_hour_approved_by_client'::text, 'extra_hour_payment_confirmed'::text,
    'extra_hour_rejected_by_client'::text, 'extra_hour_requested'::text, 'extra_hour_rejected'::text,
    'extra_hour_payment_required'::text, 'extra_hour_expired'::text, 'extra_hour_payment_expired'::text,
    'review_received'::text, 'extra_hours_offer'::text
  ]))) NOT VALID;

DROP TRIGGER IF EXISTS trg_notify_sound_coordination ON public.quotes;
DROP FUNCTION IF EXISTS public.notify_sound_coordination();
DROP FUNCTION IF EXISTS public.group_get_sound_coordination(UUID);
DROP FUNCTION IF EXISTS public.get_sound_coordination_partner(UUID, UUID);

CREATE OR REPLACE FUNCTION public.admin_alerts()
 RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public' AS $function$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM profiles WHERE id = auth.uid() AND role = 'admin') THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_admin');
  END IF;
  RETURN jsonb_build_object(
    'ok', true,
    'retiros_pendientes', (SELECT COUNT(*) FROM withdrawals WHERE status = 'pending'),
    'fees_no_capturados', (SELECT COUNT(*) FROM reservations WHERE payment_status IN ('paid','fully_paid','deposit_paid') AND stripe_fee_amount IS NULL),
    'sin_pais', ((SELECT COUNT(*) FROM groups WHERE country IS NULL) + (SELECT COUNT(*) FROM profiles WHERE role = 'talent' AND country IS NULL)),
    'grupos_suspendidos', (SELECT COUNT(*) FROM groups WHERE suspended_at IS NOT NULL),
    'disputas_abiertas', (SELECT COUNT(*) FROM disputes WHERE status IN ('open', 'under_review')),
    'reembolsos_pendientes', (SELECT COUNT(*) FROM manual_refunds WHERE status = 'pending'),
    'eventos_sin_cerrar', (SELECT COUNT(*) FROM reservations WHERE status = 'in_progress' AND event_date < (NOW() AT TIME ZONE 'America/Mexico_City')::date),
    'pagos_retenidos_viejos', (SELECT COUNT(*) FROM reservations WHERE payout_status = 'held' AND payment_status IN ('paid','fully_paid','deposit_paid') AND status = 'completed' AND held_at IS NOT NULL AND held_at < NOW() - INTERVAL '3 days'),
    'eventos_multi_grupo_revisar', (
      SELECT COUNT(*) FROM (
        SELECT e.id FROM public.events e
        WHERE e.event_date >= (NOW() AT TIME ZONE 'America/Mexico_City')::date
          AND (SELECT COUNT(DISTINCT gid) FROM (
                SELECT r.group_id AS gid FROM public.reservations r WHERE r.event_id = e.id AND r.status = ANY (public.estados_que_ocupan())
                UNION
                SELECT q.group_id AS gid FROM public.quotes q WHERE q.event_id = e.id AND q.status IN ('pending','quoted')
              ) x) >= 2
          AND EXISTS (
            SELECT 1 FROM public.quotes q2 WHERE q2.event_id = e.id AND (
              q2.needs_sound IN ('si_200', 'si') OR
              q2.needs_lighting = 'premium' OR
              q2.needs_stage = 'wedding' OR
              q2.needs_led = 'xl'
            )
          )
      ) reviewable
    )
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.admin_get_events_needing_review()
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $function$
DECLARE v_result jsonb;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM profiles WHERE id = auth.uid() AND role = 'admin') THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_admin');
  END IF;
  SELECT jsonb_build_object('ok', true, 'items', COALESCE(jsonb_agg(x.item ORDER BY x.event_date ASC), '[]'::jsonb))
  INTO v_result
  FROM (
    SELECT e.event_date, jsonb_build_object(
      'event_id', e.id, 'event_date', e.event_date, 'address', e.address, 'client_name', p.full_name,
      'provider_count', (SELECT COUNT(DISTINCT gid) FROM (
          SELECT r.group_id AS gid FROM public.reservations r WHERE r.event_id = e.id AND r.status = ANY (public.estados_que_ocupan())
          UNION
          SELECT q.group_id AS gid FROM public.quotes q WHERE q.event_id = e.id AND q.status IN ('pending','quoted')
        ) x),
      'max_needs_sound', (SELECT (array_agg(q3.needs_sound ORDER BY
          CASE q3.needs_sound WHEN 'si_200' THEN 4 WHEN 'si_100' THEN 3 WHEN 'si_50' THEN 2 WHEN 'si' THEN 1 ELSE 0 END DESC NULLS LAST
        ) FILTER (WHERE q3.needs_sound IS NOT NULL))[1] FROM public.quotes q3 WHERE q3.event_id = e.id),
      'requested_by', (SELECT COALESCE(jsonb_agg(DISTINCT g4.name) FILTER (
          WHERE q4.needs_sound IN ('si_200', 'si') OR q4.needs_lighting = 'premium' OR q4.needs_stage = 'wedding' OR q4.needs_led = 'xl'
        ), '[]'::jsonb) FROM public.quotes q4 JOIN public.groups g4 ON g4.id = q4.group_id WHERE q4.event_id = e.id)
    ) AS item
    FROM public.events e
    LEFT JOIN public.profiles p ON p.id = e.client_id
    WHERE e.event_date >= (NOW() AT TIME ZONE 'America/Mexico_City')::date
      AND (SELECT COUNT(DISTINCT gid) FROM (
            SELECT r.group_id AS gid FROM public.reservations r WHERE r.event_id = e.id AND r.status = ANY (public.estados_que_ocupan())
            UNION
            SELECT q.group_id AS gid FROM public.quotes q WHERE q.event_id = e.id AND q.status IN ('pending','quoted')
          ) x2) >= 2
      AND EXISTS (
        SELECT 1 FROM public.quotes q5 WHERE q5.event_id = e.id AND (
          q5.needs_sound IN ('si_200', 'si') OR
          q5.needs_lighting = 'premium' OR
          q5.needs_stage = 'wedding' OR
          q5.needs_led = 'xl'
        )
      )
  ) x;
  RETURN v_result;
END;
$function$;

COMMIT;

SELECT '591_group_sound_coordination_ROLLBACK ✅' AS status;
