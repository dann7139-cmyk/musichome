-- ============================================================
-- sql/491_reports_bucket.sql
-- 📊 Bucket PRIVADO para reportes descargables (Excel).
--
-- La Edge Function generate-report (service role) sube el .xlsx y
-- entrega una URL FIRMADA de 1 hora. Ningún usuario lee el bucket
-- directamente — no se crean políticas de lectura para authenticated:
-- la única puerta es la URL firmada que emite el servidor tras
-- validar el rol (admin = todo; grupo = solo lo suyo).
-- ============================================================

INSERT INTO storage.buckets (id, name, public)
VALUES ('reports', 'reports', false)
ON CONFLICT (id) DO NOTHING;

-- ── VERIFICACIÓN ──────────────────────────────────────────────────────────────
SELECT id, public FROM storage.buckets WHERE id = 'reports';
-- Esperado: reports | false

SELECT '491_reports_bucket.sql ejecutado ✅' AS status;
