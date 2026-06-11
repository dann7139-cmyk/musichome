-- ============================================================
-- sql/253_verify.sql
--
-- Checklist de verificación post-deploy de sql/253.
-- Ejecutar en Supabase SQL Editor como service_role o postgres.
-- Todos los resultados deben mostrar ✅. Cualquier ❌ indica
-- que el deploy no se aplicó correctamente.
-- ============================================================

-- ── CHECK 1: Policy verreq_group_insert restringe status ─────────────────────
SELECT
  CASE
    WHEN with_check LIKE '%draft%' AND with_check LIKE '%pending%'
    THEN '✅ verreq_group_insert: status limitado a draft/pending'
    ELSE '❌ verreq_group_insert: WITH CHECK no tiene la restricción esperada'
  END AS resultado
FROM pg_policies
WHERE tablename  = 'verification_requests'
  AND policyname = 'verreq_group_insert';

-- ── CHECK 2: Columna liveness_verified existe con DEFAULT FALSE ───────────────
SELECT
  CASE
    WHEN COUNT(*) = 1
    THEN '✅ liveness_verified: columna existe, tipo BOOLEAN, default FALSE'
    ELSE '❌ liveness_verified: columna no encontrada'
  END AS resultado
FROM information_schema.columns
WHERE table_schema    = 'public'
  AND table_name      = 'verification_requests'
  AND column_name     = 'liveness_verified'
  AND data_type       = 'boolean'
  AND column_default  = 'false';

-- ── CHECK 3: CHECK constraint incluye los cuatro valores válidos ──────────────
SELECT
  CASE
    WHEN def LIKE '%draft%'
     AND def LIKE '%pending%'
     AND def LIKE '%approved%'
     AND def LIKE '%rejected%'
    THEN '✅ CHECK status: incluye draft, pending, approved, rejected'
    ELSE '❌ CHECK status: definición inesperada → ' || def
  END AS resultado
FROM (
  SELECT pg_get_constraintdef(oid) AS def
  FROM pg_constraint
  WHERE conrelid = 'public.verification_requests'::regclass
    AND conname   = 'verification_requests_status_check'
) sub;

-- ── CHECK 4: Índice idx_vr_group_submitted existe ────────────────────────────
SELECT
  CASE
    WHEN COUNT(*) = 1
    THEN '✅ idx_vr_group_submitted: índice creado'
    ELSE '❌ idx_vr_group_submitted: índice no encontrado'
  END AS resultado
FROM pg_indexes
WHERE tablename = 'verification_requests'
  AND indexname = 'idx_vr_group_submitted';

-- ── CHECK 5: No existen filas con status='draft' (no debería haberlas aún) ───
SELECT
  CASE
    WHEN COUNT(*) = 0
    THEN '✅ Sin filas draft: estado de datos esperado'
    ELSE '⚠️  Existen ' || COUNT(*) || ' filas con status=draft — revisar si son esperadas'
  END AS resultado
FROM public.verification_requests
WHERE status = 'draft';

-- ── CHECK 6: Distribución de status en datos existentes ──────────────────────
-- Resultado informativo — todos los valores deben ser pending/approved/rejected
SELECT
  status,
  COUNT(*) AS cantidad,
  CASE
    WHEN status IN ('pending', 'approved', 'rejected', 'draft')
    THEN '✅'
    ELSE '❌ valor inesperado'
  END AS valido
FROM public.verification_requests
GROUP BY status
ORDER BY status;

-- ── CHECK 7: RLS está habilitado en la tabla ──────────────────────────────────
SELECT
  CASE
    WHEN rowsecurity = TRUE
    THEN '✅ RLS habilitado en verification_requests'
    ELSE '❌ RLS deshabilitado — verificar sql/03_rls_policies.sql'
  END AS resultado
FROM pg_tables
WHERE schemaname = 'public'
  AND tablename  = 'verification_requests';

-- ── CHECK 8: Las tres policies originales siguen existiendo ──────────────────
SELECT
  policyname,
  cmd,
  CASE
    WHEN policyname IN ('verreq_group_own', 'verreq_group_insert', 'verreq_admin_all')
    THEN '✅'
    ELSE '⚠️  policy inesperada'
  END AS estado
FROM pg_policies
WHERE tablename = 'verification_requests'
ORDER BY policyname;

-- ── PRUEBA DE SEGURIDAD (solo ejecutar como usuario autenticado no-admin) ─────
-- Las siguientes queries deben fallar con error de RLS si se ejecutan
-- como un authenticated user que es owner de algún grupo:
--
-- DEBE FALLAR (auto-aprobación bloqueada):
--   INSERT INTO verification_requests(group_id, status)
--   VALUES ('<tu_group_id>', 'approved');
--   → Error esperado: new row violates row-level security policy
--
-- DEBE FALLAR (rechazo directo bloqueado):
--   INSERT INTO verification_requests(group_id, status)
--   VALUES ('<tu_group_id>', 'rejected');
--   → Error esperado: new row violates row-level security policy
--
-- DEBE FUNCIONAR (submit legítimo):
--   INSERT INTO verification_requests(group_id, status, submitted_at)
--   VALUES ('<tu_group_id>', 'pending', NOW());
--   → Debe insertar 1 fila correctamente
--
-- LIMPIAR después de la prueba:
--   DELETE FROM verification_requests
--   WHERE group_id = '<tu_group_id>' AND status = 'pending'
--   AND submitted_at > NOW() - INTERVAL '5 minutes';
