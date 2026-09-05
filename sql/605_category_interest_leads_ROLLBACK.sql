-- ROLLBACK de sql/605_category_interest_leads.sql
-- Solo correr en emergencia deliberada. Borra la tabla y los leads en ella.

BEGIN;

DROP FUNCTION IF EXISTS public.mark_category_interest_contacted(UUID);
DROP FUNCTION IF EXISTS public.request_category_interest(TEXT, TEXT[], TEXT, TEXT);
DROP TABLE IF EXISTS public.category_interest_requests;

COMMIT;
