-- sql/646_allow_ca_admin_scope.sql
--
-- Petición del usuario (2026-09-11): "mi cuenta de méxico que yo vea todo
-- recuerda, pero por si tengo grupos deja lista la cuenta de admin para
-- canadá." — SOLO infraestructura, NO se crea ni asigna ninguna cuenta
-- admin_ops para Canadá todavía (no hay grupos reales ahí aún).
--
-- profiles.admin_country_scope solo aceptaba 'US' (sql/627). Se amplía
-- el CHECK para permitir también 'CA'. admin_ops_country() (sql/627) y
-- todas las funciones que la usan ya son genéricas — comparan
-- `country_code_of(...) = admin_ops_country()` sin hardcodear 'US' en
-- ningún lado — así que no hace falta tocar ninguna otra función: el día
-- que se asigne role='admin_ops' + admin_country_scope='CA' a una cuenta,
-- automáticamente funciona igual que la cuenta de EE.UU.
--
-- El admin completo (role='admin', la cuenta de México) sigue viendo y
-- pudiendo actuar sobre TODOS los países sin excepción, como siempre —
-- esto no cambia nada de su alcance.
BEGIN;

ALTER TABLE public.profiles DROP CONSTRAINT IF EXISTS profiles_admin_country_scope_check;
ALTER TABLE public.profiles ADD CONSTRAINT profiles_admin_country_scope_check
  CHECK (admin_country_scope IS NULL OR admin_country_scope IN ('US','CA'));

COMMIT;

-- ── VERIFICACIÓN ────────────────────────────────────────────
SELECT conname, pg_get_constraintdef(oid) FROM pg_constraint
WHERE conname = 'profiles_admin_country_scope_check';
-- Esperado: CHECK ... IN ('US'::text, 'CA'::text)

SELECT '646_allow_ca_admin_scope.sql ejecutado ✅' AS status;
