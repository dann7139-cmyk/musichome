-- 634_admin_payment_history_ROLLBACK.sql
BEGIN;
DROP FUNCTION IF EXISTS public.admin_get_payment_history(integer);
COMMIT;
