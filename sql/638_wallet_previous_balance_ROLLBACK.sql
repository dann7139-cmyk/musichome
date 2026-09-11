-- sql/638_wallet_previous_balance_ROLLBACK.sql
BEGIN;

DROP TRIGGER IF EXISTS trg_capture_previous_balance ON public.wallets;
DROP TRIGGER IF EXISTS trg_capture_previous_balance ON public.group_wallets;
DROP FUNCTION IF EXISTS public.capture_previous_wallet_balance();

ALTER TABLE public.wallets
  DROP COLUMN IF EXISTS previous_balance,
  DROP COLUMN IF EXISTS previous_balance_usd;

ALTER TABLE public.group_wallets
  DROP COLUMN IF EXISTS previous_balance,
  DROP COLUMN IF EXISTS previous_balance_usd;

COMMIT;

SELECT '638_wallet_previous_balance_ROLLBACK.sql ejecutado ✅' AS status;
