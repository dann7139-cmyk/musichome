-- ROLLBACK de sql/669 — elimina la cola de reservas "held" para dar
-- anticipo antes del evento. No afecta admin_register_group_payment ni
-- ninguna función que mueva dinero, solo esta lectura nueva.

DROP FUNCTION IF EXISTS public.admin_get_upcoming_group_payments(integer);

SELECT '669_admin_upcoming_group_payments ROLLBACK ✅' AS status;
