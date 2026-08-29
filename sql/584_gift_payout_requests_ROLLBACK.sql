-- ============================================================
-- sql/584_gift_payout_requests_ROLLBACK.sql
-- Revierte sql/584_gift_payout_requests.sql. Usar solo en emergencia
-- deliberada — cualquier group_gift_payout_requests 'pending' se pierde.
-- ============================================================

BEGIN;

DROP FUNCTION IF EXISTS public.admin_register_gift_payout(UUID, NUMERIC, TEXT, TEXT, TEXT, TIMESTAMPTZ);
DROP FUNCTION IF EXISTS public.admin_get_pending_gift_payouts();
DROP FUNCTION IF EXISTS public.group_request_gift_payout();
DROP FUNCTION IF EXISTS public.group_get_gift_payout_status();
DROP FUNCTION IF EXISTS public.group_unpaid_gift_balance(UUID);

DROP TABLE IF EXISTS public.group_gift_payout_requests;

ALTER TABLE public.wallet_transactions DROP CONSTRAINT IF EXISTS chk_wt_type;
ALTER TABLE public.wallet_transactions ADD CONSTRAINT chk_wt_type CHECK (
  type = ANY (ARRAY[
    'credit_pending', 'credit_available', 'release_to_available', 'debit_payout',
    'refund_dispute', 'adjustment', 'event_earning', 'extra_hour', 'withdrawal',
    'commission', 'refund', 'platform_income', 'debit_refund', 'ad_income',
    'bid_income', 'recommendation_income', 'commission_correction', 'manual_advance',
    'final_settlement', 'gift_income'
  ])
);

COMMIT;

SELECT '584_gift_payout_requests_ROLLBACK ✅' AS status;
