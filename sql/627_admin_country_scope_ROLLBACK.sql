-- 627_admin_country_scope_ROLLBACK.sql
BEGIN;

DROP FUNCTION IF EXISTS public.admin_ops_country(uuid);
DROP FUNCTION IF EXISTS public.is_platform_admin(uuid);

ALTER TABLE public.profiles
  DROP COLUMN IF EXISTS admin_muted_countries;

ALTER TABLE public.profiles
  DROP CONSTRAINT IF EXISTS profiles_admin_country_scope_check;

ALTER TABLE public.profiles
  DROP COLUMN IF EXISTS admin_country_scope;

ALTER TABLE public.profiles
  DROP CONSTRAINT IF EXISTS profiles_role_check;

ALTER TABLE public.profiles
  ADD CONSTRAINT profiles_role_check
  CHECK (role IN ('admin', 'group', 'client', 'talent'));

COMMIT;
