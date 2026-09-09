-- 632_admin_set_muted_countries_ROLLBACK.sql
BEGIN;
DROP FUNCTION IF EXISTS public.admin_set_muted_countries(text[]);
COMMIT;
