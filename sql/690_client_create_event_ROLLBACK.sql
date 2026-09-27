-- ═══════════════════════════════════════════════════════════════════════════
-- ROLLBACK de sql/690 — SOLO en caso de reversión deliberada
-- ═══════════════════════════════════════════════════════════════════════════
--
-- sql/690 fue puramente ADITIVO: creó UNA función nueva y no modificó ninguna
-- existente, ninguna tabla, ningún dato y ninguna política. Por eso revertirlo
-- es simplemente borrar esa función.
--
-- CONSECUENCIA: "Arma tu fiesta" dejaría de poder crear eventos (la pantalla
-- recibiría PGRST202, función no encontrada). Todo lo demás sigue intacto:
-- los eventos YA creados no se tocan, y el resto de la app sigue creando
-- eventos como siempre (INSERT directo desde QuoteFormScreen y
-- resolve_shared_event_id durante una contratación).
--
-- NO borra ningún evento ni dato de cliente.
-- ═══════════════════════════════════════════════════════════════════════════

BEGIN;

DROP FUNCTION IF EXISTS public.client_create_event(DATE, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, INTEGER, NUMERIC, TEXT, TEXT);

NOTIFY pgrst, 'reload schema';

COMMIT;
