-- ============================================================
-- sql/224_fix_group_stats_rpc.sql
--
-- Corrige get_group_monthly_earnings para incluir todas las
-- reservas pagadas (payment_status='paid'/'fully_paid'), no
-- solo las que ya tienen status='completed'.
--
-- Por qué: los eventos futuros con pago ya confirmado tienen
-- status='confirmed' pero payment_status='paid'. El gráfico
-- mensual de finanzas mostraba $0 porque excluía estas reservas.
--
-- Ejecutar en: Supabase Dashboard → SQL Editor
-- ============================================================

CREATE OR REPLACE FUNCTION public.get_group_monthly_earnings(
  p_group_id UUID,
  p_months   INT DEFAULT 6
)
RETURNS TABLE(period TEXT, earnings NUMERIC, events BIGINT)
LANGUAGE sql SECURITY DEFINER
SET search_path = public
AS $$
  SELECT
    TO_CHAR(DATE_TRUNC('month', created_at), 'Mon') AS period,
    COALESCE(SUM(group_earnings), 0)                AS earnings,
    COUNT(*)                                         AS events
  FROM reservations
  WHERE group_id = p_group_id
    AND payment_status IN ('paid', 'fully_paid', 'deposit_paid')
    AND created_at >= (CURRENT_DATE - (p_months || ' months')::INTERVAL)
  GROUP BY DATE_TRUNC('month', created_at)
  ORDER BY DATE_TRUNC('month', created_at);
$$;

GRANT EXECUTE ON FUNCTION public.get_group_monthly_earnings TO authenticated;

SELECT '224_fix_group_stats_rpc.sql ejecutado ✅' AS status;
