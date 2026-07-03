-- ============================================================
-- sql/418_fix_quote_expired_constraint.sql
-- Reincorporar 'quote_expired' a notifications_type_check
--
-- BUG: sql/362 agregó 'quote_expired' (aviso al cliente/grupo cuando
--   expire_stale_quotes cierra una cotización vencida). Las
--   reconstrucciones posteriores del constraint (391 → 396 → 402 →
--   408 → 410) copiaron la lista de un ARCHIVO anterior en vez de
--   leer la vigente, y lo perdieron. Desde 391, las notifs del cron
--   nocturno fallan en silencio (sus INSERTs están en bloques
--   EXCEPTION — la expiración funciona, el aviso jamás llega).
--
-- ⚠️ PATRÓN OBLIGATORIO A FUTURO (así se perdió el type):
--   Antes de CUALQUIER cambio a este constraint, LEER la lista
--   vigente de prod con pg_get_constraintdef y partir de ella.
--   NUNCA copiar la lista de un sql/NNN anterior: cualquier type
--   agregado en medio se pierde y sus notifs mueren en silencio.
--
-- Base de esta lista: la escrita por sql/410 (último ALTER corrido
-- en prod) + 'quote_expired'. El pre-check de abajo lo confirma.
-- ============================================================

-- ── PRE-CHECK: lista vigente ANTES del cambio ─────────────────────────────────
-- Compárala contra la lista de abajo. Si prod tiene algún type que NO
-- esté aquí abajo, DETENTE y repórtalo antes de correr el ALTER.
SELECT pg_get_constraintdef(c.oid) AS constraint_actual
FROM   pg_constraint c
WHERE  c.conname  = 'notifications_type_check'
  AND  c.conrelid = 'public.notifications'::regclass;

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
      -- Disputas
      'dispute_opened', 'dispute_received', 'dispute',
      -- Bolsa de trabajo
      'job_invitation',
      -- Cotizaciones
      'new_quote_request', 'quote_received',
      'quote_accepted',    'quote_cancelled', 'quote_sent_to_client',
      'quote_expired',                 -- ← REINCORPORADO (362, perdido en 391)
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

  RAISE NOTICE '[418] quote_expired reincorporado a notifications_type_check ✅';
END;
$$;

COMMIT;

-- ── POST-CHECK ────────────────────────────────────────────────────────────────
-- V1: quote_expired presente (y proximity sigue siendo un type aparte)
SELECT
  pg_get_constraintdef(c.oid) LIKE '%''quote_expired''%'           AS quote_expired_ok,
  pg_get_constraintdef(c.oid) LIKE '%quote_expired_proximity%'     AS proximity_intacto,
  pg_get_constraintdef(c.oid) LIKE '%event_reminder_15m%'          AS reminder_15m_intacto
FROM   pg_constraint c
WHERE  c.conname  = 'notifications_type_check'
  AND  c.conrelid = 'public.notifications'::regclass;
-- Esperado: true | true | true

-- V2 (opcional): probar que el INSERT del 362 ya no falla — simula y revierte
-- BEGIN;
--   INSERT INTO public.notifications (user_id, type, title, body, data)
--   SELECT id, 'quote_expired', 'test', 'test', '{}'::jsonb
--   FROM public.profiles LIMIT 1;
-- ROLLBACK;
-- Esperado: INSERT 0 1 (sin error de constraint) y el ROLLBACK lo deshace

SELECT '418_fix_quote_expired_constraint.sql ejecutado ✅' AS status;
