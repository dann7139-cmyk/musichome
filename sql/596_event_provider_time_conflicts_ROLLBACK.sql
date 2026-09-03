-- ============================================================
-- sql/596_event_provider_time_conflicts_ROLLBACK.sql
-- JAMÁS correr salvo emergencia deliberada.
-- Revierte sql/596: elimina client_get_event_time_conflicts().
-- No hay tablas ni columnas nuevas que revertir — solo la función.
-- ============================================================

BEGIN;

DROP FUNCTION IF EXISTS public.client_get_event_time_conflicts(UUID, UUID);

COMMIT;

SELECT '596_event_provider_time_conflicts — REVERTIDO' AS status;
