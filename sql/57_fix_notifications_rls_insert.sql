-- ════════════════════════════════════════════════════════════════════
-- 57_fix_notifications_rls_insert.sql
-- Permite que cualquier usuario autenticado inserte notificaciones
-- para OTROS usuarios (grupo notifica al cliente, etc.)
-- Sin esto, los inserts donde user_id != auth.uid() fallan silenciosamente.
-- ════════════════════════════════════════════════════════════════════

-- Eliminar política restrictiva anterior (si existe)
DROP POLICY IF EXISTS "Authenticated users can insert notifications" ON public.notifications;
DROP POLICY IF EXISTS "system_can_insert_notifications" ON public.notifications;
DROP POLICY IF EXISTS "users_insert_notifications" ON public.notifications;
DROP POLICY IF EXISTS "authenticated_can_insert_notifications" ON public.notifications;

-- Asegurar que RLS esté habilitado
ALTER TABLE public.notifications ENABLE ROW LEVEL SECURITY;

-- Nueva política: cualquier usuario autenticado puede insertar notificaciones
-- (el user_id destino puede ser diferente al auth.uid())
CREATE POLICY "authenticated_can_insert_notifications"
  ON public.notifications FOR INSERT
  TO authenticated
  WITH CHECK (true);

SELECT '57_fix_notifications_rls_insert: OK' AS status;
