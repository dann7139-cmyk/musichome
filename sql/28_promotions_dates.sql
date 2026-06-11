-- ══════════════════════════════════════════════════════════════════════════════
-- 28_promotions_dates.sql
-- Agrega fechas de inicio/fin y multimedia a la tabla promotions.
-- Ejecutar en Supabase SQL Editor.
-- ══════════════════════════════════════════════════════════════════════════════

-- ── 1. Columnas nuevas en promotions ─────────────────────────────────────────
ALTER TABLE promotions ADD COLUMN IF NOT EXISTS starts_at  timestamptz;
ALTER TABLE promotions ADD COLUMN IF NOT EXISTS ends_at    timestamptz;
ALTER TABLE promotions ADD COLUMN IF NOT EXISTS media_url  text;
ALTER TABLE promotions ADD COLUMN IF NOT EXISTS media_type text DEFAULT 'none'
  CHECK (media_type IN ('none', 'image', 'video'));

-- ── 2. Índice para filtrado eficiente ─────────────────────────────────────────
CREATE INDEX IF NOT EXISTS idx_promotions_dates
  ON promotions (starts_at, ends_at)
  WHERE is_active = true;

-- ── 3. Storage bucket público ─────────────────────────────────────────────────
INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES (
  'promotions-media',
  'promotions-media',
  true,
  52428800, -- 50 MB
  ARRAY['image/jpeg','image/png','image/webp','image/gif','video/mp4','video/mov','video/quicktime']
) ON CONFLICT (id) DO NOTHING;

-- ── 4. Storage policies ───────────────────────────────────────────────────────

-- Cualquiera puede leer (es público)
CREATE POLICY "Public read promotions-media"
  ON storage.objects FOR SELECT
  USING (bucket_id = 'promotions-media');

-- Solo admin puede subir
CREATE POLICY "Admin upload promotions-media"
  ON storage.objects FOR INSERT
  WITH CHECK (
    bucket_id = 'promotions-media' AND
    EXISTS (SELECT 1 FROM profiles WHERE id = auth.uid() AND role = 'admin')
  );

-- Solo admin puede actualizar
CREATE POLICY "Admin update promotions-media"
  ON storage.objects FOR UPDATE
  USING (
    bucket_id = 'promotions-media' AND
    EXISTS (SELECT 1 FROM profiles WHERE id = auth.uid() AND role = 'admin')
  );

-- Solo admin puede eliminar
CREATE POLICY "Admin delete promotions-media"
  ON storage.objects FOR DELETE
  USING (
    bucket_id = 'promotions-media' AND
    EXISTS (SELECT 1 FROM profiles WHERE id = auth.uid() AND role = 'admin')
  );
