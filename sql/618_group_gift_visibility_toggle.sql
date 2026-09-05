-- 618_group_gift_visibility_toggle.sql
-- Pedido 2026-09-05: el dueño del grupo puede prender/apagar que sus
-- integrantes (músicos, no dueños) vean en su propia Wallet los regalos y
-- el dinero de regalos que le han dado al grupo — transparencia para que
-- el encargado de la cuenta no pueda ocultarles el dinero. Default false:
-- no cambia el comportamiento de ningún grupo existente hasta que el
-- dueño lo prenda a propósito desde WalletScreen.tsx.

ALTER TABLE public.groups ADD COLUMN IF NOT EXISTS show_gifts_to_members boolean NOT NULL DEFAULT false;
