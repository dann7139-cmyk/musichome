-- ============================================================
-- sql/345_fix_artists_activity_boost_schedule.sql
--
-- PROBLEMA: artists-activity-boost tenía schedule '30 18-04 * * *'
--   El rango 18-04 es inválido en pg_cron (inicio > fin) → nunca disparaba.
--
-- FIX: 3 disparos fijos en los momentos clave de decisión nocturna:
--   18:30 UTC → ~12:30 PM Mexico City (invierno) ← ajusta si necesitas hora local exacta
--   22:30 UTC → ~16:30 PM Mexico City
--   02:30 UTC → ~20:30 PM Mexico City
--
-- NOTA: pg_cron corre en UTC. Si quieres 18:30, 22:30 y 02:30 hora México:
--   México invierno (UTC-6): 00:30, 04:30, 08:30 UTC
--   México verano  (UTC-5): 23:30, 03:30, 07:30 UTC
--   → Usar '30 0,4,8 * * *' cubre el horario de invierno.
--
-- El schedule '30 18,22,2 * * *' es válido y dispara 3 veces al día.
-- La función tiene anti-spam interno de 3h por grupo, así que
-- aunque el horario UTC no coincida exactamente con México,
-- el efecto práctico es correcto (3 notificaciones en la noche local).
-- ============================================================

DO $$ BEGIN
  PERFORM cron.unschedule('artists-activity-boost');
EXCEPTION WHEN OTHERS THEN NULL;
END; $$;

SELECT cron.schedule(
  'artists-activity-boost',
  '30 0,4,8 * * *',
  $$ SELECT public.notify_artists_activity_boost(); $$
);

-- ── Verificación ──────────────────────────────────────────────────────────────
DO $$
DECLARE
  v_schedule TEXT;
BEGIN
  SELECT schedule INTO v_schedule
  FROM   cron.job
  WHERE  jobname = 'artists-activity-boost';

  IF v_schedule IS NOT NULL THEN
    RAISE NOTICE '[345] artists-activity-boost agendado con schedule: % ✅', v_schedule;
  ELSE
    RAISE WARNING '[345] ALERTA: artists-activity-boost NO encontrado en cron.job';
  END IF;
END;
$$;

SELECT jobname, schedule, active
FROM   cron.job
WHERE  jobname = 'artists-activity-boost';

SELECT '345_fix_artists_activity_boost_schedule.sql ejecutado ✅' AS status;
