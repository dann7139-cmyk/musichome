-- ============================================================
-- sql/527_admin_pending_group_payments_ROLLBACK.sql
-- Revierte sql/527_admin_pending_group_payments.sql
--
-- Elimina la RPC de solo lectura de la Fase P1B. No hay tablas, datos ni
-- triggers que revertir — la función nunca escribió nada.
-- Solo correr en caso de reversión deliberada de la Fase P1B.
-- ============================================================

BEGIN;

DROP FUNCTION IF EXISTS public.admin_get_pending_group_payments(integer);

COMMIT;

SELECT '527_admin_pending_group_payments_ROLLBACK ✅ — RPC eliminada' AS status;
