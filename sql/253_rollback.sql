-- ============================================================
-- sql/253_rollback.sql
--
-- Revierte sql/253_verification_requests_security_patch.sql
--
-- ADVERTENCIA CRÍTICA:
--   Revertir este archivo RE-ABRE la vulnerabilidad de
--   autoaprobación. Un owner podrá volver a insertar
--   status='approved' y disparar sync_verification_status.
--   Solo ejecutar si sql/253 produce un comportamiento
--   inesperado que requiera rollback urgente.
--
-- PRECONDICIÓN:
--   Si entre el deploy de sql/253 y este rollback se crearon
--   filas con status='draft', el rollback del CHECK fallará
--   porque esas filas violarían el constraint original.
--   Verificar primero:
--     SELECT COUNT(*) FROM verification_requests WHERE status = 'draft';
--   Si el resultado es > 0, eliminar esas filas antes de revertir:
--     DELETE FROM verification_requests WHERE status = 'draft';
--
-- IMPACTO DEL ROLLBACK:
--   - La vulnerabilidad de autoaprobación vuelve a estar activa.
--   - liveness_verified desaparece como columna (si se usa DROP).
--   - 'draft' deja de ser un status válido.
--   - El índice se elimina (degradación de rendimiento menor).
--   - Sin pérdida de datos en filas 'pending'/'approved'/'rejected'.
-- ============================================================

-- Paso 0: verificar que no existen filas draft antes de revertir CHECK
DO $$
DECLARE v_draft_count INT;
BEGIN
  SELECT COUNT(*) INTO v_draft_count
  FROM public.verification_requests WHERE status = 'draft';
  IF v_draft_count > 0 THEN
    RAISE EXCEPTION
      '[253_rollback] Existen % filas con status=draft. '
      'Elimínalas antes de revertir el CHECK constraint.',
      v_draft_count;
  END IF;
  RAISE NOTICE '[253_rollback] Sin filas draft — rollback seguro ✅';
END;
$$;

-- ── 4. Eliminar índice ────────────────────────────────────────────────────────

DROP INDEX IF EXISTS public.idx_vr_group_submitted;

-- ── 3. Revertir CHECK constraint ─────────────────────────────────────────────

ALTER TABLE public.verification_requests
  DROP CONSTRAINT IF EXISTS verification_requests_status_check;

ALTER TABLE public.verification_requests
  ADD CONSTRAINT verification_requests_status_check
    CHECK (status IN ('pending', 'approved', 'rejected'));

-- ── 2. Eliminar columna liveness_verified ────────────────────────────────────
--
-- Nota: solo eliminar si ningún código en producción la referencia.
-- Si se prefiere conservar la columna, comentar estas líneas.

ALTER TABLE public.verification_requests
  DROP COLUMN IF EXISTS liveness_verified;

-- ── 1. Restaurar policy verreq_group_insert sin restricción de status ─────────
--
-- ADVERTENCIA: esto re-abre la vulnerabilidad de autoaprobación.

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
  );

SELECT '253_rollback.sql aplicado — verificar estado de seguridad ⚠️' AS status;
