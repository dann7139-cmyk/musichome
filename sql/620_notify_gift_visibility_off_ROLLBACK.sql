-- 620_notify_gift_visibility_off_ROLLBACK.sql
DROP TRIGGER IF EXISTS trg_notify_gift_visibility_off ON public.groups;
DROP FUNCTION IF EXISTS public.notify_gift_visibility_off();
