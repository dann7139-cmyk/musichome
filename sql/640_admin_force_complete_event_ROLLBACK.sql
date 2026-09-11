-- sql/640_admin_force_complete_event_ROLLBACK.sql
BEGIN;
DROP FUNCTION IF EXISTS public.admin_force_complete_event(uuid, text);
COMMIT;

SELECT '640_admin_force_complete_event_ROLLBACK.sql ejecutado ✅' AS status;
