-- ═══════════════════════════════════════════════════════════════════════════
-- ROLLBACK de 696 — borra las 4 RPCs nuevas de la Etapa 2
-- ═══════════════════════════════════════════════════════════════════════════
-- ⚠️  NO CORRER si `697` ya está aplicado: sin estas RPCs y sin el UPDATE
-- directo, el cliente se quedaría sin forma de guardar ubicación ni reprogramar,
-- y el proveedor sin forma de aceptar/rechazar. El orden seguro de reversión es
-- primero el ROLLBACK de 697 y solo después este.
--
-- Son funciones NUEVAS: borrarlas no puede afectar datos ni a ninguna función
-- preexistente. Ninguna otra función del proyecto las llama.
-- ═══════════════════════════════════════════════════════════════════════════

BEGIN;

DROP FUNCTION IF EXISTS public.client_set_booking_location(UUID, TEXT, TEXT);
DROP FUNCTION IF EXISTS public.client_reschedule_reservation(UUID, DATE);
DROP FUNCTION IF EXISTS public.group_accept_booking(UUID);
DROP FUNCTION IF EXISTS public.group_decline_booking(UUID);

NOTIFY pgrst, 'reload schema';

COMMIT;
