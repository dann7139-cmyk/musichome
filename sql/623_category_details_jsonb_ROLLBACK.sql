-- 623_category_details_jsonb_ROLLBACK.sql
ALTER TABLE public.groups DROP COLUMN IF EXISTS category_details;
ALTER TABLE public.quotes DROP COLUMN IF EXISTS category_details;
