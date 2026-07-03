-- ============================================================
-- sql/410_notifications_type_check_15m.sql
-- A2 · Agregar 'event_reminder_15m' a notifications_type_check
--
-- Base: la lista COMPLETA vigente de sql/408 (la más reciente que
-- recreó el constraint). Único type nuevo: 'event_reminder_15m'.
--
-- ⚠️ PRE-CHECK — correr ANTES para confirmar que prod coincide con 408
-- (si el resultado incluye algún type que NO esté abajo, PARA y repórtalo):
--   SELECT pg_get_constraintdef(c.oid)
--   FROM   pg_constraint c
--   WHERE  c.conname  = 'notifications_type_check'
--     AND  c.conrelid = 'public.notifications'::regclass;
-- ============================================================

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
      'event_reminder_15m',            -- ← NUEVO (410)
      -- Ciclo de vida del evento
      'event_completed', 'event_started', 'overtime_requested',
      'event_auto_started', 'event_no_show_alert', 'event_finalized',
      -- Disputas
      'dispute_opened', 'dispute_received', 'dispute',
      -- Bolsa de trabajo
      'job_invitation',
      -- Cotizaciones
      'new_quote_request', 'quote_received',
      'quote_accepted',    'quote_cancelled', 'quote_sent_to_client',
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

  RAISE NOTICE '[410] event_reminder_15m agregado a notifications_type_check ✅';
END;
$$;

COMMIT;

-- ── Verificación ──────────────────────────────────────────────────────────────
SELECT pg_get_constraintdef(c.oid) LIKE '%event_reminder_15m%' AS tipo_presente
FROM   pg_constraint c
WHERE  c.conname  = 'notifications_type_check'
  AND  c.conrelid = 'public.notifications'::regclass;
-- Esperado: true

SELECT '410_notifications_type_check_15m.sql ejecutado ✅' AS status;
