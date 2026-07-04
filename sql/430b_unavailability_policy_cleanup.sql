-- ============================================================
-- sql/430b_unavailability_policy_cleanup.sql
-- Remate del 430: dropear las 3 políticas redundantes cuyos nombres
-- reales diferían de los que el 430 intentó (client_read →
-- group_unavailability_client_read, etc.).
--
-- Se CONSERVA group_unavailability_admin_all (ALL, admin-scoped):
-- mismo patrón que reservations_admin_all — el admin puede gestionar
-- bloqueos de cualquier grupo para soporte. No es el hueco qual=true.
--
-- Resultado final: 5 políticas (4 canónicas + admin_all).
-- ============================================================

DROP POLICY IF EXISTS "group_unavailability_client_read" ON public.group_unavailability;
DROP POLICY IF EXISTS "unavail_select_all"               ON public.group_unavailability;
DROP POLICY IF EXISTS "unavail_write_owner"              ON public.group_unavailability;

-- ── Verificación (la V2 definitiva) ───────────────────────────────────────────
SELECT policyname, cmd FROM pg_policies
WHERE tablename = 'group_unavailability'
ORDER BY policyname;
-- Esperado: EXACTAMENTE 5 filas:
--   group_unavailability_admin_all (ALL)   ← se queda, admin-scoped
--   unavail_owner_delete           (DELETE)
--   unavail_owner_insert           (INSERT)
--   unavail_owner_update           (UPDATE)
--   unavail_public_read            (SELECT)

SELECT '430b_unavailability_policy_cleanup.sql ejecutado ✅' AS status;
