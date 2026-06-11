-- ============================================================
-- sql/24_storage_policies.sql
-- Políticas de Supabase Storage para el bucket "group-images"
--
-- El bucket almacena:
--   {groupId}/profile.jpg   → foto del grupo (sube el dueño)
--   {groupId}/promo.mp4     → video del grupo (sube el dueño)
--   avatars/{userId}.jpg    → foto personal de artista (cualquier usuario)
--
-- NOTA: Requiere que sql/23_fix_groups_rls_recursion.sql ya esté ejecutado
--       (necesita la función is_group_owner).
--
-- Ejecutar en: Supabase Dashboard → SQL Editor
-- ============================================================

-- ── 1. Asegurarse de que el bucket existe y es público ───────────────────────
INSERT INTO storage.buckets (id, name, public)
VALUES ('group-images', 'group-images', true)
ON CONFLICT (id) DO UPDATE SET public = true;

-- ── 2. Limpiar políticas anteriores (idempotente) ───────────────────────────
DROP POLICY IF EXISTS "group_images_public_read"   ON storage.objects;
DROP POLICY IF EXISTS "group_images_auth_insert"   ON storage.objects;
DROP POLICY IF EXISTS "group_images_auth_update"   ON storage.objects;
DROP POLICY IF EXISTS "group_images_auth_delete"   ON storage.objects;

-- ── 3. Lectura pública para todo el bucket ───────────────────────────────────
CREATE POLICY "group_images_public_read"
  ON storage.objects FOR SELECT
  TO public
  USING (bucket_id = 'group-images');

-- ── 4. Subida: cualquier usuario autenticado puede subir a su propia ruta ────
--    - Foto del grupo:  {groupId}/profile.jpg  (dueño del grupo)
--    - Avatar personal: avatars/{userId}.jpg   (cualquier usuario)
--
--    Regla: el archivo debe estar bajo una carpeta cuyo nombre sea
--    el UUID del usuario autenticado (avatars/) O el dueño lo valida con RPC.
--
--    Para simplificar y evitar recursión, usamos una regla amplia:
--    "cualquier usuario autenticado puede INSERT/UPDATE en su propio path".
--    La seguridad real viene del nombre de archivo que incluye el uid o group_id.

CREATE POLICY "group_images_auth_insert"
  ON storage.objects FOR INSERT
  TO authenticated
  WITH CHECK (
    bucket_id = 'group-images'
    AND (
      -- Avatar personal: avatars/{auth.uid()}.jpg
      name = 'avatars/' || auth.uid()::text || '.jpg'
      -- Foto/video del grupo: primer segmento es un UUID de grupo del usuario
      -- Guard: solo intentar el cast si NO empieza con 'avatars/'
      OR (
        name NOT LIKE 'avatars/%'
        AND public.is_group_owner((split_part(name, '/', 1))::uuid)
      )
    )
  );

CREATE POLICY "group_images_auth_update"
  ON storage.objects FOR UPDATE
  TO authenticated
  USING (
    bucket_id = 'group-images'
    AND (
      name = 'avatars/' || auth.uid()::text || '.jpg'
      OR (
        name NOT LIKE 'avatars/%'
        AND public.is_group_owner((split_part(name, '/', 1))::uuid)
      )
    )
  );

CREATE POLICY "group_images_auth_delete"
  ON storage.objects FOR DELETE
  TO authenticated
  USING (
    bucket_id = 'group-images'
    AND (
      name = 'avatars/' || auth.uid()::text || '.jpg'
      OR (
        name NOT LIKE 'avatars/%'
        AND public.is_group_owner((split_part(name, '/', 1))::uuid)
      )
    )
  );

-- ── 5. Verificación ──────────────────────────────────────────────────────────
SELECT policyname, cmd
FROM pg_policies
WHERE tablename = 'objects'
  AND schemaname = 'storage'
ORDER BY policyname;

SELECT 'Storage policies configuradas correctamente ✅' AS status;
