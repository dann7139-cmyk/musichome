-- Rollback de sql/593 — elimina client_accept_quote(). Las dos pantallas
-- (ClientQuoteDetailScreen.tsx, QuotePaymentScreen.tsx) deben revertirse
-- a su código anterior (2 pasos separados) si se hace este rollback,
-- o quedarían llamando a una función que ya no existe.
-- ⚠️ Revertir esto reabre el hallazgo real documentado en sql/593
-- (posible reserva duplicada tras una falla de red a medias) — solo
-- usar en emergencia deliberada, y coordinado con el revert del código.

BEGIN;

DROP FUNCTION IF EXISTS public.client_accept_quote(UUID, UUID, INT);

COMMIT;

SELECT '593_client_accept_quote_atomic_ROLLBACK ✅' AS status;
