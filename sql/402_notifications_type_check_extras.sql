-- ════════════════════════════════════════════════════════════════════
-- sql/402 — Ampliar notifications_type_check con tipos de horas extra
--
-- Problema:
--   sql/400 (group_accept_extra_hour_stripe) inserta notification con
--   type='extra_hour_payment_required'. sql/401 (expire cron) inserta
--   'extra_hour_expired' y 'extra_hour_payment_expired'.
--   Ninguno de los 3 está en el CHECK constraint → violación →
--   la RPC retorna { ok: false, error: 'violates check constraint' }.
--
-- Fix:
--   Recrear notifications_type_check con los 3 tipos faltantes.
--   Preservar TODOS los tipos existentes de sql/396 (el último que
--   modificó el constraint).
--
-- Tipos añadidos:
--   extra_hour_payment_required  (sql/400) — cliente paga con Stripe
--   extra_hour_expired           (sql/401) — solicitud venció por timeout
--   extra_hour_payment_expired   (sql/401) — cliente no pagó en tiempo
-- ════════════════════════════════════════════════════════════════════

BEGIN;

DO $$
BEGIN
  -- ── 1. Drop constraint actual ────────────────────────────────────
  ALTER TABLE public.notifications
    DROP CONSTRAINT IF EXISTS notifications_type_check;

  -- ── 2. Recrear con TODOS los tipos (existentes + 3 nuevos) ──────
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
      -- Ciclo de vida del evento
      'event_completed', 'event_started', 'overtime_requested',
      'event_auto_started', 'event_no_show_alert',
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
      -- Horas extra (353)
      'extra_hour_proposed',           -- grupo propone → cliente
      'extra_hour_approved_by_client', -- cliente aprueba → grupo
      'extra_hour_payment_confirmed',  -- cobro descontado → cliente
      -- Horas extra (391)
      'extra_hour_rejected_by_client', -- cliente rechaza propuesta del grupo → grupo
      -- Horas extra (395)
      'extra_hour_requested',          -- cliente solicita → grupo
      -- Horas extra (396)
      'extra_hour_rejected',           -- grupo/sistema rechaza solicitud del cliente → cliente
      -- Horas extra (400) ← NUEVOS
      'extra_hour_payment_required',   -- grupo aceptó con Stripe → cliente debe pagar
      -- Horas extra (401) ← NUEVOS
      'extra_hour_expired',            -- solicitud venció por timeout (cliente y grupo)
      'extra_hour_payment_expired'     -- cliente no pagó en tiempo → grupo notificado
    )) NOT VALID;

  RAISE NOTICE '[402] notifications_type_check actualizado con extra_hour_payment_required, extra_hour_expired, extra_hour_payment_expired ✅';
END;
$$;

COMMIT;

-- ════════════════════════════════════════════════════════════════════
-- VERIFICACIONES (ejecutar separado después del COMMIT)
-- ════════════════════════════════════════════════════════════════════

-- V1: Confirmar que el constraint existe
SELECT conname, contype
FROM   pg_constraint c
JOIN   pg_class t ON t.oid = c.conrelid
WHERE  t.relname = 'notifications'
  AND  c.conname = 'notifications_type_check';
-- Esperado: 1 fila, contype = 'c'

-- V2: Confirmar que los 3 tipos nuevos están en el CHECK
SELECT
  pg_get_constraintdef(c.oid) LIKE '%extra_hour_payment_required%' AS tiene_payment_required,
  pg_get_constraintdef(c.oid) LIKE '%extra_hour_expired%'          AS tiene_expired,
  pg_get_constraintdef(c.oid) LIKE '%extra_hour_payment_expired%'  AS tiene_payment_expired
FROM   pg_constraint c
JOIN   pg_class t ON t.oid = c.conrelid
WHERE  t.relname = 'notifications'
  AND  c.conname = 'notifications_type_check';
-- Esperado: true | true | true

-- V3: Confirmar que tipos viejos clave siguen presentes
SELECT
  pg_get_constraintdef(c.oid) LIKE '%extra_hour_requested%'        AS tiene_requested,
  pg_get_constraintdef(c.oid) LIKE '%extra_hour_rejected%'         AS tiene_rejected,
  pg_get_constraintdef(c.oid) LIKE '%booking_confirmed%'           AS tiene_booking_confirmed,
  pg_get_constraintdef(c.oid) LIKE '%express_dispatch%'            AS tiene_express_dispatch,
  pg_get_constraintdef(c.oid) LIKE '%payment_released%'            AS tiene_payment_released
FROM   pg_constraint c
JOIN   pg_class t ON t.oid = c.conrelid
WHERE  t.relname = 'notifications'
  AND  c.conname = 'notifications_type_check';
-- Esperado: true | true | true | true | true

-- V4: Dry-run INSERT con type='extra_hour_payment_required' (rollback automático)
DO $$
DECLARE v_test_id UUID;
BEGIN
  INSERT INTO public.notifications (user_id, type, title, body, data)
  VALUES (
    '00000000-0000-0000-0000-000000000000'::UUID,
    'extra_hour_payment_required',
    'Test V4',
    'Verificación sql/402',
    '{}'::JSONB
  )
  RETURNING id INTO v_test_id;

  -- Revertir inmediatamente
  DELETE FROM public.notifications WHERE id = v_test_id;

  RAISE NOTICE '[V4] INSERT extra_hour_payment_required OK, registro revertido ✅';
EXCEPTION WHEN OTHERS THEN
  RAISE EXCEPTION '[V4] FALLÓ: %', SQLERRM;
END;
$$;
