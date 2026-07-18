-- ============================================================
-- sql/511_fix_monthly_earnings_owner_guard.sql
-- 🔒 FIX privacidad (hallazgo auditoría 2026-07-18):
--    get_group_monthly_earnings era SECURITY DEFINER sin validar
--    dueño — cualquier usuario autenticado podía consultar las
--    ganancias mensuales de CUALQUIER grupo llamando el RPC directo.
--
--  Fix mínimo: misma firma, misma respuesta, misma funcionalidad
--  para el DUEÑO. Único cambio: el group_id consultado debe
--  pertenecer a auth.uid(). Si no es el dueño → 0 filas (vacío),
--  sin filtrar información.
-- ============================================================

BEGIN;

CREATE OR REPLACE FUNCTION public.get_group_monthly_earnings(
  p_group_id UUID,
  p_months   INT DEFAULT 6
)
RETURNS TABLE(period TEXT, earnings NUMERIC, events BIGINT)
LANGUAGE sql SECURITY DEFINER
SET search_path = public
AS $$
  SELECT
    TO_CHAR(DATE_TRUNC('month', r.created_at), 'Mon') AS period,
    COALESCE(SUM(r.group_earnings), 0)                AS earnings,
    COUNT(*)                                          AS events
  FROM reservations r
  WHERE r.group_id = p_group_id
    -- 🔒 [511] Solo el DUEÑO del grupo puede ver sus ganancias
    AND EXISTS (
      SELECT 1 FROM groups g
      WHERE g.id = p_group_id AND g.owner_id = auth.uid()
    )
    AND r.payment_status IN ('paid', 'fully_paid', 'deposit_paid')
    AND r.created_at >= (CURRENT_DATE - (p_months || ' months')::INTERVAL)
  GROUP BY DATE_TRUNC('month', r.created_at)
  ORDER BY DATE_TRUNC('month', r.created_at);
$$;

GRANT EXECUTE ON FUNCTION public.get_group_monthly_earnings TO authenticated;

COMMIT;

-- ── VERIFICACIÓN ──────────────────────────────────────────────────────────────
SELECT prosrc LIKE '%owner_id = auth.uid()%' AS guard_dueno
FROM pg_proc WHERE proname = 'get_group_monthly_earnings';
-- Esperado: true

-- 🧪 Prueba 1 (como DUEÑO del grupo, en la app o SQL con su sesión):
--   SELECT * FROM get_group_monthly_earnings('<id-de-su-grupo>');
--   Esperado: sus meses con ganancias, IGUAL que antes.
--
-- 🧪 Prueba 2 (con la sesión de OTRO usuario — otro grupo o un cliente):
--   SELECT * FROM get_group_monthly_earnings('<id-del-grupo-ajeno>');
--   Esperado: 0 filas (vacío) — ya no filtra nada.

SELECT '511_fix_monthly_earnings_owner_guard.sql ejecutado ✅' AS status;
