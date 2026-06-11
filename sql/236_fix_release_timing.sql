-- ============================================================
-- sql/236_fix_release_timing.sql
--
-- Fix H1: release_all_eligible_payments — timing correcto
-- ─────────────────────────────────────────────────────────
-- Historial del bug:
--   205a: event_date::TIMESTAMPTZ + 12h
--         → medianoche UTC + 12h = 06:00 MX del día del evento
--         → libera ANTES de que el evento empiece (bug original)
--
--   205d: (event_date + event_time) AT TIME ZONE 'MX' + 12h
--         → cutoff desde hora de INICIO, sin duración mínima
--         → libera 12h después del inicio, no del fin
--         → para evento de 21:00 MX libera a las 09:00 MX siguiente
--         → en la práctica funciona para eventos de 3h, pero no es
--           correcto conceptualmente ni seguro para eventos largos
--
--   210:  misma fórmula de 205d + LIMIT 500 + error handling
--
--   236 (este):
--         (event_date + event_time) AT TIME ZONE 'MX'
--         + 3h (duración mínima estimada)
--         + 12h (período de retención post-evento)
--         → cutoff siempre después del fin mínimo del evento
--
-- Fix M1: eliminar función zombie confirm_full_payment_and_credit_wallet(UUID,TEXT,NUMERIC)
-- ─────────────────────────────────────────────────────────
--   205a creó la firma 3-param.
--   231 eliminó solo la firma 4-param y creó la nueva 4-param (con p_stripe_fee).
--   La 3-param sobrevivió: no acredita admin wallet con MSI fee,
--   no guarda group_earnings ni service_fee_amount en reservations.
--   El stripe-webhook siempre llama con 4 params → usa la correcta.
--   La 3-param es código zombie que puede ser invocado por error.
-- ============================================================

-- ── M1: Eliminar función zombie ───────────────────────────────────────────────
DROP FUNCTION IF EXISTS public.confirm_full_payment_and_credit_wallet(UUID, TEXT, NUMERIC);

-- ── H1: Actualizar release_all_eligible_payments v4 ──────────────────────────
-- Eliminar ambas versiones previas para evitar ambigüedad de firma en PostgreSQL.
-- Después de este DROP, la nueva función con DEFAULT resuelve tanto f() como f(500).
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
      AND r.payout_status = 'held'
      AND r.event_date IS NOT NULL
      AND NOT EXISTS (
        SELECT 1 FROM disputes d
        WHERE d.reservation_id = r.id AND d.status IN ('open', 'under_review')
      )
    ORDER BY r.event_date ASC   -- liberar los más antiguos primero
    LIMIT p_limit
    FOR UPDATE SKIP LOCKED
  LOOP
    -- ── Calcular cutoff correcto ────────────────────────────────────────────
    --
    -- Fórmula:
    --   (event_date + COALESCE(event_time, '23:59:59'))  ← hora del evento en MX
    --   AT TIME ZONE 'America/Mexico_City'               ← convierte a UTC
    --   + INTERVAL '3 hours'                             ← duración mínima del evento
    --   + INTERVAL '12 hours'                            ← retención post-evento
    --
    -- Ejemplo: evento 2026-06-01 21:00 MX
    --   '2026-06-01 21:00:00' AT TIME ZONE 'MX' → 2026-06-02 03:00:00 UTC
    --   + 3h  → 2026-06-02 06:00:00 UTC  (fin mínimo del evento)
    --   + 12h → 2026-06-02 18:00:00 UTC  = 2026-06-02 12:00:00 MX
    --   Release: mediodía MX del día siguiente — nunca antes del fin del evento.
    --
    -- Fallback para event_time NULL: '23:59:59' (conservador — reservas legacy).
    --   '2026-06-01 23:59:59' AT TIME ZONE 'MX' → 2026-06-02 05:59:59 UTC
    --   + 3h  → 2026-06-02 08:59:59 UTC
    --   + 12h → 2026-06-02 20:59:59 UTC  = 2026-06-02 14:59:59 MX
    --   Release: ~15:00 MX del día siguiente.
    --
    -- México eliminó DST en 2022, opera bajo UTC-6 fijo.
    -- 'America/Mexico_City' en la extensión timezone de Postgres refleja UTC-6.
    v_cutoff := (
      (v_row.event_date::TEXT || ' ' ||
       COALESCE(v_row.event_time::TEXT, '23:59:59'))::TIMESTAMP
      AT TIME ZONE 'America/Mexico_City'
      + INTERVAL '3 hours'    -- duración mínima estimada del evento
      + INTERVAL '12 hours'   -- período de retención post-evento
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
        RAISE WARNING '[release_all_v4] Error en reserva %: %', v_row.id, SQLERRM;
      END;
    END IF;
  END LOOP;

  RAISE NOTICE '[release_all_v4] released=% skipped=% errors=% duration_ms=%',
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
  -- Confirmar que la función zombie fue eliminada
  IF EXISTS (
    SELECT 1 FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public'
      AND p.proname = 'confirm_full_payment_and_credit_wallet'
      AND array_length(p.proargtypes, 1) = 3
  ) THEN
    RAISE WARNING '[M1] ALERTA: función zombie (UUID,TEXT,NUMERIC) sigue presente — verificar DROP';
  ELSE
    RAISE NOTICE '[M1] confirm_full_payment_and_credit_wallet(UUID,TEXT,NUMERIC) eliminada ✅';
  END IF;

  -- Confirmar que la versión 0-param no existe (ambigüedad eliminada)
  IF EXISTS (
    SELECT 1 FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public'
      AND p.proname = 'release_all_eligible_payments'
      AND array_length(p.proargtypes, 1) = 0
  ) THEN
    RAISE WARNING '[H1] ALERTA: versión 0-param de release_all_eligible_payments sigue presente';
  ELSE
    RAISE NOTICE '[H1] release_all_eligible_payments(INT DEFAULT 500) activa ✅';
  END IF;
END;
$$;

/*
── ROLLBACK ───────────────────────────────────────────────────────────────────
Para revertir H1 (restaurar fórmula de 210 sin duración mínima):

  DROP FUNCTION IF EXISTS public.release_all_eligible_payments(INT);
  -- Luego re-ejecutar sql/210_release_limit_and_monitoring.sql
  -- O copiar el CREATE OR REPLACE de 210 y ejecutarlo manualmente.

Para revertir M1 (restaurar función zombie — NO RECOMENDADO):
  -- Re-ejecutar el bloque CREATE de sql/205a_hold_release.sql
  -- que define confirm_full_payment_and_credit_wallet(UUID, TEXT, NUMERIC).
  -- Advertencia: la versión zombie no acredita MSI fee al admin.

Nota sobre pg_cron (sql/216_pg_cron_express_locks.sql):
  El cron llama: $$SELECT release_all_eligible_payments()$$
  Con la nueva firma (p_limit INT DEFAULT 500), llamar f() sin argumentos
  resuelve a f(500) — PostgreSQL usa el DEFAULT. No requiere actualizar el cron.
──────────────────────────────────────────────────────────────────────────────
*/

SELECT '236_fix_release_timing.sql: H1 timing corregido + M1 zombie eliminado ✅' AS status;
