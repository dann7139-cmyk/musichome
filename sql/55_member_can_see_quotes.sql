-- ════════════════════════════════════════════════════════════════════
-- 55_member_can_see_quotes.sql
-- Permite que integrantes aceptados del grupo vean las cotizaciones
-- recibidas. Solo SELECT — el INSERT/UPDATE/DELETE sigue siendo
-- exclusivo del dueño (policy group_own_quotes ya lo cubre).
-- ════════════════════════════════════════════════════════════════════

-- is_group_member() ya existe desde 32_member_can_see_reservations.sql
-- is_group_owner()  ya existe desde 23_fix_groups_rls_recursion.sql

-- ── Política de lectura para integrantes del grupo ───────────────────
DROP POLICY IF EXISTS "quotes_member_select" ON public.quotes;
CREATE POLICY "quotes_member_select"
  ON public.quotes FOR SELECT
  TO authenticated
  USING (
    -- Dueño del grupo
    public.is_group_owner(group_id)
    OR
    -- Integrante con membresía aceptada permanente
    public.is_group_member(group_id)
    OR
    -- El cliente que hizo la solicitud
    client_id = auth.uid()
    OR
    -- Admin
    EXISTS (SELECT 1 FROM public.profiles WHERE id = auth.uid() AND role = 'admin')
  );

SELECT '55_member_can_see_quotes: OK ✅' AS status;
