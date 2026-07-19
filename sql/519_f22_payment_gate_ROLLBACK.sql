-- ============================================================
-- sql/519_f22_payment_gate_ROLLBACK.sql — ROLLBACK DE F2.2 (gate v2)
--
-- ⚠️⚠️ NO EJECUTAR en el orden normal de archivos. Solo emergencia
-- deliberada (regla formal post-517). Antes de correrlo, revertir
-- también los webhooks/EFs por git+redeploy para que vuelvan a llamar
-- confirm_full_payment_and_credit_wallet (que sql/519 NO tocó).
--
-- ⚠️ PÉRDIDA DE DATOS: borra payment_attempts / payment_receipts /
-- refund_intents. Solo es aceptable si el gate v2 aún no procesó pagos
-- reales. Si YA hay receipts con dinero, NO correr este archivo:
-- resolver hacia adelante.
-- ============================================================

BEGIN;

-- ── 0. GUARD AUTOMÁTICO: prohibido borrar historial financiero ───
-- Si el gate v2 ya procesó dinero real, este rollback destructivo
-- queda PROHIBIDO — se resuelve hacia adelante (fix-forward).
-- Cuenta como "dato real": cualquier receipt, cualquier refund_intent,
-- y cualquier attempt que pasó de 'creating'/'abandoned' (es decir,
-- que llegó a entregarse a un cliente como referencia de pago).
DO $$
DECLARE
  v_receipts INT;
  v_refunds  INT;
  v_attempts INT;
BEGIN
  SELECT COUNT(*) INTO v_receipts FROM payment_receipts;
  SELECT COUNT(*) INTO v_refunds  FROM refund_intents;
  SELECT COUNT(*) INTO v_attempts FROM payment_attempts
    WHERE status NOT IN ('creating','abandoned');

  IF v_receipts > 0 OR v_refunds > 0 OR v_attempts > 0 THEN
    RAISE EXCEPTION USING MESSAGE = format(
      'ROLLBACK PROHIBIDO — existen datos financieros reales: '
      || 'payment_receipts=%s, refund_intents=%s, attempts reales=%s. '
      || 'Una vez que el gate v2 procesó dinero, el historial financiero '
      || 'NO se borra jamás: resolver hacia adelante. Este archivo solo '
      || 'era válido con las tablas vacías y los webhooks en la vía vieja.',
      v_receipts, v_refunds, v_attempts);
  END IF;
END $$;

-- 1. Mapear 'paid_blocked' a la representación vieja (509):
--    payment_status='paid' + payout_status='blocked'
UPDATE reservations SET
  payment_status = 'paid',
  payout_status  = 'blocked',
  updated_at     = NOW()
WHERE payment_status = 'paid_blocked';

-- 2. Restaurar el CHECK v3 exacto (sql/204)
DO $$ BEGIN
  ALTER TABLE reservations DROP CONSTRAINT IF EXISTS chk_payment_status_v4;
EXCEPTION WHEN OTHERS THEN NULL; END; $$;

ALTER TABLE reservations
  ADD CONSTRAINT chk_payment_status_v3 CHECK (
    payment_status IN (
      'unpaid', 'pending', 'pending_payment',
      'deposit_pending', 'deposit_paid', 'remaining_pending',
      'fully_paid', 'paid',
      'payment_failed', 'refunded', 'cancelled'
    )
  );

-- 3. Funciones nuevas
DROP FUNCTION IF EXISTS public.confirm_reservation_payment_v2(
  TEXT, TEXT, TEXT, UUID, BIGINT, TEXT, TEXT, BIGINT, TEXT, JSONB);
DROP FUNCTION IF EXISTS public.can_schedule(UUID, DATE, TSTZRANGE, UUID);

-- 4. Tablas nuevas (⚠️ pérdida de datos — leer encabezado)
DROP TABLE IF EXISTS refund_intents;
DROP TABLE IF EXISTS payment_receipts;
DROP TABLE IF EXISTS payment_attempts;
DROP TABLE IF EXISTS payment_config;

COMMIT;

SELECT '519_ROLLBACK ejecutado — gate v2 eliminado; vía vieja (509) intacta y operativa' AS status;
