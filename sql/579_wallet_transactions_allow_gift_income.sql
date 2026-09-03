-- ============================================================
-- sql/579_wallet_transactions_allow_gift_income.sql — permitir 'gift_income'
--
-- sql/567 (confirm_gift_payment) inserta wallet_transactions con
-- type='gift_income', pero chk_wt_type nunca se actualizó para permitir
-- ese valor — CADA regalo pagado tronaba en el primer INSERT (violación
-- de constraint), así que confirm_gift_payment JAMÁS pudo completarse,
-- ni una sola vez, desde que existe la función. Se descubrió al
-- reconciliar manualmente los regalos de prueba de Lala (2026-08-26).
-- ============================================================

ALTER TABLE public.wallet_transactions DROP CONSTRAINT chk_wt_type;

ALTER TABLE public.wallet_transactions ADD CONSTRAINT chk_wt_type CHECK (
  type = ANY (ARRAY[
    'credit_pending', 'credit_available', 'release_to_available', 'debit_payout',
    'refund_dispute', 'adjustment', 'event_earning', 'extra_hour', 'withdrawal',
    'commission', 'refund', 'platform_income', 'debit_refund', 'ad_income',
    'bid_income', 'recommendation_income', 'commission_correction', 'manual_advance',
    'final_settlement', 'gift_income'
  ])
);

SELECT '579_wallet_transactions_allow_gift_income.sql ejecutado ✅' AS status;
