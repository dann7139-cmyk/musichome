-- ════════════════════════════════════════════════════════════════════
-- sql/349_proximity_notification_types.sql
--
-- Agrega 2 tipos nuevos a la constraint notifications_type_check:
--   · request_expired_proximity  → al cliente cuando su solicitud
--     expira por proximidad al evento (< 2h) o evento ya pasado.
--   · quote_expired_proximity    → al grupo cuando la cotización
--     expira por la misma razón.
--
-- Debe ejecutarse ANTES de 350 (expire_stale_requests usa estos tipos).
-- Patrón idéntico al 346 que ya consolidó la constraint.
-- ════════════════════════════════════════════════════════════════════

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
      'fraud_alert', 'referral_reward',
      -- Proximidad al evento (nuevos en 349)
      'request_expired_proximity',
      'quote_expired_proximity'
    )) NOT VALID;
    -- NOT VALID: no revalida filas existentes (puede haber tipos legacy).
    -- Nuevos INSERTs sí quedan validados.

  RAISE NOTICE '[349] notifications_type_check recreado con 57 tipos (+ proximity) ✅';
END;
$$;

-- ── Verificación del conteo ───────────────────────────────────────────────────
DO $$
DECLARE
  v_count INT;
BEGIN
  SELECT count(*)
  INTO   v_count
  FROM   pg_constraint c
  JOIN   LATERAL regexp_matches(
           pg_get_constraintdef(c.oid),
           '''([a-z_]+)''',
           'g'
         ) AS m(e) ON TRUE
  WHERE  c.conname    = 'notifications_type_check'
    AND  c.conrelid   = 'public.notifications'::regclass;

  RAISE NOTICE '[349] Tipos en constraint: %', v_count;
END;
$$;

-- ── Test INSERT / DELETE de los 2 tipos nuevos ───────────────────────────────
DO $$
DECLARE v_uid UUID;
BEGIN
  SELECT id INTO v_uid FROM public.profiles WHERE role = 'client' LIMIT 1;
  IF v_uid IS NULL THEN
    RAISE NOTICE '[349] Sin perfil client de prueba — omitiendo test INSERT';
    RETURN;
  END IF;

  INSERT INTO public.notifications (user_id, type, title, body, data)
  VALUES
    (v_uid, 'request_expired_proximity', '🧪 Test 349a', 'request_expired_proximity OK',
     jsonb_build_object('test', true)),
    (v_uid, 'quote_expired_proximity',   '🧪 Test 349b', 'quote_expired_proximity OK',
     jsonb_build_object('test', true));

  DELETE FROM public.notifications
  WHERE type IN ('request_expired_proximity', 'quote_expired_proximity')
    AND title LIKE '🧪 Test 349%';

  RAISE NOTICE '[349] Test INSERT/DELETE de ambos tipos nuevos ✅';
EXCEPTION WHEN OTHERS THEN
  RAISE WARNING '[349] FALLO en test: %', SQLERRM;
END;
$$;

SELECT '349_proximity_notification_types.sql ejecutado ✅' AS status;
