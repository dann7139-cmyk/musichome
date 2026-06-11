-- ============================================================
-- sql/247_talent_videos_storage_policies.sql
--
-- Asegura que las políticas RLS del bucket talent-videos existen.
-- Ejecutar si sql/246 fue corrido ANTES de crear el bucket
-- (en ese caso el bloque DO de políticas mostró WARNING y no creó nada).
--
-- Idempotente: verifica pg_policies antes de CREATE.
-- Prerequisito: bucket 'talent-videos' debe existir (Public: ON).
-- ============================================================

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM storage.buckets WHERE id = 'talent-videos') THEN
    RAISE EXCEPTION '[247] El bucket talent-videos no existe. Créalo primero con: INSERT INTO storage.buckets (id, name, public) VALUES (''talent-videos'', ''talent-videos'', true) ON CONFLICT (id) DO NOTHING;';
  END IF;

  -- Upload: solo el dueño puede subir a su carpeta
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE policyname = 'talent-videos upload'
      AND tablename  = 'objects'
      AND schemaname = 'storage'
  ) THEN
    EXECUTE $p$
      CREATE POLICY "talent-videos upload" ON storage.objects
      FOR INSERT TO authenticated
      WITH CHECK (
        bucket_id = 'talent-videos'
        AND (storage.foldername(name))[1] = auth.uid()::text
      );
    $p$;
    RAISE NOTICE '[247] Política upload creada ✅';
  ELSE
    RAISE NOTICE '[247] Política upload ya existía ✅';
  END IF;

  -- Update: solo el dueño
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE policyname = 'talent-videos update'
      AND tablename  = 'objects'
      AND schemaname = 'storage'
  ) THEN
    EXECUTE $p$
      CREATE POLICY "talent-videos update" ON storage.objects
      FOR UPDATE TO authenticated
      USING (
        bucket_id = 'talent-videos'
        AND (storage.foldername(name))[1] = auth.uid()::text
      );
    $p$;
    RAISE NOTICE '[247] Política update creada ✅';
  ELSE
    RAISE NOTICE '[247] Política update ya existía ✅';
  END IF;

  -- Delete: solo el dueño
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE policyname = 'talent-videos delete'
      AND tablename  = 'objects'
      AND schemaname = 'storage'
  ) THEN
    EXECUTE $p$
      CREATE POLICY "talent-videos delete" ON storage.objects
      FOR DELETE TO authenticated
      USING (
        bucket_id = 'talent-videos'
        AND (storage.foldername(name))[1] = auth.uid()::text
      );
    $p$;
    RAISE NOTICE '[247] Política delete creada ✅';
  ELSE
    RAISE NOTICE '[247] Política delete ya existía ✅';
  END IF;

  RAISE NOTICE '[247] Políticas RLS de talent-videos verificadas ✅';
END;
$$;

-- Verificación final
SELECT
  policyname,
  cmd,
  qual,
  with_check
FROM pg_policies
WHERE tablename  = 'objects'
  AND schemaname = 'storage'
  AND policyname LIKE 'talent-videos%'
ORDER BY policyname;
