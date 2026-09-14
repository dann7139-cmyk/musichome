-- ============================================================================
-- ROLLBACK sql/649_provider_applications.sql
--
-- ⚠️ NO correr salvo emergencia deliberada. Borra la tabla de solicitudes
-- (incluye el historial de aprobadas/rechazadas) y las 4 funciones. NO
-- borra ningún auth.users/profiles/groups ya creados por aprobaciones
-- previas — esas cuentas quedan intactas, solo se pierde la fila de
-- provider_applications que las originó (linked_group_id se pierde).
-- ============================================================================

DROP FUNCTION IF EXISTS public.admin_approve_provider_application(uuid, text, text, text);
DROP FUNCTION IF EXISTS public.admin_reject_provider_application(uuid, text);
DROP FUNCTION IF EXISTS public.admin_get_provider_applications(text);
DROP FUNCTION IF EXISTS public.submit_provider_application(text, text, text, integer, numeric, text, text, text, text);

DROP TABLE IF EXISTS public.provider_applications;

-- 'provider_application' se queda en notifications_type_check (quitar un
-- valor del CHECK es innecesario y podría romper notificaciones históricas
-- si alguna quedó guardada con ese tipo).
