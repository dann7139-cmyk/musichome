-- sql/646_allow_ca_admin_scope_ROLLBACK.sql
-- Revierte sql/646: regresa el CHECK a solo aceptar 'US'. Falla si ya
-- existe algún perfil con admin_country_scope='CA' — hay que quitarle
-- el scope a esa cuenta primero.
BEGIN;

ALTER TABLE public.profiles DROP CONSTRAINT IF EXISTS profiles_admin_country_scope_check;
ALTER TABLE public.profiles ADD CONSTRAINT profiles_admin_country_scope_check
  CHECK (admin_country_scope IS NULL OR admin_country_scope IN ('US'));

COMMIT;

SELECT '646_allow_ca_admin_scope_ROLLBACK.sql ejecutado ✅' AS status;
