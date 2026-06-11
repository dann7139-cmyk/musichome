-- ════════════════════════════════════════════════════════════════════
-- 81_event_request_expiry_15min.sql
-- Cambia expiración de solicitudes express a 15 minutos (pruebas).
-- Cambiar a '48 hours' en producción.
-- ════════════════════════════════════════════════════════════════════

ALTER TABLE public.event_requests
  ALTER COLUMN expires_at SET DEFAULT NOW() + INTERVAL '15 minutes';

SELECT '81_event_request_expiry_15min: expiración cambiada a 15 min ✅' AS status;
