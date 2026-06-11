-- ============================================================
-- sql/257_selfie_evidence_and_storage.sql
--
-- CAMBIOS:
--
--   1. selfie_url TEXT en verification_requests
--      Almacena el path (dentro del bucket verification-docs) de
--      la fotografía tomada por el responsable del grupo durante
--      el paso de "foto de verificación".
--
--   2. complete_verification_liveness — firma extendida
--      Agrega p_selfie_path TEXT DEFAULT NULL (backward compatible).
--      Llamadas existentes con 1 argumento siguen funcionando.
--      Llamadas nuevas con 2 argumentos guardan además el path
--      de la selfie en selfie_url.
--
--      IMPORTANTE sobre nomenclatura:
--      La columna liveness_verified=TRUE indica que se tomó y
--      subió una selfie. No implica detección biométrica de vida
--      (movimiento, parpadeo, profundidad). Si en el futuro se
--      integra un SDK de liveness real (FaceTec, AWS Rekognition,
--      etc.), se debe crear una columna separada para ese dato y
--      no reutilizar liveness_verified.
--
--   3. Storage policy — admin puede leer verification-docs
--      Permite a usuarios con role='admin' generar signed URLs
--      y leer objetos del bucket privado verification-docs para
--      revisar documentos e identidades antes de aprobar.
--
-- IDEMPOTENTE:
--   • ADD COLUMN IF NOT EXISTS → sí
--   • DROP FUNCTION IF EXISTS + CREATE OR REPLACE → sí
--   • DO/IF NOT EXISTS para la policy → sí
--
-- ROLLBACK:
--   ALTER TABLE public.verification_requests
--     DROP COLUMN IF EXISTS selfie_url;
--   DROP FUNCTION IF EXISTS
--     public.complete_verification_liveness(UUID, TEXT);
--   (Re-ejecutar sql/255a_fase1.sql restaura la versión de 1 arg)
--   DROP POLICY IF EXISTS "verification_docs_admin_select"
--     ON storage.objects;
-- ============================================================


-- ─────────────────────────────────────────────────────────────────────────────
-- § 1  Nueva columna selfie_url en verification_requests
-- ─────────────────────────────────────────────────────────────────────────────

ALTER TABLE public.verification_requests
  ADD COLUMN IF NOT EXISTS selfie_url TEXT;

COMMENT ON COLUMN public.verification_requests.selfie_url IS
  'Path en el bucket verification-docs de la selfie tomada '
  'por el responsable del grupo durante la verificación KYC. '
  'NULL si no se ha subido selfie. '
  'Complementa liveness_verified (booleano de estado). '
  'liveness_verified=TRUE + selfie_url=NULL ocurre en registros '
  'históricos creados antes de sql/257.';


-- ─────────────────────────────────────────────────────────────────────────────
-- § 2  complete_verification_liveness — firma extendida (backward compatible)
--
-- Se elimina explícitamente la versión de 1 parámetro para evitar
-- ambigüedad de overload. La nueva versión de 2 parámetros con
-- DEFAULT NULL es compatible con llamadas de 1 argumento:
--
--   -- Llamada antigua (sigue funcionando):
--   SELECT complete_verification_liveness(p_attempt_id => '...');
--
--   -- Llamada nueva (guarda selfie_url):
--   SELECT complete_verification_liveness(
--     p_attempt_id  => '...',
--     p_selfie_path => 'kyc_selfie_<group_id>_<ts>.jpg'
--   );
-- ─────────────────────────────────────────────────────────────────────────────

DROP FUNCTION IF EXISTS public.complete_verification_liveness(UUID);

CREATE OR REPLACE FUNCTION public.complete_verification_liveness(
  p_attempt_id  UUID,
  p_selfie_path TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_status   TEXT;
  v_owner_id UUID;
BEGIN
  SELECT vr.status, g.owner_id
  INTO   v_status, v_owner_id
  FROM   public.verification_requests vr
  JOIN   public.groups g ON g.id = vr.group_id
  WHERE  vr.id = p_attempt_id;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'attempt_not_found');
  END IF;

  IF v_owner_id IS DISTINCT FROM auth.uid() THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_owner');
  END IF;

  IF v_status <> 'draft' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'attempt_not_draft');
  END IF;

  UPDATE public.verification_requests
  SET
    liveness_verified = TRUE,
    -- selfie_url: actualiza solo si se pasa un path no vacío.
    -- Si p_selfie_path es NULL o cadena vacía, conserva el valor
    -- existente (no sobreescribe con NULL una selfie ya guardada).
    selfie_url = COALESCE(NULLIF(trim(p_selfie_path), ''), selfie_url)
  WHERE id = p_attempt_id;

  RETURN jsonb_build_object('ok', true);
END;
$$;

GRANT EXECUTE ON FUNCTION public.complete_verification_liveness(UUID, TEXT)
  TO authenticated;


-- ─────────────────────────────────────────────────────────────────────────────
-- § 3  Storage policy — admin puede leer verification-docs
-- ─────────────────────────────────────────────────────────────────────────────

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE  policyname = 'verification_docs_admin_select'
      AND  tablename  = 'objects'
      AND  schemaname = 'storage'
  ) THEN
    EXECUTE $p$
      CREATE POLICY "verification_docs_admin_select"
        ON storage.objects
        FOR SELECT
        TO authenticated
        USING (
          bucket_id = 'verification-docs'
          AND EXISTS (
            SELECT 1 FROM public.profiles
            WHERE  id   = auth.uid()
              AND  role = 'admin'
          )
        );
    $p$;
    RAISE NOTICE '[257] Política verification_docs_admin_select creada ✅';
  ELSE
    RAISE NOTICE '[257] Política verification_docs_admin_select ya existía — sin cambios ✅';
  END IF;
END;
$$;


-- ─────────────────────────────────────────────────────────────────────────────
-- § 4  Verificación
-- ─────────────────────────────────────────────────────────────────────────────

DO $$
DECLARE
  v_col_exists    BOOLEAN;
  v_fn_2arg       BOOLEAN;
  v_fn_1arg       BOOLEAN;
  v_policy_exists BOOLEAN;
BEGIN
  -- 1. selfie_url existe en verification_requests
  SELECT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE  table_schema = 'public'
      AND  table_name   = 'verification_requests'
      AND  column_name  = 'selfie_url'
  ) INTO v_col_exists;

  IF NOT v_col_exists THEN
    RAISE EXCEPTION '[257] selfie_url no encontrada en verification_requests ❌';
  END IF;
  RAISE NOTICE '[257] verification_requests.selfie_url: existe ✅';

  -- 2. La versión de 2 parámetros existe
  SELECT EXISTS (
    SELECT 1 FROM pg_proc p
    JOIN   pg_namespace ns ON ns.oid = p.pronamespace
    WHERE  ns.nspname = 'public'
      AND  proname    = 'complete_verification_liveness'
      AND  pronargs   = 2
  ) INTO v_fn_2arg;

  IF NOT v_fn_2arg THEN
    RAISE EXCEPTION '[257] complete_verification_liveness(UUID, TEXT) no encontrada ❌';
  END IF;
  RAISE NOTICE '[257] complete_verification_liveness(UUID, TEXT): existe ✅';

  -- 3. La versión de 1 parámetro ya no existe (evita ambigüedad)
  SELECT EXISTS (
    SELECT 1 FROM pg_proc p
    JOIN   pg_namespace ns ON ns.oid = p.pronamespace
    WHERE  ns.nspname = 'public'
      AND  proname    = 'complete_verification_liveness'
      AND  pronargs   = 1
  ) INTO v_fn_1arg;

  IF v_fn_1arg THEN
    RAISE EXCEPTION '[257] complete_verification_liveness(UUID) todavía existe — DROP no se aplicó ❌';
  END IF;
  RAISE NOTICE '[257] complete_verification_liveness(UUID) eliminada: sin overload ambiguo ✅';

  -- 4. La policy de storage existe
  SELECT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE  policyname = 'verification_docs_admin_select'
      AND  tablename  = 'objects'
      AND  schemaname = 'storage'
  ) INTO v_policy_exists;

  IF NOT v_policy_exists THEN
    RAISE EXCEPTION '[257] Política verification_docs_admin_select no encontrada ❌';
  END IF;
  RAISE NOTICE '[257] Política verification_docs_admin_select: existe ✅';

  RAISE NOTICE '[257] Todas las verificaciones pasaron ✅';
END;
$$;


SELECT '257_selfie_evidence_and_storage.sql aplicado correctamente ✅' AS status;
