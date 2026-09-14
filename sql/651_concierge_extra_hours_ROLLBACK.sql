-- ============================================================================
-- ROLLBACK sql/651_concierge_extra_hours.sql
-- ⚠️ NO correr salvo emergencia deliberada. No borra ninguna fila de
-- extra_hours ya creada por estas funciones — esos registros quedan
-- intactos, solo se quita la capacidad de crear nuevos así.
-- ============================================================================

DROP FUNCTION IF EXISTS public.admin_propose_extra_hours(uuid, numeric, numeric, text);
DROP FUNCTION IF EXISTS public.admin_get_concierge_live_reservations(integer);
