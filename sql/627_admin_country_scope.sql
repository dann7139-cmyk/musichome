-- sql/627_admin_country_scope.sql
--
-- Base para el plan aprobado de admin con alcance por país (memoria
-- project_scoped_admin_plan.md, 2026-08-28), ahora retomado a pedido del
-- usuario (2026-09-08). Fase 1: fundamento de esquema + helpers de
-- autorización — no toca ninguna pantalla ni función existente todavía.
--
-- Diseño elegido: rol NUEVO 'admin_ops' (no reutilizar 'admin' con un
-- campo opcional) — así CUALQUIER función/RLS que hoy exige
-- `role = 'admin'` sigue excluyendo automáticamente a las cuentas
-- admin_ops por defecto (denegar por defecto), y solo les damos acceso
-- explícito función por función, en migraciones futuras, filtrando por
-- país. Nadie con admin_ops puede ver ni consultar nada de otro país
-- por una llamada directa a la API, ni aunque conozca el nombre del RPC.
--
-- - profiles.role admite 'admin_ops' adicional a los 4 valores actuales.
-- - profiles.admin_country_scope: país de la cuenta admin_ops ('US' por
--   ahora; se amplía a 'CA' cuando el usuario contrate ahí). NULL para
--   todos los demás roles, incluida la cuenta admin completa.
-- - profiles.admin_muted_countries: SOLO para la cuenta admin completa
--   (role='admin') — países cuyas alertas/notificaciones ya NO quiere
--   recibir (para cuando el usuario active un trabajador y prefiera dejar
--   de enterarse él). Arranca vacío ('{}') = comportamiento actual sin
--   cambio alguno (ve y recibe todo, igual que hoy).
-- - is_platform_admin(): true solo para la cuenta admin completa.
-- - admin_ops_country(): el país de alcance si quien llama es admin_ops,
--   NULL en cualquier otro caso (incluida la cuenta admin completa).
BEGIN;

ALTER TABLE public.profiles
  DROP CONSTRAINT IF EXISTS profiles_role_check;

ALTER TABLE public.profiles
  ADD CONSTRAINT profiles_role_check
  CHECK (role IN ('admin', 'group', 'client', 'talent', 'admin_ops'));

ALTER TABLE public.profiles
  ADD COLUMN IF NOT EXISTS admin_country_scope TEXT NULL;

ALTER TABLE public.profiles
  DROP CONSTRAINT IF EXISTS profiles_admin_country_scope_check;

ALTER TABLE public.profiles
  ADD CONSTRAINT profiles_admin_country_scope_check
  CHECK (admin_country_scope IS NULL OR admin_country_scope IN ('US'));

ALTER TABLE public.profiles
  ADD COLUMN IF NOT EXISTS admin_muted_countries TEXT[] NOT NULL DEFAULT '{}';

CREATE OR REPLACE FUNCTION public.is_platform_admin(p_uid uuid DEFAULT auth.uid())
RETURNS boolean
LANGUAGE sql
STABLE SECURITY DEFINER
SET search_path TO 'public'
AS $function$
  SELECT EXISTS (
    SELECT 1 FROM public.profiles WHERE id = p_uid AND role = 'admin'
  );
$function$;

CREATE OR REPLACE FUNCTION public.admin_ops_country(p_uid uuid DEFAULT auth.uid())
RETURNS text
LANGUAGE sql
STABLE SECURITY DEFINER
SET search_path TO 'public'
AS $function$
  SELECT admin_country_scope FROM public.profiles
  WHERE id = p_uid AND role = 'admin_ops';
$function$;

COMMIT;
