-- ============================================================
-- sql/475_transit_movement_and_near_arrival.sql
-- Afinación del "En camino" (2026-07-11, tras sql/473 y 474):
--
--   1. "Se detuvo" DE VERDAD: el aviso de detención solo si la posición
--      deja de CAMBIAR (>12 min sin avanzar ~120 m). Si el grupo va
--      avanzando, nunca se le molesta.
--   2. "¡Ya mero llega!" AL CLIENTE: cuando el grupo entra al radio de
--      ~1.5 km del evento → "prepárate para recibirlos" (una sola vez).
--
-- Requiere sql/473 (tránsito) y sql/424 (haversine_m).
-- ============================================================

BEGIN;

ALTER TABLE reservations ADD COLUMN IF NOT EXISTS transit_moved_at         TIMESTAMPTZ;
ALTER TABLE reservations ADD COLUMN IF NOT EXISTS transit_near_notified_at TIMESTAMPTZ;

-- ── group_update_transit v2: detecta avance + avisa "ya mero llega" ──────────
CREATE OR REPLACE FUNCTION public.group_update_transit(
  p_reservation_id UUID,
  p_lat            FLOAT8,
  p_lng            FLOAT8,
  p_start          BOOLEAN DEFAULT FALSE
)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_res        RECORD;
  v_moved      BOOLEAN := FALSE;
  v_ev_lat     FLOAT8;
  v_ev_lng     FLOAT8;
  v_dist_ev    NUMERIC;
BEGIN
  IF auth.uid() IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'unauthorized');
  END IF;

  SELECT r.*, g.owner_id, g.name AS gname
  INTO v_res
  FROM reservations r JOIN groups g ON g.id = r.group_id
  WHERE r.id = p_reservation_id
  FOR UPDATE OF r;

  IF NOT FOUND THEN RETURN jsonb_build_object('ok', false, 'error', 'not_found'); END IF;
  IF v_res.owner_id <> auth.uid() THEN
    RETURN jsonb_build_object('ok', false, 'error', 'forbidden');
  END IF;
  IF v_res.group_arrived_at IS NOT NULL THEN
    RETURN jsonb_build_object('ok', true, 'skipped', true, 'reason', 'already_arrived');
  END IF;
  IF v_res.status IN ('cancelled', 'rejected', 'expired', 'completed') THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_active');
  END IF;

  -- ¿Avanzó? (primer punto cuenta como avance; después, >120 m de la última)
  IF v_res.transit_lat IS NULL
     OR haversine_m(v_res.transit_lat, v_res.transit_lng, p_lat, p_lng) > 120 THEN
    v_moved := TRUE;
  END IF;

  UPDATE reservations SET
    group_en_route_at  = COALESCE(group_en_route_at, CASE WHEN p_start THEN NOW() END),
    transit_lat        = p_lat,
    transit_lng        = p_lng,
    transit_updated_at = NOW(),
    transit_moved_at   = CASE WHEN v_moved THEN NOW() ELSE transit_moved_at END,
    updated_at         = NOW()
  WHERE id = p_reservation_id;

  -- Notificar al cliente SOLO la primera vez que sale
  IF p_start AND v_res.group_en_route_at IS NULL THEN
    INSERT INTO notifications (user_id, type, title, body, data)
    VALUES (v_res.client_id, 'reservation',
      '🚐 ¡Tu grupo va en camino!',
      format('%s ya salió hacia tu evento. Puedes ver cómo se acerca en el mapa de tu reserva.',
             COALESCE(v_res.gname, 'El grupo')),
      jsonb_build_object('reservation_id', p_reservation_id, 'screen', 'Reservations'));
  END IF;

  -- "¡Ya mero llega!" — al entrar al radio de 1.5 km del evento (una vez)
  IF v_res.transit_near_notified_at IS NULL THEN
    v_ev_lat := NULL; v_ev_lng := NULL;
    IF v_res.quote_id IS NOT NULL THEN
      SELECT q.latitude, q.longitude INTO v_ev_lat, v_ev_lng
      FROM quotes q WHERE q.id = v_res.quote_id;
    END IF;
    IF (v_ev_lat IS NULL OR v_ev_lng IS NULL) AND v_res.event_request_id IS NOT NULL THEN
      SELECT COALESCE(er.latitude, er.event_lat), COALESCE(er.longitude, er.event_lng)
      INTO v_ev_lat, v_ev_lng
      FROM event_requests er WHERE er.id = v_res.event_request_id;
    END IF;

    IF v_ev_lat IS NOT NULL AND v_ev_lng IS NOT NULL THEN
      v_dist_ev := haversine_m(p_lat, p_lng, v_ev_lat, v_ev_lng);
      IF v_dist_ev <= 1500 THEN
        INSERT INTO notifications (user_id, type, title, body, data)
        VALUES (v_res.client_id, 'reservation',
          '🎉 ¡Ya mero llega tu grupo!',
          format('%s está a unos minutos de tu evento. ¡Prepárate para recibirlos!',
                 COALESCE(v_res.gname, 'Tu grupo')),
          jsonb_build_object('reservation_id', p_reservation_id, 'screen', 'Reservations'));
        UPDATE reservations SET transit_near_notified_at = NOW() WHERE id = p_reservation_id;
      END IF;
    END IF;
  END IF;

  RETURN jsonb_build_object('ok', true, 'moved', v_moved);
END;
$$;

GRANT EXECUTE ON FUNCTION public.group_update_transit(UUID, FLOAT8, FLOAT8, BOOLEAN) TO authenticated;

-- ── check_transit_nudges v2: "detenido" = SIN AVANZAR (no solo sin reportar) ──
CREATE OR REPLACE FUNCTION public.check_transit_nudges()
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_now   TIMESTAMPTZ := NOW();
  v_r     RECORD;
  v_a INT := 0; v_b INT := 0; v_c INT := 0;
BEGIN
  FOR v_r IN
    SELECT r.id, r.event_time, r.group_en_route_at, r.transit_updated_at,
           r.transit_moved_at, r.group_arrived_at, r.transit_nudge_start_at,
           r.transit_nudge_stall_at, r.transit_nudge_late_at,
           g.owner_id, g.name AS gname,
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

    -- B) En camino pero SIN AVANZAR (>12 min sin moverse ~120 m) o sin señal
    --    (>10 min sin reportar). Si va avanzando, NUNCA se le molesta.
    IF v_r.group_en_route_at IS NOT NULL
       AND v_r.transit_nudge_stall_at IS NULL
       AND v_now < v_r.evt_ts + INTERVAL '1 hour'
       AND (
         COALESCE(v_r.transit_moved_at, v_r.group_en_route_at) < v_now - INTERVAL '12 minutes'
         OR (v_r.transit_updated_at IS NOT NULL AND v_r.transit_updated_at < v_now - INTERVAL '10 minutes')
       ) THEN
      INSERT INTO notifications (user_id, type, title, body, data)
      VALUES (v_r.owner_id, 'reservation',
        '🚐 ¿Todo bien en el camino?',
        'Parece que llevas un rato sin avanzar. Si pasó algo, repórtalo desde Soporte — y recuerda que el cliente te espera.',
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

-- ── VERIFICACIONES ────────────────────────────────────────────────────────────
SELECT prosrc LIKE '%transit_moved_at%' AS detecta_avance
FROM pg_proc WHERE proname = 'group_update_transit';
-- Esperado: true

SELECT prosrc LIKE '%SIN AVANZAR%' AS stall_por_avance
FROM pg_proc WHERE proname = 'check_transit_nudges';
-- Esperado: true

SELECT '475_transit_movement_and_near_arrival.sql ejecutado ✅' AS status;
