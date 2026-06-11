-- ════════════════════════════════════════════════════════════════════
-- 99_reset_test_data.sql
-- Limpia todos los datos de prueba para empezar desde cero.
-- ⚠️  SOLO PARA DESARROLLO — NO ejecutar en producción.
-- ════════════════════════════════════════════════════════════════════

-- Transacciones y ledger financiero
DELETE FROM public.wallet_transactions;
DELETE FROM public.financial_ledger;
DELETE FROM public.withdrawals;

-- Pagos y distribución de eventos
DELETE FROM public.event_payouts;

-- Notificaciones
DELETE FROM public.notifications;

-- Calificaciones
DELETE FROM public.client_reviews;
DELETE FROM public.talent_reviews;

-- Chat / mensajes
DELETE FROM public.reservation_messages;

-- Solicitudes express
DELETE FROM public.event_requests;

-- Cotizaciones
DELETE FROM public.quotes;

-- Reservas
DELETE FROM public.reservations;

-- Wallets (saldo a cero)
UPDATE public.wallets
SET available_balance = 0,
    total_earned      = 0,
    updated_at        = NOW();

SELECT '99_reset_test_data: datos de prueba eliminados ✅' AS status;
