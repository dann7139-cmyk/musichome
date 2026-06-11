-- ════════════════════════════════════════════════════════════════════════════
-- 111_cancellation_protection.sql
-- Sistema anti-cancelaciones: logging completo + cron de monitoreo
--
-- ESTADO PREVIO (ya implementado en 92/107 — NO se reimplementa):
--   92  → cancellation_records table, get_cancellation_policy(), client_cancel_reservation()
--   107 → reliability_score, reliability_penalty, cancelled_by en reservations
--         group_cancel_reservation() con penalizaciones
--         _trg_protect_client_on_group_cancel trigger
--         send_group_health_warnings(), review_group_health()
--         calculate_group_reliability(), get_group_trust_profile()
--
-- LO QUE AGREGA ESTE ARCHIVO:
--   1. cancelled_by en cancellation_records (quién canceló: group/client/admin/system)
--   2. group_cancel_reservation() actualizado — ahora TAMBIÉN registra en
--      cancellation_records para auditoría completa
--   3. Cron jobs para monitoreo periódico:
--        review-group-health   → cada 6 horas (recalcula scores, expira penalties)
--        group-health-warnings → cada 24 horas (notificaciones educativas a grupos)
--
-- No modifica el flujo de pagos ni de reservas.
-- Ejecutar DESPUÉS de 110_dynamic_pricing.sql
-- ════════════════════════════════════════════════════════════════════════════


-- ── 1. Extender cancellation_records: columna cancelled_by ───────────────────
-- Permite rastrear si fue el grupo, el cliente, admin o el sistema.
-- Compatible con la columna homóloga ya existente en reservations.

ALTER TABLE public.cancellation_records
  ADD COLUMN IF NOT EXISTS cancelled_by TEXT
    CHECK (cancelled_by IN ('group', 'client', 'admin', 'system'));

COMMENT ON COLUMN public.cancellation_records.cancelled_by IS
  'Indica quién inició la cancelación. Espeja reservations.cancelled_by para auditoría.';


-- ── 2. group_cancel_reservation() — versión con log en cancellation_records ──
-- Sustituye la versión de 107. Firma idéntica.
-- Cambios: INSERT INTO cancellation_records después de cancelar la reserva.

CREATE OR REPLACE FUNCTION public.group_cancel_reservation(p_reservation_id UUID)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_res      RECORD;
  v_group    RECORD;
  v_hours    NUMERIC;
  v_penalty  NUMERIC;
  v_days     INT;
BEGIN
  -- Verificar que la reserva pertenece a un grupo del usuario autenticado
  SELECT r.*, g.id AS gid
  INTO   v_res
  FROM   public.reservations r
  JOIN   public.groups g ON g.id = r.group_id AND g.owner_id = auth.uid()
  WHERE  r.id = p_reservation_id
    AND  r.status IN ('confirmed', 'deposit_paid', 'accepted');

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'reservation_not_found_or_unauthorized');
  END IF;

  v_hours := EXTRACT(EPOCH FROM (v_res.event_date::TIMESTAMPTZ - NOW())) / 3600;

  -- Determinar penalización según proximidad
  IF v_hours <= 48 THEN
    v_penalty := 20; v_days := 14;
  ELSIF v_hours <= 168 THEN   -- 7 días
    v_penalty := 10; v_days :=  7;
  ELSE
    v_penalty :=  5; v_days :=  3;
  END IF;

  -- Cancelar reserva
  UPDATE public.reservations
  SET status       = 'cancelled',
      cancelled_by = 'group'
  WHERE id = p_reservation_id;

  -- ── NUEVO: Registrar en cancellation_records para auditoría ─────────────
  INSERT INTO public.cancellation_records (
    reservation_id,
    user_id,
    cancelled_by,
    hours_until_event,
    refund_policy,
    refund_amount,
    refund_status,
    event_date,
    event_total
  ) VALUES (
    p_reservation_id,
    auth.uid(),
    'group',
    v_hours,
    'not_paid',     -- el grupo no recibe reembolso
    0,
    'not_applicable',
    v_res.event_date,
    COALESCE(v_res.total_price, 0)
  );

  -- Aplicar penalización al reliability_score temporalmente
  UPDATE public.groups
  SET reliability_penalty = LEAST(COALESCE(reliability_penalty, 0) + v_penalty, 40),
      penalty_expires_at  = GREATEST(
                              COALESCE(penalty_expires_at, NOW()),
                              NOW() + (v_days || ' days')::INTERVAL
                            ),
      warnings_count      = COALESCE(warnings_count, 0) + 1
  WHERE id = v_res.gid;

  -- Reducir ranking_boost (visibilidad)
  PERFORM public.apply_ranking_boost(v_res.gid, -0.30, v_days * 24);

  -- Recalcular scores
  PERFORM public.calculate_group_reliability(v_res.gid);
  PERFORM public.recalculate_group_reputation(v_res.gid);

  RETURN jsonb_build_object(
    'ok',             true,
    'penalty_pts',    v_penalty,
    'penalty_days',   v_days,
    'hours_to_event', ROUND(v_hours::NUMERIC, 1)
  );

EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$$;

GRANT EXECUTE ON FUNCTION public.group_cancel_reservation(UUID) TO authenticated;


-- ── 3. Cron jobs de monitoreo periódico ──────────────────────────────────────
-- Requiere pg_cron habilitado en Supabase → Database → Extensions.
-- review_group_health()   → cada 6 horas: recalcula scores, expira penalizaciones
-- send_group_health_warnings() → cada 24 horas: notificaciones educativas

DO $$
BEGIN
  -- Desregistrar previos si existían
  BEGIN PERFORM cron.unschedule('review-group-health');    EXCEPTION WHEN OTHERS THEN NULL; END;
  BEGIN PERFORM cron.unschedule('group-health-warnings');  EXCEPTION WHEN OTHERS THEN NULL; END;

  -- Recálculo de confiabilidad: 0:00, 6:00, 12:00, 18:00
  PERFORM cron.schedule(
    'review-group-health',
    '0 */6 * * *',
    'SELECT public.review_group_health()'
  );

  -- Advertencias educativas a grupos con bajo desempeño: 10:00 AM diario
  PERFORM cron.schedule(
    'group-health-warnings',
    '0 10 * * *',
    'SELECT public.send_group_health_warnings()'
  );

EXCEPTION WHEN OTHERS THEN
  RAISE NOTICE 'pg_cron no disponible. Activar en Dashboard → Extensions → pg_cron, luego re-ejecutar.';
END;
$$;


SELECT '111_cancellation_protection: log en cancellation_records + cron de monitoreo ✅' AS status;
