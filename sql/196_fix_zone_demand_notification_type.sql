-- ════════════════════════════════════════════════════════════════════
-- 196_fix_zone_demand_notification_type.sql
--
-- PROBLEMA: El trigger notify_groups_in_zone() (116) inserta
--   notificaciones con type = 'zone_demand', pero el constraint
--   notifications_type_check fue redefinido en 193 sin incluir
--   ese tipo, causando el error:
--   "new row for relation notifications violates check constraint
--    notifications_type_check"
--
-- FIX: Ampliar el constraint para incluir 'zone_demand'.
-- ════════════════════════════════════════════════════════════════════

DO $$
BEGIN
  ALTER TABLE public.notifications
    DROP CONSTRAINT IF EXISTS notifications_type_check;

  ALTER TABLE public.notifications
    ADD CONSTRAINT notifications_type_check CHECK (type IN (
      -- Legacy
      'reservation', 'payment', 'review', 'verification', 'system',
      'financial', 'admin_alert',
      -- Reservas
      'booking', 'booking_received', 'booking_accepted', 'booking_confirmed',
      'booking_rejected', 'booking_auto_cancelled', 'booking_expired_no_payment',
      'booking_cancelled',
      -- Pagos
      'deposit_received', 'payment_released',
      -- Eventos
      'event_reminder_24h', 'event_completed', 'event_started', 'overtime_requested',
      -- Disputas
      'dispute_opened', 'dispute_received',
      -- Job board
      'job_invitation',
      -- Cotizaciones
      'new_quote_request', 'quote_received', 'quote_accepted', 'quote_cancelled',
      -- Chat
      'chat',
      -- Marketing / visibilidad (grupos)
      'ad_space_available', 'high_demand', 'no_ads_in_city', 'first_ad_reminder',
      -- Re-engagement (clientes)
      'new_city_groups', 'group_nearby',
      -- Competencia de bids (152-153)
      'bid_displaced', 'bid_expiring_soon',
      -- Recordatorio renovación (141)
      'bid_expiry_reminder',
      -- Anuncios (193)
      'ad_payment_confirmed', 'ad_approved', 'ad_expiring_soon', 'ad_expired',
      -- Zona / demanda (116) — faltaba en 193
      'zone_demand'
    )) NOT VALID;
END;
$$;

SELECT '196_fix_zone_demand_notification_type.sql ejecutado ✅' AS status;
SELECT 'zone_demand agregado al constraint notifications_type_check' AS fix;
