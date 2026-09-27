-- ═══════════════════════════════════════════════════════════════════════════
-- ROLLBACK de 694 — devuelve la ACL EXACTA que tenían las 17 funciones
-- ═══════════════════════════════════════════════════════════════════════════
-- ⚠️  NO CORRER salvo emergencia deliberada: esto REABRE el acceso anónimo a
-- funciones que acreditan pagos y mueven wallets. Solo tiene sentido si el
-- endurecimiento rompió un flujo legítimo que no se detectó y hace falta
-- restaurar el estado anterior mientras se investiga.
--
-- Estado que restaura (el que tenían las 17 antes de sql/694):
--   `=X/postgres | postgres=X/postgres | anon=X/postgres |
--    authenticated=X/postgres | service_role=X/postgres`
-- es decir, EXECUTE para PUBLIC + anon + authenticated + service_role.
--
-- `GRANT ... TO PUBLIC` reproduce el `=X/postgres`; los grants explícitos a
-- anon y authenticated se reponen aparte para dejar la ACL idéntica y no solo
-- equivalente.
-- ═══════════════════════════════════════════════════════════════════════════

BEGIN;

GRANT EXECUTE ON FUNCTION public.auto_cancel_unpaid_bookings()          TO PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.auto_cancel_expired_bookings()         TO PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.auto_finalize_stuck_events()           TO PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.auto_start_due_events()                TO PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.check_transit_nudges()                 TO PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.send_client_retention_notifications()  TO PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION public.confirm_full_payment_and_credit_wallet(UUID, TEXT, NUMERIC, NUMERIC)
  TO PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.mp_credit_pending_earnings(UUID, TEXT, NUMERIC)
  TO PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.confirm_extra_hour_stripe_payment(UUID, TEXT, NUMERIC, TEXT, NUMERIC)
  TO PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION public.distribute_event_earnings(UUID)                     TO PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.process_refund_reversal(UUID, TEXT, NUMERIC, UUID)  TO PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.settle_cancellation(UUID, TEXT, TEXT, UUID)         TO PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.settle_group_cancellation(UUID, TEXT, TEXT, UUID)   TO PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION public.mark_abandoned_reservations()                        TO PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.release_group_earnings_atomic(UUID, UUID)            TO PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.release_half_on_arrival(UUID, DOUBLE PRECISION, DOUBLE PRECISION)
  TO PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.validate_arrival_code(UUID, TEXT)                   TO PUBLIC, anon, authenticated;

NOTIFY pgrst, 'reload schema';

COMMIT;
