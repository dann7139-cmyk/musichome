-- ════════════════════════════════════════════════════════════════════
-- sql/391 — Notificación al grupo cuando cliente rechaza hora extra
--
-- Contexto:
--   approve_extra_hour_payment_atomic (sql/353) ya notifica al grupo
--   cuando el cliente APRUEBA. Pero cuando el cliente RECHAZA
--   (UPDATE extra_hours SET status='rejected'), no había ninguna
--   notificación → el grupo quedaba sin saber la respuesta.
--
-- Cambios:
--   1. Tipo 'extra_hour_rejected_by_client' en notifications_type_check
--   2. Trigger notify_extra_hour_rejected — AFTER UPDATE en extra_hours
--      cuando status cambia a 'rejected'.
-- ════════════════════════════════════════════════════════════════════

BEGIN;

-- ─── 1. Agregar tipo al constraint ────────────────────────────────────────────

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
      -- Proximidad al evento (349)
      'request_expired_proximity', 'quote_expired_proximity',
      -- Horas extra (353)
      'extra_hour_proposed',           -- grupo propone → cliente
      'extra_hour_approved_by_client', -- cliente aprueba → grupo
      'extra_hour_payment_confirmed',  -- cobro descontado → cliente
      -- Horas extra (391)
      'extra_hour_rejected_by_client'  -- cliente rechaza → grupo
    )) NOT VALID;

  RAISE NOTICE '[391] notifications_type_check actualizado con extra_hour_rejected_by_client ✅';
END;
$$;

-- ─── 2. Trigger: notificar al grupo cuando cliente rechaza ────────────────────

CREATE OR REPLACE FUNCTION public.notify_extra_hour_rejected()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_group_owner_id UUID;
  v_hours_added    INT;
BEGIN
  SELECT g.owner_id, NEW.hours_added
  INTO   v_group_owner_id, v_hours_added
  FROM   public.reservations r
  JOIN   public.groups g ON g.id = r.group_id
  WHERE  r.id = NEW.reservation_id;

  IF NOT FOUND OR v_group_owner_id IS NULL THEN
    RETURN NEW;
  END IF;

  INSERT INTO public.notifications (user_id, type, title, body, data)
  VALUES (
    v_group_owner_id,
    'extra_hour_rejected_by_client',
    '❌ Cliente rechazó la hora extra',
    'El cliente rechazó tu propuesta de +' || COALESCE(v_hours_added, 1)::TEXT ||
      'h extra. El evento continúa hasta el tiempo contratado.',
    jsonb_build_object(
      'screen',         'EventTimer',
      'reservation_id', NEW.reservation_id,
      'extra_hour_id',  NEW.id
    )
  );

  RETURN NEW;

EXCEPTION WHEN OTHERS THEN
  RAISE WARNING '[391] notify_extra_hour_rejected falló: %', SQLERRM;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_notify_extra_hour_rejected ON public.extra_hours;

CREATE TRIGGER trg_notify_extra_hour_rejected
  AFTER UPDATE ON public.extra_hours
  FOR EACH ROW
  WHEN (OLD.status IS DISTINCT FROM NEW.status AND NEW.status = 'rejected')
  EXECUTE FUNCTION public.notify_extra_hour_rejected();

COMMIT;

-- ════════════════════════════════════════════════════════════════════
-- VERIFICACIONES (ejecutar separado después del COMMIT)
-- ════════════════════════════════════════════════════════════════════

-- V1: constraint incluye el tipo nuevo
SELECT pg_get_constraintdef(c.oid) LIKE '%extra_hour_rejected_by_client%' AS tipo_presente
FROM   pg_constraint c
WHERE  c.conname  = 'notifications_type_check'
  AND  c.conrelid = 'public.notifications'::regclass;
-- Esperado: true

-- V2: función existe con SECURITY DEFINER
SELECT proname, prosecdef AS is_security_definer
FROM   pg_proc
WHERE  proname = 'notify_extra_hour_rejected';
-- Esperado: 1 fila, is_security_definer = true

-- V3: trigger existe y apunta a la función correcta
SELECT tgname, tgenabled
FROM   pg_trigger
WHERE  tgname = 'trg_notify_extra_hour_rejected';
-- Esperado: 1 fila, tgenabled = 'O' (origin)

-- V4: simular rechazo y verificar notificación
-- UPDATE extra_hours SET status = 'rejected' WHERE id = '<uuid-pendiente>';
-- SELECT * FROM notifications WHERE type = 'extra_hour_rejected_by_client' ORDER BY created_at DESC LIMIT 1;
-- Esperado: 1 fila con body "❌ Cliente rechazó..." y user_id = group owner
