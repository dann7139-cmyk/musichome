-- ════════════════════════════════════════════════════════════════════
-- 86_clean_for_testing.sql
-- Borra TODOS los eventos, reservas, solicitudes y notificaciones
-- para empezar pruebas desde cero.
-- ⚠️  SOLO PARA DESARROLLO — NO ejecutar en producción.
-- ════════════════════════════════════════════════════════════════════

-- Mensajes de chat ligados a reservas
DELETE FROM public.reservation_messages;

-- Calificaciones
DELETE FROM public.client_reviews;
DELETE FROM public.talent_reviews;

-- Pagos y ledger financiero
DELETE FROM public.event_payouts;
DELETE FROM public.wallet_transactions;
DELETE FROM public.financial_ledger;
DELETE FROM public.withdrawals;

-- Notificaciones
DELETE FROM public.notifications;

-- Solicitudes express (event_requests) y cotizaciones
DELETE FROM public.event_requests;
DELETE FROM public.quotes;

-- Reservas y eventos
DELETE FROM public.reservations;
DELETE FROM public.events;

-- Wallets a cero
UPDATE public.wallets
SET available_balance = 0,
    total_earned      = 0,
    updated_at        = NOW();

SELECT '86_clean_for_testing: todo limpio, listo para prueba ✅' AS status;
