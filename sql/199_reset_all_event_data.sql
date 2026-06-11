-- ════════════════════════════════════════════════════════════════════
-- 199_reset_all_event_data.sql
--
-- RESET COMPLETO de datos de prueba:
--   • Solicitudes express (event_requests)
--   • Reservas y todo lo que depende de ellas
--   • Cotizaciones (quotes)
--   • Eventos (events)
--   • Notificaciones
--   • Historial financiero (wallet_transactions, financial_ledger,
--     event_payouts, connected_payouts, withdrawals)
--   • Saldos de wallets → 0
--   • Reviews / feedback
--   • Disputas, mensajes, confirmaciones de miembros
--   • Heatmap de demanda, loyalty events, analytics
--
-- NO toca: profiles, groups, packages, push_tokens,
--          verification_requests, job_board_profiles,
--          advertisements, bid_orders, etc.
--
-- ⚠️  IRREVERSIBLE — ejecutar solo en entorno de pruebas.
-- ════════════════════════════════════════════════════════════════════

-- ── 1. Solicitudes express primero (event_requests referencia reservations) ───
DELETE FROM public.request_matching_state;
DELETE FROM public.event_requests;

-- ── 2. Cotizaciones ───────────────────────────────────────────────────────────
DELETE FROM public.quotes;

-- ── 3. Hijos directos de reservations (SET NULL no hace CASCADE) ──────────────
DELETE FROM public.extra_hours;
DELETE FROM public.overtime_requests;
DELETE FROM public.event_breaks;
DELETE FROM public.event_disputes;
DELETE FROM public.event_feedback;
DELETE FROM public.reservation_messages;
DELETE FROM public.reservation_member_confirmations;
DELETE FROM public.refund_requests;
DELETE FROM public.cancellation_records;
DELETE FROM public.event_financial_summary;
DELETE FROM public.package_member_distribution;

-- ── 4. Payouts y movimientos financieros ──────────────────────────────────────
DELETE FROM public.connected_payouts;
DELETE FROM public.event_payouts;
DELETE FROM public.wallet_transactions;
DELETE FROM public.financial_ledger;
DELETE FROM public.withdrawals;

-- ── 5. Reservas ───────────────────────────────────────────────────────────────
DELETE FROM public.reservations;

-- ── 6. Eventos (events) ───────────────────────────────────────────────────────
DELETE FROM public.events;

-- ── 7. Reviews ────────────────────────────────────────────────────────────────
DELETE FROM public.client_reviews;
DELETE FROM public.reviews;
DELETE FROM public.talent_reviews;

-- ── 8. Notificaciones ────────────────────────────────────────────────────────
DELETE FROM public.notifications;
DELETE FROM public.notification_log;

-- ── 9. Heatmap / señales de demanda / analytics ──────────────────────────────
DELETE FROM public.demand_heatmap;
DELETE FROM public.loyalty_events;
DELETE FROM public.platform_analytics_snapshots;
DELETE FROM public.group_profile_views;
DELETE FROM public.group_views;

-- ── 10. Resetear saldos de wallets a 0 ───────────────────────────────────────
UPDATE public.wallets
SET
  available_balance = 0,
  pending_balance   = 0,
  total_earned      = 0;

-- ── 11. Verificación final ───────────────────────────────────────────────────
SELECT
  (SELECT COUNT(*) FROM public.event_requests)  AS event_requests,
  (SELECT COUNT(*) FROM public.reservations)    AS reservations,
  (SELECT COUNT(*) FROM public.quotes)          AS quotes,
  (SELECT COUNT(*) FROM public.events)          AS events,
  (SELECT COUNT(*) FROM public.notifications)   AS notifications,
  (SELECT COUNT(*) FROM public.wallet_transactions) AS wallet_txns,
  (SELECT SUM(available_balance) FROM public.wallets) AS total_wallet_balance;

SELECT '199_reset_all_event_data.sql ejecutado ✅ — base de datos limpia para pruebas' AS status;
