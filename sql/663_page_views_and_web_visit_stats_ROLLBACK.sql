-- ROLLBACK de sql/663_page_views_and_web_visit_stats.sql
DROP FUNCTION IF EXISTS public.get_web_visit_stats();
DROP TABLE IF EXISTS public.page_views;
