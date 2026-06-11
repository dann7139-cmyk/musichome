-- ============================================================
-- sql/255_rollback.sql
--
-- Revierte sql/255.sql en orden inverso.
--
-- Fase 3 rollback (si Fase 3 fue ejecutada):
--   Restaura el GRANT irrestricto en groups y el trigger.
--   ⚠️  Si se restaura el trigger, el frontend legacy vuelve a funcionar.
--
-- Fase 1 rollback:
--   Elimina RPCs nuevas e índices parciales.
--   Los datos deduplicados NO se restauran (irreversible).
-- ============================================================

-- ══════════════════════════════════════════════════════════════
-- ROLLBACK FASE 3 (ejecutar solo si Fase 3 fue aplicada)
-- ══════════════════════════════════════════════════════════════

-- Restaurar GRANT irrestricto en groups
GRANT UPDATE ON public.groups TO authenticated;

-- Restaurar trigger sync_verification_status
CREATE OR REPLACE FUNCTION public.sync_group_verification()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY INVOKER
AS $$
BEGIN
  IF NEW.status = 'pending' THEN
    UPDATE public.groups
    SET    verification_status = 'pending'
    WHERE  id = NEW.group_id;
  ELSIF NEW.status = 'approved' THEN
    UPDATE public.groups
    SET    verification_status = 'approved',
           is_verified         = TRUE
    WHERE  id = NEW.group_id;
  ELSIF NEW.status = 'rejected' THEN
    UPDATE public.groups
    SET    verification_status = 'rejected',
           is_verified         = FALSE
    WHERE  id = NEW.group_id;
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS sync_verification_status ON public.verification_requests;
CREATE TRIGGER sync_verification_status
  AFTER INSERT OR UPDATE OF status ON public.verification_requests
  FOR EACH ROW
  EXECUTE FUNCTION public.sync_group_verification();


-- ══════════════════════════════════════════════════════════════
-- ROLLBACK FASE 1
-- ══════════════════════════════════════════════════════════════

-- Eliminar RPCs nuevas
DROP FUNCTION IF EXISTS public.start_group_verification(UUID);
DROP FUNCTION IF EXISTS public.update_verification_document(UUID, TEXT);
DROP FUNCTION IF EXISTS public.complete_verification_liveness(UUID);
DROP FUNCTION IF EXISTS public.submit_verification_request(UUID);
DROP FUNCTION IF EXISTS public.admin_review_group_verification(UUID, BOOLEAN, TEXT);
DROP FUNCTION IF EXISTS public.admin_review_profile_verification(UUID, BOOLEAN, TEXT);
DROP FUNCTION IF EXISTS public.evaluate_group_verification(UUID);
DROP FUNCTION IF EXISTS public.evaluate_profile_verification(UUID);

-- Eliminar índices parciales
DROP INDEX IF EXISTS public.uidx_vr_group_pending;
DROP INDEX IF EXISTS public.uidx_vr_group_draft;

-- Nota: los datos eliminados por la deduplicación (F1-1) NO se restauran.
-- Si necesitas restaurarlos, usa un backup previo a la ejecución de 255.sql.

SELECT '255_rollback.sql ejecutado — ADVERTENCIA: los datos deduplicados son irreversibles ✅' AS status;
