-- ═══════════════════════════════════════════════════════════════════════════
-- ROLLBACK de 706 — borra `log_fraud_signal`
-- ═══════════════════════════════════════════════════════════════════════════
-- Volver a dejar la señal antifraude sin registrar (la llamada de ChatScreen
-- vuelve a fallar en silencio, como antes de 706). No borra ninguna fila ya
-- registrada en `fraud_signals` ni toca la tabla.
-- Es una función NUEVA: nada más del proyecto la llama.
-- ═══════════════════════════════════════════════════════════════════════════

BEGIN;

DROP FUNCTION IF EXISTS public.log_fraud_signal(UUID, TEXT, JSONB);

NOTIFY pgrst, 'reload schema';

COMMIT;
