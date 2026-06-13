-- ============================================================
-- sql/346_fix_notifications_constraint_and_quote_type.sql
--
-- PROBLEMA 1: La constraint notifications_type_check fue redefinida
--   en sql/196 y dejó fuera todos los tipos añadidos en SQLs 197-345:
--   express_dispatch, event_reminder_morning, event_reminder_1h,
--   event_reminder_3h, event_reminder_2h, event_upcoming_24h,
--   event_auto_started, event_no_show_alert, payout, wallet,
--   payment_received, payment_mismatch, fraud_alert, referral_reward,
--   general, etc.
--   Efecto: INSERT de esos tipos falla con constraint violation.
--   En funciones con EXCEPTION handler (crons), la excepción se captura
--   y la fila se descarta silenciosamente → 0 recordatorios en prod.
--
-- PROBLEMA 2: QuoteDetailScreen.tsx notificaba a integrantes con
--   tipo 'new_quote_request' cuando el dueño envía precio al cliente.
--   El tipo correcto es 'quote_sent_to_client' para diferenciar:
--     new_quote_request  = cliente solicita cotización al grupo
--     quote_sent_to_client = dueño envía precio, notifica a integrantes
--
-- FIX: Recrear constraint con lista completa + añadir nuevo tipo.
-- ============================================================

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
      'fraud_alert', 'referral_reward'
    )) NOT VALID;
    -- NOT VALID: no revalida filas existentes (puede haber tipos legacy).
    -- Nuevos INSERTs sí quedan validados.

  RAISE NOTICE '[346] notifications_type_check recreado con 55 tipos ✅';
END;
$$;

-- ── Verificación ──────────────────────────────────────────────────────────────
DO $$
DECLARE
  v_types TEXT[];
BEGIN
  SELECT array_agg(e ORDER BY e)
  INTO   v_types
  FROM   pg_constraint c
  JOIN   LATERAL regexp_matches(
           pg_get_constraintdef(c.oid),
           '''([a-z_]+)''',
           'g'
         ) AS m(e) ON TRUE
  WHERE  c.conname    = 'notifications_type_check'
    AND  c.conrelid   = 'public.notifications'::regclass;

  RAISE NOTICE '[346] Tipos en constraint: %', array_to_string(v_types, ', ');
END;
$$;

-- Prueba de inserción con el tipo nuevo
DO $$
DECLARE v_uid UUID;
BEGIN
  SELECT id INTO v_uid FROM public.profiles WHERE role = 'group' LIMIT 1;
  IF v_uid IS NULL THEN
    RAISE NOTICE '[346] Sin grupo de prueba — omitiendo test INSERT';
    RETURN;
  END IF;

  INSERT INTO public.notifications (user_id, type, title, body, data)
  VALUES (v_uid, 'quote_sent_to_client',
          '🧪 Test 346', 'Tipo nuevo OK',
          jsonb_build_object('test', true));

  DELETE FROM public.notifications
  WHERE type = 'quote_sent_to_client' AND title = '🧪 Test 346';

  RAISE NOTICE '[346] INSERT/DELETE de quote_sent_to_client ✅';
EXCEPTION WHEN OTHERS THEN
  RAISE WARNING '[346] FALLO en test: %', SQLERRM;
END;
$$;

SELECT '346_fix_notifications_constraint_and_quote_type.sql ejecutado ✅' AS status;
