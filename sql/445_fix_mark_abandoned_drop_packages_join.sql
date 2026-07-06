-- ============================================================
-- sql/445_fix_mark_abandoned_drop_packages_join.sql
-- BUG: mark_abandoned_reservations (sql/384) hace LEFT JOIN packages.
-- La tabla `packages` fue ERRADICADA → to_regclass('public.packages') = NULL
-- → el cron LANZA excepción en cada corrida y NUNCA cancela abandonos.
-- Efecto colateral: la cola No-Shows (admin_get_no_shows) queda siempre
-- vacía porque nada llega a cancellation_type='system_auto'.
--
-- FIX: quitar SOLO el JOIN a packages y su referencia en el COALESCE de
-- duración. Nada más cambia:
--   · ends_at: idéntico (misma zona MX, +30 min de gracia).
--   · duración: COALESCE(hours_count, quote.duration_hours, 4)  ← sin pkg.
--   · filtro, SET (cancelled/blocked), SECURITY DEFINER: intactos.
--   · NO toca payout, NO toca el candado GPS ni el release del 50%.
--
-- Basado en el pg_get_functiondef VIVO de prod (lección 429), no en el repo.
-- México = UTC-6 fijo (sin horario de verano desde 2022).
-- ============================================================

-- ── PRE-CHECK: abortar si packages VOLVIÓ a existir (este patch la asume ida) ──
DO $pre$
BEGIN
  IF to_regclass('public.packages') IS NOT NULL THEN
    RAISE EXCEPTION 'ABORT: public.packages existe — este patch asume que fue eliminada. Revisar antes de aplicar.';
  END IF;
  IF (SELECT prosrc FROM pg_proc WHERE proname = 'mark_abandoned_reservations') NOT LIKE '%packages%' THEN
    RAISE NOTICE 'La función ya NO referencia packages — el patch quizá ya se aplicó (se re-aplica igual, es idempotente).';
  END IF;
END
$pre$;

BEGIN;

CREATE OR REPLACE FUNCTION public.mark_abandoned_reservations()
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_count INTEGER;
BEGIN
  -- Subquery calcula ends_at por reserva:
  --   event_date + event_time (hora local MX) → UTC via AT TIME ZONE
  --   + duración real (hours_count ó quote.duration_hours ó 4h)   [445: sin packages]
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
        + COALESCE(res.hours_count, qte.duration_hours, 4)   -- [445] sin pkg.duration_hours
          * INTERVAL '1 hour'
        + INTERVAL '30 minutes'
      ) AS ends_at
    FROM reservations res
    LEFT JOIN quotes   qte ON qte.id = res.quote_id          -- [445] LEFT JOIN packages eliminado
    WHERE res.status            = 'confirmed'
      AND res.payment_status    IN ('paid', 'deposit_paid', 'fully_paid')
      AND res.group_arrived_at  IS NULL
  ) sub
  WHERE r.id     = sub.id
    AND sub.ends_at < NOW();

  GET DIAGNOSTICS v_count = ROW_COUNT;
  RETURN v_count;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.mark_abandoned_reservations() TO authenticated;

COMMIT;

-- ── VERIFICACIONES (correr por separado después del COMMIT) ─────────────────────
-- V1: función ya NO referencia packages, conserva lógica y SECURITY DEFINER
SELECT
  prosecdef                              AS is_security_definer,
  prosrc NOT LIKE '%packages%'           AS sin_packages,          -- esperado true
  prosrc     LIKE '%ends_at%'            AS conserva_logica_ends,  -- esperado true
  prosrc     LIKE '%no_show_grupo%'      AS conserva_set_cancel,   -- esperado true
  prosrc     LIKE '%qte.duration_hours%' AS usa_quote_duration     -- esperado true
FROM pg_proc
WHERE proname = 'mark_abandoned_reservations';
-- Esperado: true | true | true | true | true

-- V2: vista previa — candidatos actuales SIN tumbar el cron (ya no JOIN a packages)
SELECT
  res.folio,
  res.event_date,
  res.event_time,
  COALESCE(res.hours_count, qte.duration_hours, 4) AS dur_h,
  (
    (res.event_date + COALESCE(res.event_time, '23:59:00'::TIME))
      AT TIME ZONE 'America/Mexico_City'
    + COALESCE(res.hours_count, qte.duration_hours, 4) * INTERVAL '1 hour'
    + INTERVAL '30 minutes'
  ) AS ends_at,
  NOW() AS now_utc,
  res.payment_status,
  res.payout_status
FROM reservations res
LEFT JOIN quotes qte ON qte.id = res.quote_id
WHERE res.status           = 'confirmed'
  AND res.payment_status   IN ('paid', 'deposit_paid', 'fully_paid')
  AND res.group_arrived_at IS NULL;
-- Revisar: filas con ends_at < now_utc serán canceladas en el próximo call.

-- V3: ejecutar el cron manualmente y ver cuántas marcó (ya no truena)
-- SELECT mark_abandoned_reservations();
-- Esperado: INTEGER >= 0 SIN error (antes: excepción por packages inexistente)

SELECT '445_fix_mark_abandoned_drop_packages_join.sql ejecutado ✅' AS status;
