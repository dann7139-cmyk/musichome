-- ============================================================
-- sql/237_cron_half_released.sql
--
-- Fix W5: release_all_eligible_payments — incluir payout_status='half_released'
-- ─────────────────────────────────────────────────────────
-- Bug W5:
--   sql/236 define el cron con: r.payout_status = 'held'
--   Si el grupo registra llegada (→ 'half_released') pero finishEvent()
--   falla silenciosamente (red, crash), el 50% restante queda bloqueado
--   indefinidamente. El cron nunca lo recoge porque filtra solo 'held'.
--
-- Fix:
--   WHERE payout_status IN ('held', 'half_released')
--   release_group_earnings_atomic ya maneja ambos estados de forma
--   idempotente — detecta qué fracción está pendiente y libera solo esa.
--   FOR UPDATE SKIP LOCKED garantiza seguridad de concurrencia.
--   El cutoff de timing no cambia.
-- ============================================================

DROP FUNCTION IF EXISTS public.release_all_eligible_payments();
DROP FUNCTION IF EXISTS public.release_all_eligible_payments(INT);

CREATE OR REPLACE FUNCTION public.release_all_eligible_payments(
  p_limit INT DEFAULT 500
)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_row      RECORD;
  v_released INT := 0;
  v_skipped  INT := 0;
  v_errors   INT := 0;
  v_result   JSONB;
  v_cutoff   TIMESTAMPTZ;
  v_start    TIMESTAMPTZ := clock_timestamp();
BEGIN
  FOR v_row IN
    SELECT r.id, r.event_date, r.event_time
    FROM reservations r
    WHERE r.payment_status IN ('paid', 'fully_paid', 'deposit_paid')
      AND r.payout_status IN ('held', 'half_released')
      AND r.event_date IS NOT NULL
      AND NOT EXISTS (
        SELECT 1 FROM disputes d
        WHERE d.reservation_id = r.id AND d.status IN ('open', 'under_review')
      )
    ORDER BY r.event_date ASC
    LIMIT p_limit
    FOR UPDATE SKIP LOCKED
  LOOP
    v_cutoff := (
      (v_row.event_date::TEXT || ' ' ||
       COALESCE(v_row.event_time::TEXT, '23:59:59'))::TIMESTAMP
      AT TIME ZONE 'America/Mexico_City'
      + INTERVAL '3 hours'
      + INTERVAL '12 hours'
    );

    IF v_cutoff < NOW() THEN
      BEGIN
        v_result := release_group_earnings_atomic(v_row.id, NULL);
        IF (v_result->>'ok')::BOOLEAN AND NOT (v_result->>'skipped')::BOOLEAN THEN
          v_released := v_released + 1;
        ELSE
          v_skipped := v_skipped + 1;
        END IF;
      EXCEPTION WHEN OTHERS THEN
        v_errors := v_errors + 1;
        RAISE WARNING '[release_all_v5] Error en reserva %: %', v_row.id, SQLERRM;
      END;
    END IF;
  END LOOP;

  RAISE NOTICE '[release_all_v5] released=% skipped=% errors=% duration_ms=%',
    v_released, v_skipped, v_errors,
    EXTRACT(EPOCH FROM (clock_timestamp() - v_start)) * 1000;

  RETURN jsonb_build_object(
    'ok',          true,
    'released',    v_released,
    'skipped',     v_skipped,
    'errors',      v_errors,
    'limit_used',  p_limit,
    'duration_ms', ROUND(EXTRACT(EPOCH FROM (clock_timestamp() - v_start)) * 1000)
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.release_all_eligible_payments(INT) TO service_role;

-- ── Verificación post-deploy ──────────────────────────────────────────────────
DO $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public'
      AND p.proname = 'release_all_eligible_payments'
      AND array_length(p.proargtypes, 1) = 0
  ) THEN
    RAISE WARNING '[W5] ALERTA: versión 0-param sigue presente';
  ELSE
    RAISE NOTICE '[W5] release_all_eligible_payments(INT DEFAULT 500) con half_released activa ✅';
  END IF;
END;
$$;

/*
── ROLLBACK ───────────────────────────────────────────────────────────────────
Para revertir (restaurar versión de sql/236 — solo 'held'):
  DROP FUNCTION IF EXISTS public.release_all_eligible_payments(INT);
  -- Re-ejecutar sql/236_fix_release_timing.sql

Nota: el cron llama $$SELECT release_all_eligible_payments()$$
Con p_limit INT DEFAULT 500, f() sin args resuelve a f(500).
──────────────────────────────────────────────────────────────────────────────
*/

SELECT '237_cron_half_released.sql: W5 half_released incluido en cron ✅' AS status;
