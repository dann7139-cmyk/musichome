-- ============================================================
-- sql/248_fix_talent_videos_rls.sql
--
-- Recrea las políticas RLS del bucket talent-videos usando
-- DROP IF EXISTS + CREATE — bypasea los guards IF NOT EXISTS
-- de los scripts 246/247 que sólo crean si la política NO existía.
--
-- Ejecutar si la subida de videos retorna:
--   Storage 400: { "statusCode":"403", "error":"Unauthorized",
--                  "message":"new row violates row-level security policy" }
--
-- Prerequisito: el bucket 'talent-videos' debe existir (Public: ON).
-- No toca: pagos, wallets, Stripe, reservas, timers, realtime.
-- ============================================================

-- Verificar que el bucket existe antes de proceder
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM storage.buckets WHERE id = 'talent-videos') THEN
    RAISE EXCEPTION '[248] El bucket talent-videos no existe. '
      'Créalo en: Dashboard → Storage → New Bucket → Name: talent-videos, Public: ON';
  END IF;
  RAISE NOTICE '[248] Bucket talent-videos encontrado ✅';
END;
$$;

-- ── Eliminar políticas anteriores (idempotente) ──────────────────────────────

DROP POLICY IF EXISTS "talent-videos upload" ON storage.objects;
DROP POLICY IF EXISTS "talent-videos update" ON storage.objects;
DROP POLICY IF EXISTS "talent-videos delete" ON storage.objects;
DROP POLICY IF EXISTS "talent-videos select" ON storage.objects;

-- ── Recrear políticas limpias ────────────────────────────────────────────────

-- INSERT: el usuario autenticado sólo puede subir a su propia carpeta UID/
CREATE POLICY "talent-videos upload" ON storage.objects
  FOR INSERT TO authenticated
  WITH CHECK (
    bucket_id = 'talent-videos'
    AND (storage.foldername(name))[1] = auth.uid()::text
  );

-- UPDATE: WITH CHECK explícito para cubrir upsert (x-upsert: true)
CREATE POLICY "talent-videos update" ON storage.objects
  FOR UPDATE TO authenticated
  USING (
    bucket_id = 'talent-videos'
    AND (storage.foldername(name))[1] = auth.uid()::text
  )
  WITH CHECK (
    bucket_id = 'talent-videos'
    AND (storage.foldername(name))[1] = auth.uid()::text
  );

-- DELETE: sólo el dueño de la carpeta puede eliminar su archivo
CREATE POLICY "talent-videos delete" ON storage.objects
  FOR DELETE TO authenticated
  USING (
    bucket_id = 'talent-videos'
    AND (storage.foldername(name))[1] = auth.uid()::text
  );

-- SELECT: lectura pública (necesaria para getPublicUrl y para que el gateway
-- de Storage pueda verificar existencia del objeto durante upsert interno)
CREATE POLICY "talent-videos select" ON storage.objects
  FOR SELECT TO anon, authenticated
  USING (bucket_id = 'talent-videos');

-- ── Verificación final ───────────────────────────────────────────────────────

DO $$
DECLARE
  v_count INT;
BEGIN
  SELECT COUNT(*) INTO v_count
  FROM pg_policies
  WHERE tablename  = 'objects'
    AND schemaname = 'storage'
    AND policyname LIKE 'talent-videos%';

  IF v_count = 4 THEN
    RAISE NOTICE '[248] ✅ 4 políticas de talent-videos creadas correctamente.';
  ELSE
    RAISE WARNING '[248] ⚠ Se esperaban 4 políticas, se encontraron %', v_count;
  END IF;
END;
$$;

SELECT
  policyname,
  cmd        AS operation,
  roles,
  qual       AS using_clause,
  with_check
FROM pg_policies
WHERE tablename  = 'objects'
  AND schemaname = 'storage'
  AND policyname LIKE 'talent-videos%'
ORDER BY policyname;
