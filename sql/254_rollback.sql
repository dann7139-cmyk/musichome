-- ============================================================
-- sql/254_rollback.sql
--
-- Revierte sql/254_compute_eligibility_functions.sql
--
-- IMPACTO:
--   Elimina las funciones compute_*. Cualquier RPC o trigger
--   que las llame fallará hasta que se re-aplique sql/254.
--   Sin pérdida de datos (las funciones son de solo lectura).
--
-- PRECONDICIÓN:
--   Si sql/255 ya fue aplicado, sus RPCs dependen de estas
--   funciones. En ese caso, revertir sql/254 romperá sql/255.
--   Verificar que sql/255 no esté aplicado antes de ejecutar.
-- ============================================================

DROP FUNCTION IF EXISTS public.compute_group_eligibility(UUID);
DROP FUNCTION IF EXISTS public.compute_profile_eligibility(UUID);

SELECT '254_rollback.sql aplicado — compute_* eliminadas ✅' AS status;
