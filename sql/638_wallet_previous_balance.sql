-- sql/638_wallet_previous_balance.sql
--
-- "SALDO ANTERIOR" en cada wallet (2026-09-10) — petición del usuario:
-- si a alguien le llega un depósito y no se acuerda cuánto tenía antes,
-- puede pensar que le están robando. Se agrega un solo valor "lo que
-- tenías antes de este último cambio" — NO un historial (para eso ya
-- existe wallet_transactions).
--
-- Enfoque: 2 columnas nuevas + 1 trigger BEFORE UPDATE. Se eligió así
-- (en vez de editar cada función) porque HAY 18 funciones distintas que
-- mueven saldos (confirm_gift_payment, distribute_event_earnings,
-- settle_cancellation, admin_register_group_payment, etc.) — tocar cada
-- una es frágil y obliga a re-probarlas todas. El trigger es aditivo:
-- CERO cambios en esas 18 funciones, y captura CUALQUIER cambio futuro
-- también, sin tener que acordarse de mantenerlo.
--
-- Solo se guarda el valor ANTERIOR al último cambio (se sobrescribe cada
-- vez) — nunca un arreglo ni una tabla de histórico.
-- ============================================================

BEGIN;

ALTER TABLE public.wallets
  ADD COLUMN IF NOT EXISTS previous_balance     numeric,
  ADD COLUMN IF NOT EXISTS previous_balance_usd numeric;

ALTER TABLE public.group_wallets
  ADD COLUMN IF NOT EXISTS previous_balance     numeric,
  ADD COLUMN IF NOT EXISTS previous_balance_usd numeric;

CREATE OR REPLACE FUNCTION public.capture_previous_wallet_balance()
RETURNS trigger
LANGUAGE plpgsql
AS $fn$
BEGIN
  IF NEW.available_balance IS DISTINCT FROM OLD.available_balance THEN
    NEW.previous_balance := OLD.available_balance;
  END IF;
  IF NEW.available_balance_usd IS DISTINCT FROM OLD.available_balance_usd THEN
    NEW.previous_balance_usd := OLD.available_balance_usd;
  END IF;
  RETURN NEW;
END;
$fn$;

DROP TRIGGER IF EXISTS trg_capture_previous_balance ON public.wallets;
CREATE TRIGGER trg_capture_previous_balance
  BEFORE UPDATE ON public.wallets
  FOR EACH ROW EXECUTE FUNCTION public.capture_previous_wallet_balance();

DROP TRIGGER IF EXISTS trg_capture_previous_balance ON public.group_wallets;
CREATE TRIGGER trg_capture_previous_balance
  BEFORE UPDATE ON public.group_wallets
  FOR EACH ROW EXECUTE FUNCTION public.capture_previous_wallet_balance();

COMMIT;

-- ── VERIFICACIÓN ────────────────────────────────────────────
SELECT column_name FROM information_schema.columns
WHERE table_name IN ('wallets','group_wallets') AND column_name LIKE 'previous_balance%'
ORDER BY table_name, column_name;
-- Esperado: 4 filas

SELECT tgname, tgrelid::regclass FROM pg_trigger
WHERE tgname = 'trg_capture_previous_balance' AND NOT tgisinternal;
-- Esperado: 2 filas (wallets, group_wallets)

SELECT '638_wallet_previous_balance.sql ejecutado ✅' AS status;
