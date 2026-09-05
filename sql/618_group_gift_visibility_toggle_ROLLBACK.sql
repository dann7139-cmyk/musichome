-- 618_group_gift_visibility_toggle_ROLLBACK.sql
ALTER TABLE public.groups DROP COLUMN IF EXISTS show_gifts_to_members;
