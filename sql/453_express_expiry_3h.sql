-- ============================================================
-- sql/453_express_expiry_3h.sql
-- Las solicitudes EXPRÉS deben expirar en 3 HORAS (antes: 24 h, sql/371).
-- Aplica al cliente Y al grupo (mismo expires_at; el grupo ve el countdown).
--
-- El cron expire_stale_requests (cada 5 min) ya marca 'expired' cuando
-- expires_at < NOW() — no se toca. Solo cambiamos la ventana + backfill.
-- ============================================================

BEGIN;

-- 1. Nuevas solicitudes: 3 h
ALTER TABLE public.event_requests
  ALTER COLUMN expires_at SET DEFAULT NOW() + INTERVAL '3 hours';

-- 2. Backfill: las que siguen vivas y tenían ventana más larga → acortar a
--    created_at + 3 h. Las que ya pasan de 3 h de vida expirarán en el
--    próximo cron. No toca las ya expiradas (expires_at <= NOW()).
UPDATE public.event_requests
SET    expires_at = created_at + INTERVAL '3 hours'
WHERE  expires_at > NOW()
  AND  expires_at > created_at + INTERVAL '3 hours';

COMMIT;

-- ── VERIFICACIONES ──────────────────────────────────────────────────────────────
-- V1: el default quedó en 3 h
SELECT column_default
FROM   information_schema.columns
WHERE  table_name = 'event_requests' AND column_name = 'expires_at';
-- Esperado: contiene "03:00:00" / "3 hours"

-- V2: no quedan solicitudes vivas con ventana > 3 h desde su creación
SELECT COUNT(*) AS vivas_con_ventana_larga
FROM   public.event_requests
WHERE  expires_at > NOW()
  AND  expires_at > created_at + INTERVAL '3 hours';
-- Esperado: 0

SELECT '453_express_expiry_3h.sql ejecutado ✅' AS status;
