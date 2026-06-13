-- ============================================================
-- sql/340_fix_expire_advertisements.sql
--
-- PROBLEMA CONFIRMADO (cron.job_run_details):
--   expire-advertisements falla cada 5 min desde abril.
--   expire_advertisements() intenta SET status='expired' en bid_orders
--   pero la constraint original de 139_bid_payment_flow.sql solo permite:
--     ('pending_payment', 'paid', 'failed')
--   → violación de constraint → UPDATE falla → ROLLBACK → cron reporta error.
--
-- ANÁLISIS DE VALORES FALTANTES:
--   Flujo completo de bid_orders.status:
--     pending_payment → pago iniciado (estado inicial)
--     paid            → pago confirmado por MP/Stripe
--     failed          → pago rechazado/expirado sin pagar
--     expired         → bid vigente expiró (needs adding ← FIX)
--     cancelled       → grupo canceló el bid manualmente (future-proof)
--   No se usan 'refunded' ni 'disputed' en bid_orders (pertenecen a reservations).
--
-- FIX:
--   1. Renombrar/recrear el CHECK añadiendo 'expired' y 'cancelled'.
--   2. Descomentar y registrar el cron expire-advertisements.
-- ============================================================


-- ══════════════════════════════════════════════════════════════
-- PASO 1 — Ver el nombre exacto del constraint antes de droparlo
-- ══════════════════════════════════════════════════════════════
-- Ejecuta primero si quieres confirmar el nombre:
/*
SELECT conname, pg_get_constraintdef(oid) AS definition
FROM   pg_constraint
WHERE  conrelid = 'public.bid_orders'::regclass
  AND  contype  = 'c'
ORDER  BY conname;
*/


-- ══════════════════════════════════════════════════════════════
-- PASO 2 — Ampliar el CHECK de bid_orders.status
-- ══════════════════════════════════════════════════════════════

-- Dropear constraint existente (nombre generado por Postgres al crear
-- la tabla inline; puede ser bid_orders_status_check o bid_orders_check
-- — el DROP IF EXISTS cubre ambos casos).
ALTER TABLE public.bid_orders DROP CONSTRAINT IF EXISTS bid_orders_status_check;
ALTER TABLE public.bid_orders DROP CONSTRAINT IF EXISTS bid_orders_check;

-- Agregar constraint ampliada con todos los valores válidos del ciclo de vida
ALTER TABLE public.bid_orders
  ADD CONSTRAINT bid_orders_status_check
  CHECK (status IN (
    'pending_payment',   -- creado, esperando pago
    'paid',              -- pago confirmado, bid activo
    'failed',            -- pago rechazado/caducó sin pagar
    'expired',           -- bid vigente cuya ventana de tiempo terminó
    'cancelled'          -- grupo canceló el bid antes de que expirara
  ));


-- ══════════════════════════════════════════════════════════════
-- PASO 3 — Verificar que no queden filas huérfanas
--   (bid_orders con status fuera del nuevo CHECK — no debería haber,
--    pero confirma antes de agregar el constraint)
-- ══════════════════════════════════════════════════════════════
DO $$
DECLARE
  v_bad INT;
BEGIN
  SELECT COUNT(*) INTO v_bad
  FROM   public.bid_orders
  WHERE  status NOT IN ('pending_payment','paid','failed','expired','cancelled');

  IF v_bad > 0 THEN
    RAISE WARNING '[340] Hay % fila(s) en bid_orders con status no reconocido — revísalas antes de continuar', v_bad;
  ELSE
    RAISE NOTICE '[340] Todas las filas de bid_orders tienen status válido ✅';
  END IF;
END;
$$;


-- ══════════════════════════════════════════════════════════════
-- PASO 4 — Registrar el cron expire-advertisements
--   (estaba comentado en 192_performance_and_flow_fixes.sql)
-- ══════════════════════════════════════════════════════════════
DO $$ BEGIN
  PERFORM cron.unschedule('expire-advertisements');
EXCEPTION WHEN OTHERS THEN NULL;
END; $$;

SELECT cron.schedule(
  'expire-advertisements',
  '*/5 * * * *',
  $$SELECT public.expire_advertisements();$$
);


-- ══════════════════════════════════════════════════════════════
-- PASO 5 — Ejecutar expire_advertisements() una vez de inmediato
--   para limpiar el backlog acumulado desde abril.
-- ══════════════════════════════════════════════════════════════
SELECT public.expire_advertisements() AS ads_expirados_ahora;


-- ── Verificación ──────────────────────────────────────────────────────────────
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'expire-advertisements') THEN
    RAISE NOTICE '[340] Cron expire-advertisements registrado ✅';
  ELSE
    RAISE WARNING '[340] ALERTA: cron expire-advertisements NO encontrado — verifica pg_cron';
  END IF;

  IF EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE  conrelid = 'public.bid_orders'::regclass
      AND  contype  = 'c'
      AND  pg_get_constraintdef(oid) LIKE '%expired%'
  ) THEN
    RAISE NOTICE '[340] bid_orders.status CHECK ampliado con ''expired'' y ''cancelled'' ✅';
  ELSE
    RAISE WARNING '[340] ALERTA: constraint bid_orders_status_check no encontrado o no tiene ''expired''';
  END IF;
END;
$$;

SELECT '340_fix_expire_advertisements.sql ejecutado ✅' AS status;
