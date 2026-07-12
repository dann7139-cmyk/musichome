-- ============================================================
-- sql/474_transit_nudges.sql
-- ⏰ EMPUJONES DE PUNTUALIDAD (estilo Uber) — cron cada 5 min (2026-07-11).
--
-- Tres avisos AL GRUPO (una sola vez cada uno, nunca spam):
--   A) NO ha presionado "Voy en camino" y el evento empieza en <45 min
--      → "¿Ya vas en camino? Presiónalo para que el cliente lo sepa."
--   B) Va en camino pero su ubicación DEJÓ de actualizarse >10 min
--      → "¿Todo bien? Si pasó algo, repórtalo."
--   C) Ya pasó la hora de inicio y NO ha marcado llegada
--      → "El evento ya debió empezar — el cliente te espera. ¿Pasó algo?"
--
-- El cliente NO recibe estos (no asustarlo); el grupo sí, para apurarlo.
-- Requiere sql/473 (columnas de tránsito). No toca dinero ni candados.
-- ============================================================

BEGIN;

ALTER TABLE reservations ADD COLUMN IF NOT EXISTS transit_nudge_start_at TIMESTAMPTZ;
ALTER TABLE reservations ADD COLUMN IF NOT EXISTS transit_nudge_stall_at TIMESTAMPTZ;
ALTER TABLE reservations ADD COLUMN IF NOT EXISTS transit_nudge_late_at  TIMESTAMPTZ;

CREATE OR REPLACE FUNCTION public.check_transit_nudges()
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_now   TIMESTAMPTZ := NOW();
  v_r     RECORD;
  v_a INT := 0; v_b INT := 0; v_c INT := 0;
BEGIN
  FOR v_r IN
    SELECT r.id, r.event_time, r.group_en_route_at, r.transit_updated_at,
           r.group_arrived_at, r.transit_nudge_start_at, r.transit_nudge_stall_at,
           r.transit_nudge_late_at, g.owner_id, g.name AS gname,
           ((r.event_date::timestamp + COALESCE(r.event_time, '20:00'::time))
             AT TIME ZONE 'America/Mexico_City') AS evt_ts
    FROM reservations r
    JOIN groups g ON g.id = r.group_id
    WHERE r.event_date BETWEEN (v_now AT TIME ZONE 'America/Mexico_City')::date - 1
                           AND (v_now AT TIME ZONE 'America/Mexico_City')::date + 1
      AND r.status IN ('accepted', 'confirmed', 'in_progress')
      AND r.payment_status IN ('paid', 'fully_paid', 'deposit_paid')
      AND r.group_arrived_at IS NULL
  LOOP
    -- A) No ha salido y el evento empieza en menos de 45 min
    IF v_r.group_en_route_at IS NULL
       AND v_r.transit_nudge_start_at IS NULL
       AND v_now BETWEEN v_r.evt_ts - INTERVAL '45 minutes' AND v_r.evt_ts THEN
      INSERT INTO notifications (user_id, type, title, body, data)
      VALUES (v_r.owner_id, 'reservation',
        '🚐 ¿Ya vas en camino?',
        format('Tu evento empieza a las %s. Presiona "Voy en camino" en tu temporizador para que el cliente sepa que vas — la puntualidad cuida tu reputación.',
               to_char(v_r.evt_ts AT TIME ZONE 'America/Mexico_City', 'HH24:MI')),
        jsonb_build_object('reservation_id', v_r.id, 'screen', 'EventTimer'));
      UPDATE reservations SET transit_nudge_start_at = v_now WHERE id = v_r.id;
      v_a := v_a + 1;
    END IF;

    -- B) En camino pero la ubicación dejó de actualizarse >10 min
    IF v_r.group_en_route_at IS NOT NULL
       AND v_r.transit_nudge_stall_at IS NULL
       AND v_r.transit_updated_at IS NOT NULL
       AND v_r.transit_updated_at < v_now - INTERVAL '10 minutes'
       AND v_now < v_r.evt_ts + INTERVAL '1 hour' THEN
      INSERT INTO notifications (user_id, type, title, body, data)
      VALUES (v_r.owner_id, 'reservation',
        '🚐 ¿Todo bien en el camino?',
        'Tu ubicación dejó de actualizarse. Abre tu temporizador para seguir compartiendo el trayecto — y si pasó algo, repórtalo desde Soporte.',
        jsonb_build_object('reservation_id', v_r.id, 'screen', 'EventTimer'));
      UPDATE reservations SET transit_nudge_stall_at = v_now WHERE id = v_r.id;
      v_b := v_b + 1;
    END IF;

    -- C) Ya pasó la hora de inicio y no ha llegado
    IF v_r.transit_nudge_late_at IS NULL
       AND v_now BETWEEN v_r.evt_ts AND v_r.evt_ts + INTERVAL '40 minutes' THEN
      INSERT INTO notifications (user_id, type, title, body, data)
      VALUES (v_r.owner_id, 'reservation',
        '⏰ El evento ya debió empezar',
        format('Eran las %s y aún no marcas tu llegada. El cliente te espera — si pasó algo, repórtalo desde Soporte para que podamos ayudar.',
               to_char(v_r.evt_ts AT TIME ZONE 'America/Mexico_City', 'HH24:MI')),
        jsonb_build_object('reservation_id', v_r.id, 'screen', 'EventTimer'));
      UPDATE reservations SET transit_nudge_late_at = v_now WHERE id = v_r.id;
      v_c := v_c + 1;
    END IF;
  END LOOP;

  RETURN jsonb_build_object('ok', true, 'sal_nudges', v_a, 'stall_nudges', v_b, 'late_nudges', v_c);
END;
$$;

GRANT EXECUTE ON FUNCTION public.check_transit_nudges() TO service_role;

COMMIT;

-- ── Agendar el cron (cada 5 minutos) — mismo patrón que sql/100 ──────────────
DO $$
BEGIN
  PERFORM cron.unschedule('transit-nudges');
EXCEPTION WHEN OTHERS THEN NULL;
END $$;

DO $$
BEGIN
  PERFORM cron.schedule(
    'transit-nudges',
    '*/5 * * * *',
    $cron$ SELECT public.check_transit_nudges(); $cron$
  );
  RAISE NOTICE 'Cron transit-nudges agendado cada 5 min ✅';
EXCEPTION WHEN OTHERS THEN
  RAISE NOTICE 'pg_cron no disponible: actívalo en Dashboard → Extensions y re-ejecuta este bloque.';
END $$;

-- ── VERIFICACIONES ────────────────────────────────────────────────────────────
SELECT proname FROM pg_proc WHERE proname = 'check_transit_nudges';
-- Esperado: 1 fila

SELECT jobname, schedule FROM cron.job WHERE jobname = 'transit-nudges';
-- Esperado: transit-nudges | */5 * * * *

-- Prueba manual (no manda nada si no hay eventos en ventana):
-- SELECT check_transit_nudges();

SELECT '474_transit_nudges.sql ejecutado ✅' AS status;
