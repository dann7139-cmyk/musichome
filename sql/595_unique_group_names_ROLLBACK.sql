-- Rollback de sql/595 — quita la restricción de nombre único de grupo.
BEGIN;
DROP INDEX IF EXISTS public.groups_name_unique_ci;
COMMIT;
SELECT '595_unique_group_names_ROLLBACK ✅' AS status;
