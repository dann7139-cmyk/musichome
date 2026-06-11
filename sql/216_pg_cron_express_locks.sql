-- ============================================================
-- 216_pg_cron_express_locks.sql
-- Configura el cron job que libera locks expirados cada minuto.
--
-- REQUISITO: Supabase Pro (pg_cron viene preinstalado).
-- En el plan Free usa la alternativa Edge Function del final.
-- ============================================================

-- ── 1. Habilitar extensión (ya activa en Pro, idempotente) ───────────────────
CREATE EXTENSION IF NOT EXISTS pg_cron;

-- ── 2. Remover job anterior si existe (idempotente) ──────────────────────────
SELECT cron.unschedule('release-express-locks')
WHERE EXISTS (
  SELECT 1 FROM cron.job WHERE jobname = 'release-express-locks'
);

-- ── 3. Programar: cada minuto, liberar locks vencidos y re-broadcastear ──────
SELECT cron.schedule(
  'release-express-locks',          -- nombre del job
  '* * * * *',                      -- cada minuto
  $$SELECT release_expired_express_locks()$$
);

-- ── 4. Verificar que quedó registrado ────────────────────────────────────────
SELECT jobid, jobname, schedule, command, active
FROM cron.job
WHERE jobname = 'release-express-locks';

-- ── 5. (Opcional) Liberar earnings con el mismo cron ─────────────────────────
-- Si ya tienes release_all_eligible_payments() de 210_release_limit_and_monitoring.sql:

SELECT cron.unschedule('release-eligible-payments')
WHERE EXISTS (
  SELECT 1 FROM cron.job WHERE jobname = 'release-eligible-payments'
);

SELECT cron.schedule(
  'release-eligible-payments',
  '*/15 * * * *',                   -- cada 15 minutos
  $$SELECT release_all_eligible_payments()$$
);

-- ============================================================
-- ALTERNATIVA PARA PLAN FREE: Edge Function con schedule
-- ============================================================
-- Si no tienes Pro, crea esta Edge Function en Supabase Dashboard
-- → Edge Functions → New function → "release-express-locks"
-- con el siguiente código Deno:
--
-- import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'
--
-- Deno.serve(async () => {
--   const supabase = createClient(
--     Deno.env.get('SUPABASE_URL')!,
--     Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!,
--   )
--   const { data, error } = await supabase.rpc('release_expired_express_locks')
--   if (error) return new Response(JSON.stringify({ error }), { status: 500 })
--   return new Response(JSON.stringify({ released: data }), { status: 200 })
-- })
--
-- Luego en Dashboard → Edge Functions → release-express-locks
-- → Settings → Cron Schedule: "* * * * *"
-- ============================================================

SELECT '216_pg_cron_express_locks.sql ejecutado ✅' AS status;
