-- Punto de inicio del clip de video dentro del archivo subido.
-- duration_seconds (SQL 333) controla hasta cuándo suena/aparece.
-- Ejemplo: start=10, duration=20 → el explorador reproduce del segundo 10 al 30.
ALTER TABLE promotions ADD COLUMN IF NOT EXISTS video_start_seconds INTEGER DEFAULT 0;
