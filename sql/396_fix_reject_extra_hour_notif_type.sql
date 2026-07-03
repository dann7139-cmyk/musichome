-- ════════════════════════════════════════════════════════════════════
-- sql/396 — Fix group_reject_extra_hour: type 'reservation' → 'extra_hour_rejected'
--
-- Problema:
--   group_reject_extra_hour (sql/393) inserta notificación al cliente con
--   type='reservation' → al tocarla, el cliente navega a ReservationsScreen.
--   Debe navegar a EventTimer para ver el contexto del rechazo.
--
-- Fix:
--   A. Agregar 'extra_hour_rejected' al CHECK constraint de notifications.
--      Tipo semántico: grupo (o sistema) rechazó solicitud del cliente.
--      Distinto de 'extra_hour_rejected_by_client' (sql/391) que es el inverso.
--   B. Recrear group_reject_extra_hour con type='extra_hour_rejected'.
--      NotificationsScreen case 'extra_hour_rejected' navega a EventTimer.
-- ════════════════════════════════════════════════════════════════════

BEGIN;

-- ── A. Agregar tipo al constraint ─────────────────────────────────────────────

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
      'extra_hour_rejected_by_client', -- cliente rechaza propuesta del grupo → grupo
      -- Horas extra (395)
      'extra_hour_requested',          -- cliente solicita → grupo
      -- Horas extra (396)
      'extra_hour_rejected'            -- grupo/sistema rechaza solicitud del cliente → cliente
    )) NOT VALID;

  RAISE NOTICE '[396] notifications_type_check actualizado con extra_hour_rejected ✅';
END;
$$;

-- ── B. Recrear group_reject_extra_hour con type correcto ─────────────────────

CREATE OR REPLACE FUNCTION public.group_reject_extra_hour(
  p_extra_id UUID
)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_extra  RECORD;
  v_res    RECORD;
  v_caller UUID := auth.uid();
BEGIN
  IF v_caller IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'unauthorized');
  END IF;

  SELECT * INTO v_extra
  FROM   public.extra_hours
  WHERE  id = p_extra_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'extra_not_found');
  END IF;

  IF v_extra.status NOT IN ('pending', 'client_requested', 'awaiting_group_confirmation') THEN
    RETURN jsonb_build_object('ok', true, 'skipped', true, 'reason', 'already_processed');
  END IF;

  SELECT r.*, g.owner_id AS group_owner_id
  INTO   v_res
  FROM   public.reservations r
  JOIN   public.groups g ON g.id = r.group_id
  WHERE  r.id = v_extra.reservation_id;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'reservation_not_found');
  END IF;

  IF v_caller != v_res.group_owner_id THEN
    RETURN jsonb_build_object('ok', false, 'error', 'unauthorized: solo el owner del grupo puede rechazar');
  END IF;

  UPDATE public.extra_hours
  SET status = 'rejected'
  WHERE id = p_extra_id;

  -- FIX: type corregido 'reservation' → 'extra_hour_rejected'
  -- NotificationsScreen.case 'extra_hour_rejected' navega a EventTimer
  IF v_res.client_id IS NOT NULL THEN
    INSERT INTO public.notifications (user_id, type, title, body, data)
    VALUES (
      v_res.client_id,
      'extra_hour_rejected',
      '❌ Hora extra no disponible',
      'El grupo no puede extender el servicio en este momento.',
      jsonb_build_object(
        'reservation_id', v_extra.reservation_id,
        'screen',         'EventTimer'
      )
    );
  END IF;

  RETURN jsonb_build_object('ok', true, 'extra_id', p_extra_id);

EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$$;

GRANT EXECUTE ON FUNCTION public.group_reject_extra_hour(UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION public.group_reject_extra_hour(UUID) TO service_role;

COMMIT;

-- ════════════════════════════════════════════════════════════════════
-- VERIFICACIONES (ejecutar separado después del COMMIT)
-- ════════════════════════════════════════════════════════════════════

-- V1: Constraint incluye 'extra_hour_rejected'
SELECT pg_get_constraintdef(c.oid) LIKE '%extra_hour_rejected%' AS tipo_presente
FROM   pg_constraint c
JOIN   pg_class t ON t.oid = c.conrelid
WHERE  t.relname = 'notifications'
  AND  c.conname = 'notifications_type_check';
-- Esperado: true

-- V2: group_reject_extra_hour usa 'extra_hour_rejected' (no 'reservation')
SELECT
  routine_definition LIKE '%extra_hour_rejected%' AS tipo_correcto,
  routine_definition NOT LIKE '%''reservation''%'  AS sin_tipo_viejo
FROM information_schema.routines
WHERE routine_schema = 'public'
  AND routine_name   = 'group_reject_extra_hour';
-- Esperado: true | true

-- V3: Función tiene SECURITY DEFINER y GRANT para authenticated
SELECT proname, prosecdef AS is_security_definer
FROM pg_proc
WHERE proname = 'group_reject_extra_hour'
  AND pronamespace = (SELECT oid FROM pg_namespace WHERE nspname = 'public');
-- Esperado: is_security_definer = true

-- V4: Función mantiene la verificación de ownership
SELECT routine_definition LIKE '%v_caller != v_res.group_owner_id%' AS verifica_ownership
FROM information_schema.routines
WHERE routine_schema = 'public'
  AND routine_name   = 'group_reject_extra_hour';
-- Esperado: true
