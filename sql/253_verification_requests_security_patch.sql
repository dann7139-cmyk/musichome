-- ============================================================
-- sql/253_verification_requests_security_patch.sql
--
-- OBJETIVO: Parche de seguridad y estabilización de
-- verification_requests. No es una refactorización del flujo
-- KYC — eso llegará en sql/255 mediante RPCs.
--
-- CAMBIOS:
--   1. verreq_group_insert — limita status a ('draft','pending').
--      Cierra la vulnerabilidad de autoaprobación confirmada:
--      un owner podía insertar status='approved', disparar el
--      trigger sync_verification_status y obtener is_verified=TRUE
--      sin revisión admin.
--
--   2. ADD COLUMN liveness_verified — la columna ya es leída por
--      VerificationScreen (req?.liveness_verified) pero no existía
--      en DB. Los upserts de liveness fallaban silenciosamente.
--
--   3. CHECK status — amplía el constraint para incluir 'draft'.
--      Los upserts de subida de documento usaban status='draft'
--      pero el CHECK los rechazaba en silencio.
--
--   4. Índice en (group_id, submitted_at DESC) — cubre la query
--      de lectura de VerificationScreen y AdminDashboard.
--
-- COMPATIBILIDAD:
--   Sin cambios de frontend requeridos para este deploy.
--   Sin cambios en UNIQUE constraints ni en el modelo de filas.
--   Sin triggers nuevos. Sin columnas de historial.
--
-- PROBLEMAS QUE SIGUEN ABIERTOS DESPUÉS DE sql/253:
--   - document_url no se propaga al submit: la fila con
--     status='pending' se crea sin document_url porque el upsert
--     no hace UPDATE (sin UNIQUE(group_id), crea nueva fila).
--     fetchData lee la fila más reciente (pending) que tiene
--     document_url=NULL. Los docs están en storage pero sin
--     referencia persistente en la fila que el admin lee.
--   - liveness_verified no se propaga al submit: misma causa.
--     La fila del submit no lleva ese valor.
--   - El patrón de upsert sigue creando múltiples filas por grupo.
--   - La solución completa llega en sql/255: RPCs que gestionan
--     una única fila por intento con UPDATE explícito por id.
--
-- VULNERABILIDAD CERRADA:
--   Antes: owner podía → INSERT {group_id, status:'approved'}
--          → trigger sync_group_verification se dispara
--          → UPDATE groups SET is_verified=TRUE
--   Después: la nueva WITH CHECK bloquea status='approved' y
--            status='rejected' desde contexto authenticated.
--
-- ROLLBACK: sql/253_rollback.sql
-- ============================================================

-- ── 1. Cerrar vulnerabilidad de autoaprobación ────────────────────────────────
--
-- La policy anterior solo verificaba ownership. Permitía insertar
-- cualquier valor de status, incluyendo 'approved'.

DROP POLICY IF EXISTS "verreq_group_insert" ON public.verification_requests;

CREATE POLICY "verreq_group_insert"
  ON public.verification_requests
  FOR INSERT
  TO authenticated
  WITH CHECK (
    EXISTS (
      SELECT 1 FROM public.groups
      WHERE id = group_id AND owner_id = auth.uid()
    )
    AND status IN ('draft', 'pending')
  );

-- ── 2. Columna liveness_verified ─────────────────────────────────────────────
--
-- VerificationScreen:202 lee req?.liveness_verified para restaurar
-- el estado entre sesiones. La columna no existía — el campo
-- retornaba undefined y livenessComplete se reseteaba siempre.

ALTER TABLE public.verification_requests
  ADD COLUMN IF NOT EXISTS liveness_verified BOOLEAN NOT NULL DEFAULT FALSE;

-- ── 3. Ampliar CHECK de status para incluir 'draft' ──────────────────────────
--
-- VerificationScreen:239 y :280 hacen upsert con status='draft'.
-- El CHECK anterior los rechazaba silenciosamente.
-- Con este cambio, esos upserts crean filas draft válidas.
-- Nota: sin UNIQUE(group_id), los upserts siguen siendo INSERTs
-- (crean nueva fila cada vez en lugar de actualizar la existente).
-- Ese comportamiento se corrige en sql/255.

ALTER TABLE public.verification_requests
  DROP CONSTRAINT IF EXISTS verification_requests_status_check;

ALTER TABLE public.verification_requests
  ADD CONSTRAINT verification_requests_status_check
    CHECK (status IN ('draft', 'pending', 'approved', 'rejected'));

-- ── 4. Índice de rendimiento ──────────────────────────────────────────────────
--
-- Cubre:
--   VerificationScreen:   WHERE group_id = X ORDER BY submitted_at DESC LIMIT 1
--   AdminDashboard:       WHERE status = 'pending' (parcialmente)
--   GroupsScreen admin:   WHERE group_id = X ORDER BY submitted_at DESC LIMIT 10

CREATE INDEX IF NOT EXISTS idx_vr_group_submitted
  ON public.verification_requests (group_id, submitted_at DESC);

-- ── Verificación ──────────────────────────────────────────────────────────────

DO $$
DECLARE
  v_policy_check  TEXT;
  v_col_exists    BOOLEAN;
  v_check_def     TEXT;
  v_index_exists  BOOLEAN;
BEGIN
  -- 1. Policy WITH CHECK incluye status IN ('draft','pending')
  SELECT with_check INTO v_policy_check
  FROM pg_policies
  WHERE tablename = 'verification_requests'
    AND policyname = 'verreq_group_insert';

  IF v_policy_check IS NULL THEN
    RAISE EXCEPTION '[253] verreq_group_insert policy no encontrada ❌';
  END IF;
  IF v_policy_check NOT LIKE '%draft%' OR v_policy_check NOT LIKE '%pending%' THEN
    RAISE EXCEPTION '[253] verreq_group_insert no restringe status correctamente ❌';
  END IF;
  RAISE NOTICE '[253] verreq_group_insert: status limitado a draft/pending ✅';

  -- 2. Columna liveness_verified existe
  SELECT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name   = 'verification_requests'
      AND column_name  = 'liveness_verified'
  ) INTO v_col_exists;

  IF NOT v_col_exists THEN
    RAISE EXCEPTION '[253] liveness_verified column no encontrada ❌';
  END IF;
  RAISE NOTICE '[253] liveness_verified: columna existe ✅';

  -- 3. CHECK constraint incluye 'draft'
  SELECT pg_get_constraintdef(oid) INTO v_check_def
  FROM pg_constraint
  WHERE conrelid = 'public.verification_requests'::regclass
    AND conname   = 'verification_requests_status_check';

  IF v_check_def IS NULL OR v_check_def NOT LIKE '%draft%' THEN
    RAISE EXCEPTION '[253] CHECK constraint no incluye draft ❌';
  END IF;
  RAISE NOTICE '[253] CHECK status: incluye draft ✅';

  -- 4. Índice existe
  SELECT EXISTS (
    SELECT 1 FROM pg_indexes
    WHERE tablename = 'verification_requests'
      AND indexname = 'idx_vr_group_submitted'
  ) INTO v_index_exists;

  IF NOT v_index_exists THEN
    RAISE EXCEPTION '[253] idx_vr_group_submitted no encontrado ❌';
  END IF;
  RAISE NOTICE '[253] idx_vr_group_submitted: índice creado ✅';

  -- 5. Filas existentes siguen siendo válidas (ninguna tiene status='draft')
  IF EXISTS (SELECT 1 FROM public.verification_requests WHERE status = 'draft') THEN
    RAISE WARNING '[253] Existen filas con status=draft antes del deploy — revisar';
  ELSE
    RAISE NOTICE '[253] Filas existentes: ninguna con status=draft ✅';
  END IF;

END;
$$;

SELECT '253_verification_requests_security_patch.sql aplicado correctamente ✅' AS status;
