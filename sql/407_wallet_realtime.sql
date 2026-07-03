BEGIN;

ALTER TABLE public.group_wallets      REPLICA IDENTITY FULL;
ALTER TABLE public.wallet_transactions REPLICA IDENTITY FULL;

DO $$ BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_publication_tables
    WHERE pubname = 'supabase_realtime' AND tablename = 'group_wallets'
  ) THEN
    ALTER PUBLICATION supabase_realtime ADD TABLE public.group_wallets;
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_publication_tables
    WHERE pubname = 'supabase_realtime' AND tablename = 'wallet_transactions'
  ) THEN
    ALTER PUBLICATION supabase_realtime ADD TABLE public.wallet_transactions;
  END IF;
END $$;

COMMIT;

-- Verificación
SELECT tablename FROM pg_publication_tables
WHERE pubname = 'supabase_realtime'
AND tablename IN ('group_wallets', 'wallet_transactions');
