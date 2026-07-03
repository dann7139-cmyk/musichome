-- ═══════════════════════════════════════════════════════════════
-- 384 — Ajusta mark_abandoned_reservations
-- Reemplaza el margen fijo de 6h por: duración real + 30 min.
-- Duración: COALESCE(hours_count, package.duration_hours, quote.duration_hours, 4h default).
-- Requiere JOIN con packages y quotes (duration_hours no está en reservations directamente).
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
  -- Subquery calcula ends_at por reserva:
  --   event_date + event_time (hora local MX) → UTC via AT TIME ZONE
  --   + duración real (hours_count ó package.duration_hours ó quote.duration_hours ó 4h)
  --   + 30 min de gracia
  -- Si ends_at < NOW() y el grupo nunca llegó → abandono confirmado.
  UPDATE reservations AS r
  SET
    status            = 'cancelled',
    cancelled_at      = NOW(),
    cancelled_by      = NULL,           -- NULL = sistema
    cancel_reason     = 'no_show_grupo',
    cancellation_type = 'system_auto',
    payout_status     = 'blocked'
  FROM (
    SELECT
      res.id,
      (
        (res.event_date + COALESCE(res.event_time, '23:59:00'::TIME))
          AT TIME ZONE 'America/Mexico_City'
        + COALESCE(res.hours_count, pkg.duration_hours, qte.duration_hours, 4)
          * INTERVAL '1 hour'
        + INTERVAL '30 minutes'
      ) AS ends_at
    FROM reservations res
    LEFT JOIN packages pkg ON pkg.id = res.package_id
    LEFT JOIN quotes   qte ON qte.id = res.quote_id
    WHERE res.status            = 'confirmed'
      AND res.payment_status    IN ('paid', 'deposit_paid', 'fully_paid')
      AND res.group_arrived_at  IS NULL
  ) sub
  WHERE r.id     = sub.id
    AND sub.ends_at < NOW();

  GET DIAGNOSTICS v_count = ROW_COUNT;
  RETURN v_count;
END;
$$;

GRANT EXECUTE ON FUNCTION mark_abandoned_reservations() TO authenticated;

COMMIT;

-- ═══════════════════════════════════════════════════════════════
-- VERIFICACIONES (ejecutar separado después del COMMIT)
-- ═══════════════════════════════════════════════════════════════

-- V1: función actualizada — verificar que sigue siendo SECURITY DEFINER
SELECT proname, prosecdef AS is_security_definer, prosrc LIKE '%ends_at%' AS has_new_logic
FROM pg_proc
WHERE proname = 'mark_abandoned_reservations';
-- Esperado: 1 fila, is_security_definer=true, has_new_logic=true

-- V2: candidatos actuales con duración calculada (vista previa sin modificar)
SELECT
  res.id,
  res.folio,
  res.event_date,
  res.event_time,
  COALESCE(res.hours_count, pkg.duration_hours, qte.duration_hours, 4) AS dur_h,
  (
    (res.event_date + COALESCE(res.event_time, '23:59:00'::TIME))
      AT TIME ZONE 'America/Mexico_City'
    + COALESCE(res.hours_count, pkg.duration_hours, qte.duration_hours, 4)
      * INTERVAL '1 hour'
    + INTERVAL '30 minutes'
  ) AS ends_at,
  NOW() AS now_utc,
  res.payment_status,
  res.payout_status
FROM reservations res
LEFT JOIN packages pkg ON pkg.id = res.package_id
LEFT JOIN quotes   qte ON qte.id = res.quote_id
WHERE res.status           = 'confirmed'
  AND res.payment_status   IN ('paid', 'deposit_paid', 'fully_paid')
  AND res.group_arrived_at IS NULL;
-- Revisar: ends_at < now_utc → esos serán marcados en el próximo call

-- V3: llamar la función y ver cuántas filas marcó
-- SELECT mark_abandoned_reservations();
-- Esperado: INTEGER ≥ 1 (al menos DRC-2026-0003)

-- V4: confirmar que DRC-2026-0003 quedó bloqueado
-- SELECT folio, status, cancellation_type, cancel_reason, payout_status, cancelled_at
-- FROM reservations WHERE folio = 'DRC-2026-0003';
-- Esperado: status='cancelled', cancellation_type='system_auto',
--           cancel_reason='no_show_grupo', payout_status='blocked'
