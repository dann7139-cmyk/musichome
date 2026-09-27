-- ═══════════════════════════════════════════════════════════════════════════
-- ROLLBACK de 699 — borra las envolturas de autorización de la Etapa 2.5
-- ═══════════════════════════════════════════════════════════════════════════
-- ⚠️  NO CORRER si `700` ya está aplicado: sin las envolturas y con las
-- primitivas revocadas, el proveedor se queda sin poder validar el código de
-- inicio, sin marcar llegada y sin liberar su pago. El orden seguro de reversión
-- es primero el ROLLBACK de 700 y solo después este.
--
-- Son funciones NUEVAS y nada del proyecto las llama todavía: borrarlas no
-- afecta datos ni a ninguna función preexistente.
-- ═══════════════════════════════════════════════════════════════════════════

BEGIN;

DROP FUNCTION IF EXISTS public.group_release_earnings(UUID);
DROP FUNCTION IF EXISTS public.group_confirm_arrival(UUID, DOUBLE PRECISION, DOUBLE PRECISION);
DROP FUNCTION IF EXISTS public.group_validate_start_code(UUID, TEXT);
DROP FUNCTION IF EXISTS public.reservation_group_if_owner(UUID);

NOTIFY pgrst, 'reload schema';

COMMIT;
