-- ============================================================
-- sql/258_verification_docs_upload_policy.sql
--
-- PROBLEMA: El bucket verification-docs solo tenía policy de
-- SELECT para admins (sql/257). Sin policy de INSERT/UPDATE,
-- los grupos no podían subir documentos ni selfies.
--
-- CAMBIOS:
--   1. INSERT policy — authenticated puede subir al bucket
--   2. UPDATE policy — authenticated puede reemplazar archivos
--      (necesario porque el código usa upsert:true)
--
-- IDEMPOTENTE: Sí (IF NOT EXISTS en cada policy).
-- ROLLBACK:
--   DROP POLICY IF EXISTS "verification_docs_auth_insert" ON storage.objects;
--   DROP POLICY IF EXISTS "verification_docs_auth_update" ON storage.objects;
-- ============================================================

DO $$
BEGIN
  -- INSERT: cualquier usuario autenticado puede subir al bucket
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE  policyname = 'verification_docs_auth_insert'
      AND  tablename  = 'objects'
      AND  schemaname = 'storage'
  ) THEN
    EXECUTE $p$
      CREATE POLICY "verification_docs_auth_insert"
        ON storage.objects
        FOR INSERT
        TO authenticated
        WITH CHECK (bucket_id = 'verification-docs');
    $p$;
    RAISE NOTICE '[258] verification_docs_auth_insert creada ✅';
  ELSE
    RAISE NOTICE '[258] verification_docs_auth_insert ya existía ✅';
  END IF;

  -- UPDATE: necesario para upsert:true en el upload
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE  policyname = 'verification_docs_auth_update'
      AND  tablename  = 'objects'
      AND  schemaname = 'storage'
  ) THEN
    EXECUTE $p$
      CREATE POLICY "verification_docs_auth_update"
        ON storage.objects
        FOR UPDATE
        TO authenticated
        USING (bucket_id = 'verification-docs');
    $p$;
    RAISE NOTICE '[258] verification_docs_auth_update creada ✅';
  ELSE
    RAISE NOTICE '[258] verification_docs_auth_update ya existía ✅';
  END IF;
END;
$$;

-- Verificación: mostrar todas las policies activas del bucket
SELECT policyname, cmd
FROM   pg_policies
WHERE  tablename  = 'objects'
  AND  schemaname = 'storage'
  AND  (qual LIKE '%verification-docs%' OR with_check LIKE '%verification-docs%')
ORDER  BY policyname;

SELECT '258_verification_docs_upload_policy.sql aplicado correctamente ✅' AS status;
