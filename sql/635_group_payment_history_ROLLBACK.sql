-- 635_group_payment_history_ROLLBACK.sql
BEGIN;
DROP FUNCTION IF EXISTS public.group_get_payment_history(integer);
COMMIT;
