-- Rollback de sql/589 — restaura admin_alerts() exactamente como estaba
-- antes del parche (hash confirmado b07addfd093fca1be0b74b2b95e557e4,
-- 2026-09-01), quitando 'eventos_multi_grupo_revisar' del jsonb, y elimina
-- la función nueva admin_get_events_needing_review().

BEGIN;

CREATE OR REPLACE FUNCTION public.admin_alerts()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM profiles WHERE id = auth.uid() AND role = 'admin') THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_admin');
  END IF;

  RETURN jsonb_build_object(
    'ok', true,
    -- 💸 FIX [509]: withdrawals, no payout_requests (huérfana)
    'retiros_pendientes', (
      SELECT COUNT(*) FROM withdrawals WHERE status = 'pending'),
    'fees_no_capturados', (
      SELECT COUNT(*) FROM reservations
      WHERE payment_status IN ('paid','fully_paid','deposit_paid')
        AND stripe_fee_amount IS NULL),
    'sin_pais', (
      (SELECT COUNT(*) FROM groups WHERE country IS NULL)
      + (SELECT COUNT(*) FROM profiles WHERE role = 'talent' AND country IS NULL)),
    'grupos_suspendidos', (
      SELECT COUNT(*) FROM groups WHERE suspended_at IS NOT NULL),
    'disputas_abiertas', (
      SELECT COUNT(*) FROM disputes WHERE status IN ('open', 'under_review')),
    'reembolsos_pendientes', (
      SELECT COUNT(*) FROM manual_refunds WHERE status = 'pending'),
    'eventos_sin_cerrar', (
      SELECT COUNT(*) FROM reservations
      WHERE status = 'in_progress'
        AND event_date < (NOW() AT TIME ZONE 'America/Mexico_City')::date),
    'pagos_retenidos_viejos', (
      SELECT COUNT(*) FROM reservations
      WHERE payout_status = 'held'
        AND payment_status IN ('paid','fully_paid','deposit_paid')
        AND status = 'completed'
        AND held_at IS NOT NULL
        AND held_at < NOW() - INTERVAL '3 days')
  );
END;
$function$;

DROP FUNCTION IF EXISTS public.admin_get_events_needing_review();

COMMIT;

SELECT '589_admin_events_review_queue_ROLLBACK ✅' AS status;
