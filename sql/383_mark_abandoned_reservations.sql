-- ═══════════════════════════════════════════════════════════════
-- 383 — mark_abandoned_reservations
-- Detecta eventos pagados que el grupo abandonó (nunca llegaron).
-- Marca status='cancelled', cancellation_type='system_auto',
-- cancel_reason='no_show_grupo' y bloquea el payout.
-- Admin decide manualmente: reembolso, strike, penalización.
-- ═══════════════════════════════════════════════════════════════

BEGIN;

CREATE OR REPLACE FUNCTION mark_abandoned_reservations()
RETURNS INTEGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_count INTEGER;
BEGIN
  -- Criterios de abandono:
  --   1. status = 'confirmed'  (pagado, nunca iniciado)
  --   2. payment_status IN paid/deposit_paid/fully_paid
  --   3. group_arrived_at IS NULL  (grupo nunca presionó "Llegué")
  --   4. event_date + event_time + 6h < NOW()  (margen generoso para cualquier duración)
  -- Acción: cancela y bloquea payout para que el cron de 12h NO lo libere al grupo.
  UPDATE reservations
  SET
    status            = 'cancelled',
    cancelled_at      = NOW(),
    cancelled_by      = NULL,          -- NULL = acción del sistema
    cancel_reason     = 'no_show_grupo',
    cancellation_type = 'system_auto',
    payout_status     = 'blocked'
  WHERE
    status            = 'confirmed'
    AND payment_status IN ('paid', 'deposit_paid', 'fully_paid')
    AND group_arrived_at IS NULL
    AND (
      (event_date + COALESCE(event_time, '23:59:00'::TIME))
        AT TIME ZONE 'America/Mexico_City'
      + INTERVAL '6 hours'
    ) < NOW();

  GET DIAGNOSTICS v_count = ROW_COUNT;
  RETURN v_count;
END;
$$;

GRANT EXECUTE ON FUNCTION mark_abandoned_reservations() TO authenticated;

COMMIT;

-- ═══════════════════════════════════════════════════════════════
-- VERIFICACIONES (ejecutar separado después del COMMIT)
-- ═══════════════════════════════════════════════════════════════

-- V1: función existe con SECURITY DEFINER
SELECT proname, prosecdef AS is_security_definer
FROM pg_proc
WHERE proname = 'mark_abandoned_reservations';
-- Esperado: 1 fila, is_security_definer = true

-- V2: GRANT aplicado a authenticated
SELECT grantee, privilege_type
FROM information_schema.routine_privileges
WHERE routine_name = 'mark_abandoned_reservations'
  AND grantee = 'authenticated';
-- Esperado: 1 fila con privilege_type = 'EXECUTE'

-- V3: candidatos actuales que serían marcados (sin modificar)
SELECT id, folio, event_date, event_time, status, payment_status,
       group_arrived_at, payout_status
FROM reservations
WHERE status = 'confirmed'
  AND payment_status IN ('paid', 'deposit_paid', 'fully_paid')
  AND group_arrived_at IS NULL
  AND (
    (event_date + COALESCE(event_time, '23:59:00'::TIME))
      AT TIME ZONE 'America/Mexico_City'
    + INTERVAL '6 hours'
  ) < NOW();
-- Revisar: solo deben aparecer eventos realmente abandonados

-- V4: después de llamar la función, verificar que los marcados tienen payout bloqueado
-- SELECT id, folio, status, cancellation_type, cancel_reason, payout_status
-- FROM reservations
-- WHERE cancel_reason = 'no_show_grupo';
-- Esperado: status='cancelled', cancellation_type='system_auto', payout_status='blocked'
