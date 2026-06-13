-- ============================================================
-- sql/342_purge_location_history.sql
--
-- PROBLEMA: No existe ningún cron que limpie client_locations.
--   Filas de ubicación acumulan indefinidamente.
--
-- FIX: Función + cron diario a las 3 AM UTC (10 PM Mexico City invierno).
--   Borra registros con más de 7 días (configurable).
--   No toca filas de las últimas 24 h (podrían usarse para mapa admin).
-- ============================================================

CREATE OR REPLACE FUNCTION public.purge_old_location_history(
  p_days_to_keep INT DEFAULT 7
)
RETURNS INT
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_deleted INT;
BEGIN
  DELETE FROM public.client_locations
  WHERE updated_at < NOW() - (p_days_to_keep || ' days')::INTERVAL;

  GET DIAGNOSTICS v_deleted = ROW_COUNT;

  IF v_deleted > 0 THEN
    RAISE NOTICE '[purge-location-history] % registro(s) eliminado(s) (> % días)', v_deleted, p_days_to_keep;
  END IF;

  RETURN v_deleted;
END;
$$;

GRANT EXECUTE ON FUNCTION public.purge_old_location_history(INT) TO service_role;


-- ── Cron: diario a las 03:00 UTC (21:00 Mexico City invierno) ────────────────
DO $$ BEGIN
  PERFORM cron.unschedule('purge-location-history');
EXCEPTION WHEN OTHERS THEN NULL;
END; $$;

SELECT cron.schedule(
  'purge-location-history',
  '0 3 * * *',   -- 03:00 UTC diario
  $$SELECT public.purge_old_location_history(7);$$
);


-- ── Verificación ──────────────────────────────────────────────────────────────
DO $$
DECLARE v_total BIGINT;
BEGIN
  IF EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'purge-location-history') THEN
    RAISE NOTICE '[342] Cron purge-location-history registrado (diario 03:00 UTC) ✅';
  ELSE
    RAISE WARNING '[342] ALERTA: cron purge-location-history NO encontrado';
  END IF;

  SELECT COUNT(*) INTO v_total FROM public.client_locations;
  RAISE NOTICE '[342] Filas actuales en client_locations: %', v_total;

  SELECT COUNT(*) INTO v_total
  FROM   public.client_locations
  WHERE  updated_at < NOW() - INTERVAL '7 days';
  RAISE NOTICE '[342] Filas con más de 7 días (se purgarán en el próximo cron): %', v_total;
END;
$$;

SELECT '342_purge_location_history.sql ejecutado ✅' AS status;
