-- ============================================================
-- sql/570_gift_realtime.sql — FASE 4: animación en vivo del regalo
--
-- Habilita Realtime (Postgres Changes) en group_gifts — mismo mecanismo
-- que ya usa wallet_transactions/group_wallets en esta misma base
-- (WalletScreen.tsx ya se suscribe así), no es nada nuevo para el
-- proyecto. El frontend escucha UPDATE en group_gifts filtrando por
-- post_id — cuando status pasa a 'paid' (lo hace confirm_gift_payment,
-- sql/569), todos los que tengan esa publicación abierta ven el emoji
-- flotar al momento. RLS ya cubre esto: group_gifts_read (sql/566)
-- permite leer regalos con status='paid' a cualquiera.
-- ============================================================

ALTER PUBLICATION supabase_realtime ADD TABLE public.group_gifts;

SELECT '570_gift_realtime.sql ejecutado ✅' AS status;
