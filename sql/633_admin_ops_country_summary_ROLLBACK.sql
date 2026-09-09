-- 633_admin_ops_country_summary_ROLLBACK.sql
BEGIN;
DROP FUNCTION IF EXISTS public.admin_ops_country_summary(date, date);
COMMIT;
