-- ════════════════════════════════════════════════════════════════════
-- sql/371_event_request_expiry_24h.sql
--
-- PROBLEMA: sql/81 dejó expires_at default en 15 minutos (era para
--   testing). El cron expire_stale_requests marca la solicitud como
--   'expired' a los 15 min y desaparece antes de que los grupos puedan
--   cotizar.
--
-- FIX: Cambiar default de 15 min → 24 horas.
--   El propio sql/81 indica "Cambiar a '48 hours' en producción".
--   Usamos 24 h como valor de producción conservador.
--
--   Solicitudes Express: tienen ventana de 60 min en express_dispatches.
--   Solicitudes programadas: cliente puede recibir propuestas durante 24 h.
--
-- NOTA: Solo afecta solicitudes NUEVAS. Las ya creadas mantienen
--   su expires_at original (si necesitas extender las activas,
--   ejecuta el UPDATE de abajo por separado).
-- ════════════════════════════════════════════════════════════════════

BEGIN;

ALTER TABLE public.event_requests
  ALTER COLUMN expires_at SET DEFAULT NOW() + INTERVAL '24 hours';

COMMIT;

-- Verificación: el nuevo default debe mostrar '24:00:00'
SELECT column_default
FROM information_schema.columns
WHERE table_schema = 'public'
  AND table_name   = 'event_requests'
  AND column_name  = 'expires_at';

-- ── OPCIONAL: extender solicitudes activas que vencieron por el bug ───────────
-- Ejecuta esto POR SEPARADO si quieres recuperar requests ya creadas:
--
-- UPDATE public.event_requests
-- SET expires_at = NOW() + INTERVAL '24 hours'
-- WHERE status IN ('open', 'en_negociacion')
--   AND expires_at < NOW() + INTERVAL '1 hour';
