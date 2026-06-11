-- ════════════════════════════════════════════════════════════════════
-- 76_event_request_expiry_30min.sql
-- Cambia el tiempo de expiración de solicitudes de 48h a 30 minutos
-- (para pruebas). Cambiar de vuelta a '48 hours' en producción.
-- ════════════════════════════════════════════════════════════════════

ALTER TABLE public.event_requests
  ALTER COLUMN expires_at SET DEFAULT NOW() + INTERVAL '30 minutes';

SELECT '76_event_request_expiry_30min: expiración cambiada a 30 min ✅' AS status;
