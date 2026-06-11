-- ══════════════════════════════════════════════════════════════════════════════
-- 29_fix.sql
-- Agrega media_offset a promotions (posición vertical del video/imagen).
-- Ejecutar en Supabase SQL Editor.
-- ══════════════════════════════════════════════════════════════════════════════

-- Posición vertical: 0 = arriba, 50 = centro, 100 = abajo
ALTER TABLE promotions ADD COLUMN IF NOT EXISTS media_offset int DEFAULT 50;
