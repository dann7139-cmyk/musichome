-- ═══════════════════════════════════════════════════════════════════════════
-- ROLLBACK de sql/718 — recordatorios de cotizaciones pendientes
-- ═══════════════════════════════════════════════════════════════════════════
-- NO SE EJECUTA salvo emergencia deliberada.
--
-- Deja el sistema exactamente como estaba antes de 718: sin cron, sin función,
-- sin índice y sin las tres columnas.
--
-- ⚠ Las columnas se borran al final y por separado, porque borrarlas pierde el
-- historial de qué recordatorio ya se había mandado. Si lo que se quiere es
-- APAGAR los recordatorios sin perder ese historial, corre SOLO el paso 1
-- (desprogramar el cron) y detente ahí: la función queda inerte.
-- ═══════════════════════════════════════════════════════════════════════════

BEGIN;

-- ── 1. Apagar el cron (esto solo ya detiene todo) ──────────────────────────
DO $cron$
BEGIN
  PERFORM cron.unschedule('notify-pending-quotes')
  WHERE EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'notify-pending-quotes');
END
$cron$;

-- ── 2. La función ──────────────────────────────────────────────────────────
DROP FUNCTION IF EXISTS public.notify_pending_quotes();

-- ── 3. El índice ───────────────────────────────────────────────────────────
DROP INDEX IF EXISTS public.idx_quotes_pending_reminders;

-- ── 4. Las columnas (PIERDE EL HISTORIAL — ver la nota de arriba) ──────────
ALTER TABLE public.quotes
  DROP COLUMN IF EXISTS reminder_12h_at,
  DROP COLUMN IF EXISTS reminder_36h_at,
  DROP COLUMN IF EXISTS escalated_48h_at;

-- ── 5. Verificación: expire_stale_quotes sigue intacta y activa ────────────
DO $verify$
BEGIN
  IF (SELECT md5(prosrc) FROM pg_proc WHERE oid = to_regprocedure('public.expire_stale_quotes()'))
     <> '3c47a4175f7baf0b598c400664b13a36' THEN
    RAISE EXCEPTION 'expire_stale_quotes no esta como la auditamos. Revisar a mano.';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'expire-stale-quotes' AND active) THEN
    RAISE EXCEPTION 'El cron expire-stale-quotes no quedo activo. Revisar a mano.';
  END IF;
  IF EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'notify-pending-quotes') THEN
    RAISE EXCEPTION 'El cron notify-pending-quotes sigue existiendo. Revisar a mano.';
  END IF;
END
$verify$;

NOTIFY pgrst, 'reload schema';

COMMIT;
