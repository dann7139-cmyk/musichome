-- ════════════════════════════════════════════════════════════════════════════
-- 101_push_notifications_complete.sql
-- Asegura que TODAS las notificaciones lleguen como push reales al dispositivo
-- aunque la app esté cerrada.
--
-- FIX 1: Constraint de tipos — incluye todos los tipos del sistema
-- FIX 2: Cron para send-push-notification (despacha cada minuto)
--
-- Ejecutar DESPUÉS de 100_reservation_improvements.sql
-- ════════════════════════════════════════════════════════════════════════════

-- ────────────────────────────────────────────────────────────────────────────
-- FIX 1: CONSTRAINT DE TIPOS COMPLETO
-- Reemplaza el constraint de 75_fix_notifications_booking_type.sql con
-- TODOS los tipos usados en el sistema (incluidos los de 100_reservation).
--
-- Si falta un tipo → INSERT falla silenciosamente → push nunca llega.
-- ────────────────────────────────────────────────────────────────────────────

ALTER TABLE public.notifications
  DROP CONSTRAINT IF EXISTS notifications_type_check;

ALTER TABLE public.notifications
  ADD CONSTRAINT notifications_type_check
  CHECK (type IN (
    -- ── Tipos legacy ──────────────────────────────────────────────────────
    'reservation',
    'payment',
    'review',
    'verification',
    'system',
    'financial',        -- usado en 92_security_protections (cancelaciones)
    'admin_alert',      -- usado en 92_security_protections (abuso detectado)

    -- ── Flujo de reservas programadas ────────────────────────────────────
    'booking',                          -- solicitudes express (wave system)
    'booking_received',                 -- grupo recibe nueva reserva
    'booking_accepted',
    'booking_confirmed',                -- grupo confirma → cliente notificado
    'booking_rejected',                 -- grupo rechaza → cliente notificado
    'booking_auto_cancelled',           -- expiró 24h sin respuesta del grupo
    'booking_expired_no_payment',       -- cliente no pagó a tiempo
    'booking_cancelled',                -- cliente cancela

    -- ── Pagos ─────────────────────────────────────────────────────────────
    'deposit_received',                 -- grupo recibe aviso de anticipo
    'payment_released',                 -- pago liberado al finalizar evento

    -- ── Eventos ───────────────────────────────────────────────────────────
    'event_reminder_24h',               -- recordatorio mañana / 3h / 1h antes
    'event_completed',                  -- evento marcado como completado
    'event_started',                    -- evento iniciado (opcional)

    -- ── Overtime / Horas extra ────────────────────────────────────────────
    'overtime_requested',               -- grupo solicita hora(s) extra (mejora 5)

    -- ── Disputas ──────────────────────────────────────────────────────────
    'dispute_opened',                   -- admin notificado de nueva disputa (mejora 6)
    'dispute_received',                 -- otra parte notificada de disputa abierta

    -- ── Bolsa de trabajo ──────────────────────────────────────────────────
    'job_invitation',                   -- invitación a integrarse al grupo

    -- ── Cotizaciones ──────────────────────────────────────────────────────
    'new_quote_request',
    'quote_received',
    'quote_accepted',
    'quote_cancelled'
  ));

-- ────────────────────────────────────────────────────────────────────────────
-- FIX 2: PROGRAMAR send-push-notification CADA MINUTO
--
-- OPCIÓN A (recomendada): Supabase Dashboard
--   → Edge Functions → send-push-notification → Schedule → "* * * * *"
--   No requiere pg_net. Más estable.
--
-- OPCIÓN B (pg_cron + pg_net, automática):
--   Requiere:
--     1. pg_net habilitado en Dashboard → Extensions → pg_net
--     2. Reemplazar YOUR_PROJECT_REF con tu Project Reference de Supabase
--        (Dashboard → Settings → General → Reference ID)
--     3. Reemplazar YOUR_SERVICE_ROLE_KEY con tu service_role key
--        (Dashboard → Settings → API → service_role)
-- ────────────────────────────────────────────────────────────────────────────

DO $$
BEGIN
  -- Desregistrar si ya existe con otro nombre
  BEGIN
    PERFORM cron.unschedule('dispatch-push-notifications');
  EXCEPTION WHEN OTHERS THEN NULL; END;

  PERFORM cron.schedule(
    'dispatch-push-notifications',
    '* * * * *',    -- cada minuto
    $cmd$
    SELECT net.http_post(
      url     := 'https://sqgzyipqpewzbnfrtdqk.supabase.co/functions/v1/send-push-notification',
      headers := '{"Authorization": "Bearer YOUR_SERVICE_ROLE_KEY", "Content-Type": "application/json"}'::jsonb,
      body    := '{}'::jsonb
    );
    $cmd$
  );

EXCEPTION WHEN OTHERS THEN
  RAISE NOTICE
    E'⚠️  No se pudo programar el cron de push.\n'
    '   Opciones:\n'
    '   A) Dashboard → Edge Functions → send-push-notification → Schedule → "* * * * *"\n'
    '   B) Habilitar pg_net en Extensions y re-ejecutar este bloque con tu PROJECT_REF y SERVICE_ROLE_KEY.';
END;
$$;

-- ────────────────────────────────────────────────────────────────────────────
-- RECORDATORIO: Verificar que los crons existentes siguen activos
-- (se configuraron en 100_reservation_improvements.sql)
-- ────────────────────────────────────────────────────────────────────────────
-- auto-cancel-bookings   → */5 * * * *   → auto_cancel_expired_bookings()
-- event-reminders        → 0 * * * *     → send_event_reminders()
-- process-express-waves  → */2 * * * *   → process_notification_waves()
-- dispatch-push-notifications → * * * * * → send-push-notification (Edge Fn)
-- ────────────────────────────────────────────────────────────────────────────

SELECT '101_push_notifications_complete: tipos + cron despachador ✅' AS status;
