-- ============================================================
-- sql/233_commission_correction_type.sql
--
-- 232 grabó type='debit_refund' para ajustes negativos de comisión.
-- Eso es semánticamente incorrecto: no es un reembolso al cliente,
-- es una corrección donde Stripe cobró más de lo estimado.
--
-- Solución:
--   1. Agregar 'commission_correction' al constraint chk_wt_type
--   2. Renombrar las transacciones mal tipificadas de 232
-- ============================================================

-- ── 1. Expandir constraint de tipo ────────────────────────────────────────
ALTER TABLE wallet_transactions DROP CONSTRAINT IF EXISTS chk_wt_type;
ALTER TABLE wallet_transactions ADD CONSTRAINT chk_wt_type CHECK (
  type IN (
    'credit_pending','credit_available','release_to_available','debit_payout',
    'refund_dispute','adjustment',
    'event_earning','extra_hour','withdrawal','commission','refund',
    'platform_income','debit_refund',
    'ad_income','bid_income','recommendation_income',
    'commission_correction'   -- ajuste de comisión por diferencia Stripe real vs estimado
  )
);

-- ── 2. Reclasificar transacciones de corrección grabadas en 232 ───────────
UPDATE wallet_transactions
SET type = 'commission_correction'
WHERE type = 'debit_refund'
  AND description LIKE '[Corrección 232]%';

SELECT
  type,
  amount,
  description,
  created_at
FROM wallet_transactions
WHERE description LIKE '[Corrección 232]%'
ORDER BY created_at DESC;

SELECT '233_commission_correction_type.sql ejecutado ✅' AS status;
