-- ═══════════════════════════════════════════════════════════════════════════
-- 694 — ENDURECIMIENTO DE ACL: funciones internas de reservations/dinero
-- ═══════════════════════════════════════════════════════════════════════════
-- ETAPA 1 del endurecimiento de seguridad. Esta migración NO cambia lógica:
-- solo cambia QUIÉN puede invocar. Cero cambios en cálculo de precios,
-- comisiones, wallets, payouts, reembolsos, Stripe, Conekta o MSI. Cero DDL de
-- tablas, cero DML, cero policies, cero RLS.
--
-- ── EL PROBLEMA (verificado por introspección, 2026-09-27) ─────────────────
-- 17 funciones SECURITY DEFINER que escriben `reservations` cumplían TODO esto
-- a la vez:
--   · ACL = `=X/postgres` (PUBLIC) + anon + authenticated + service_role;
--   · ninguna comprobación de auth.uid() adentro;
--   · capaces de mover o registrar dinero (wallets, payouts, reembolsos) o de
--     cambiar payment_status/status de una reserva.
-- Es decir: cualquiera con la llave anon pública de la app podía invocar, por
-- ejemplo, confirm_full_payment_and_credit_wallet o settle_cancellation.
--
-- ── EL PATRÓN QUE YA EXISTÍA EN EL PROYECTO ────────────────────────────────
-- `confirm_reservation_payment_v2` ya tiene ACL `postgres | service_role` y
-- nada más. Esta migración aplica ese mismo criterio al resto, PERO no de forma
-- mecánica: se decidió función por función según sus invocadores REALES.
--
-- ── CÓMO SE DECIDIÓ CADA UNA ───────────────────────────────────────────────
-- Se revisaron los 50 crons (`cron.job`), las edge functions, la app móvil,
-- `web/src`, y las llamadas función→función en `pg_proc`.
--
-- Los 6 crons que invocan estas funciones corren como `postgres`
-- (`cron.job.username`), así que NO necesitan el grant de anon/authenticated:
--   transit-nudges, mark-abandoned-reservations, client-retention,
--   auto-start-events, auto-finalize-stuck-events, auto-cancel-bookings.
--
-- Las edge functions que las invocan (stripe-webhook, conekta-webhook,
-- mercadopago-webhook, create-conekta-order, process-refund, cron-auto-cancel)
-- usan SERVICE_ROLE_KEY. En `process-refund` se verificó header por header:
-- `serviceHeaders` lleva `Bearer SERVICE_KEY`, y el único lugar donde se usa
-- `userHeaders` (apikey anon + token del llamante) es `claim_reservation_refund`,
-- que NO está en esta lista y sí valida auth.uid().
--
-- Llamadas función→función: `release_group_earnings_atomic` la invocan
-- admin_force_complete_event, admin_release_reservation,
-- admin_verify_arrival_and_release, release_all_eligible_payments y
-- release_event_payment; `release_half_on_arrival` la invoca
-- admin_dispute_evidence. TODAS son SECURITY DEFINER propiedad de postgres, así
-- que la llamada interna corre con privilegios del definidor y NO requiere que
-- el usuario final tenga EXECUTE sobre la función interna. Por eso revocar no
-- rompe esas rutas.
--
-- ── LAS 4 EXCEPCIONES: sí tienen un invocador legítimo `authenticated` ─────
-- A estas se les revoca PUBLIC y anon, pero se les CONSERVA `authenticated`,
-- porque la app instalada las llama hoy y revocarlas la rompería en caliente:
--   · mark_abandoned_reservations  → src/screens/group/GroupEventsScreen.tsx:589
--       (el grupo la dispara al cargar sus eventos; además hay cron cada 30 min)
--   · release_group_earnings_atomic → src/screens/group/EventTimerScreen.tsx:1964
--       (el grupo la llama tras complete_event para liberar su pago)
--   · release_half_on_arrival      → src/screens/group/EventTimerScreen.tsx:1688
--       (el grupo la llama al marcar "Llegué", con validación GPS server-side)
--   · validate_arrival_code        → sin invocador vivo encontrado, pero
--       `sql/381` le concedió EXECUTE a authenticated de forma explícita y
--       deliberada; no se revierte esa decisión en esta etapa.
-- El riesgo residual de esas 4 se cierra en la ETAPA 2, quitando el UPDATE
-- directo del cliente sobre `reservations` (sin poder escribir payment_status
-- ni payout_status, la cadena de abuso deja de existir) y, donde convenga,
-- envolviéndolas en una RPC que verifique al dueño del grupo.
--
-- ── ORDEN Y REVERSIBILIDAD ─────────────────────────────────────────────────
-- Aditiva en el sentido de que no toca datos ni lógica. Reversible al 100% con
-- `694_..._ROLLBACK.sql`. Probar con `sql/695` (autorevertible, solo lee ACL con
-- has_function_privilege — NUNCA ejecuta estas funciones).
-- ═══════════════════════════════════════════════════════════════════════════

BEGIN;

-- ─── GRUPO A: internas puras. Solo postgres y service_role ────────────────
-- Ningún invocador `authenticated` real. Las llaman crons (como postgres),
-- webhooks/edge (service_role), u otras funciones SECURITY DEFINER.

-- Barridos programados (cron como postgres)
REVOKE EXECUTE ON FUNCTION public.auto_cancel_unpaid_bookings()          FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.auto_cancel_expired_bookings()         FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.auto_finalize_stuck_events()           FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.auto_start_due_events()                FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.check_transit_nudges()                 FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.send_client_retention_notifications()  FROM PUBLIC, anon, authenticated;

-- Acreditación de pagos: las invocan EXCLUSIVAMENTE los webhooks con
-- service_role. Que anon pudiera llamarlas era la exposición más grave.
REVOKE EXECUTE ON FUNCTION public.confirm_full_payment_and_credit_wallet(UUID, TEXT, NUMERIC, NUMERIC)
  FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.mp_credit_pending_earnings(UUID, TEXT, NUMERIC)
  FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.confirm_extra_hour_stripe_payment(UUID, TEXT, NUMERIC, TEXT, NUMERIC)
  FROM PUBLIC, anon, authenticated;

-- Reparto y reembolsos: solo process-refund / webhooks con service_role.
REVOKE EXECUTE ON FUNCTION public.distribute_event_earnings(UUID)                        FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.process_refund_reversal(UUID, TEXT, NUMERIC, UUID)     FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.settle_cancellation(UUID, TEXT, TEXT, UUID)            FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.settle_group_cancellation(UUID, TEXT, TEXT, UUID)      FROM PUBLIC, anon, authenticated;

-- ─── GRUPO B: conservan `authenticated` (invocador real en la app) ────────
-- Se cierra el acceso anónimo, que es lo indefendible. El resto del riesgo se
-- cierra en la ETAPA 2 (quitar el UPDATE directo sobre reservations).
REVOKE EXECUTE ON FUNCTION public.mark_abandoned_reservations()                      FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION public.release_group_earnings_atomic(UUID, UUID)           FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION public.release_half_on_arrival(UUID, DOUBLE PRECISION, DOUBLE PRECISION)
  FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION public.validate_arrival_code(UUID, TEXT)                  FROM PUBLIC, anon;

-- ─── Garantía explícita de que el backend NO pierde acceso ────────────────
-- Estos GRANT son idempotentes y redundantes (los roles ya los tenían), pero se
-- dejan escritos para que quede constancia de que Stripe/Conekta/webhooks/crons
-- siguen pudiendo ejecutar todo lo que ejecutaban.
GRANT EXECUTE ON FUNCTION public.auto_cancel_unpaid_bookings()          TO postgres, service_role;
GRANT EXECUTE ON FUNCTION public.auto_cancel_expired_bookings()         TO postgres, service_role;
GRANT EXECUTE ON FUNCTION public.auto_finalize_stuck_events()           TO postgres, service_role;
GRANT EXECUTE ON FUNCTION public.auto_start_due_events()                TO postgres, service_role;
GRANT EXECUTE ON FUNCTION public.check_transit_nudges()                 TO postgres, service_role;
GRANT EXECUTE ON FUNCTION public.send_client_retention_notifications()  TO postgres, service_role;
GRANT EXECUTE ON FUNCTION public.confirm_full_payment_and_credit_wallet(UUID, TEXT, NUMERIC, NUMERIC) TO postgres, service_role;
GRANT EXECUTE ON FUNCTION public.mp_credit_pending_earnings(UUID, TEXT, NUMERIC)                      TO postgres, service_role;
GRANT EXECUTE ON FUNCTION public.confirm_extra_hour_stripe_payment(UUID, TEXT, NUMERIC, TEXT, NUMERIC) TO postgres, service_role;
GRANT EXECUTE ON FUNCTION public.distribute_event_earnings(UUID)                    TO postgres, service_role;
GRANT EXECUTE ON FUNCTION public.process_refund_reversal(UUID, TEXT, NUMERIC, UUID)  TO postgres, service_role;
GRANT EXECUTE ON FUNCTION public.settle_cancellation(UUID, TEXT, TEXT, UUID)         TO postgres, service_role;
GRANT EXECUTE ON FUNCTION public.settle_group_cancellation(UUID, TEXT, TEXT, UUID)   TO postgres, service_role;
GRANT EXECUTE ON FUNCTION public.mark_abandoned_reservations()                       TO postgres, service_role, authenticated;
GRANT EXECUTE ON FUNCTION public.release_group_earnings_atomic(UUID, UUID)            TO postgres, service_role, authenticated;
GRANT EXECUTE ON FUNCTION public.release_half_on_arrival(UUID, DOUBLE PRECISION, DOUBLE PRECISION) TO postgres, service_role, authenticated;
GRANT EXECUTE ON FUNCTION public.validate_arrival_code(UUID, TEXT)                   TO postgres, service_role, authenticated;

-- PostgREST cachea el esquema y sus permisos: sin esto, un cliente podría
-- seguir recibiendo respuestas del caché durante unos segundos.
NOTIFY pgrst, 'reload schema';

COMMIT;
