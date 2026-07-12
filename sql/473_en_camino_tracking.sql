-- ============================================================
-- sql/473_en_camino_tracking.sql
-- 🚐 "EN CAMINO" — tracking en vivo del grupo hacia el evento (2026-07-11).
--
-- El grupo presiona "En camino" en su temporizador el día del evento:
--   1. Se notifica al cliente ("¡El grupo va en camino!").
--   2. Mientras maneja (timer abierto), su GPS se guarda cada ~15 s.
--   3. El cliente ve la foto del grupo ACERCÁNDOSE en el mapa de su evento
--      (Realtime sobre reservations).
--   4. Al marcar llegada se deja de compartir (solo durante el trayecto).
--
-- NO toca dinero, liberaciones ni el candado GPS de llegada.
-- ============================================================

BEGIN;

ALTER TABLE reservations ADD COLUMN IF NOT EXISTS group_en_route_at  TIMESTAMPTZ;
ALTER TABLE reservations ADD COLUMN IF NOT EXISTS transit_lat        FLOAT8;
ALTER TABLE reservations ADD COLUMN IF NOT EXISTS transit_lng        FLOAT8;
ALTER TABLE reservations ADD COLUMN IF NOT EXISTS transit_updated_at TIMESTAMPTZ;

-- ── RPC única: iniciar el trayecto y/o actualizar posición ────────────────────
-- p_start = true → primera vez (marca en camino + notifica al cliente).
-- Después el grupo manda solo posiciones (p_start = false).
CREATE OR REPLACE FUNCTION public.group_update_transit(
  p_reservation_id UUID,
  p_lat            FLOAT8,
  p_lng            FLOAT8,
  p_start          BOOLEAN DEFAULT FALSE
)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_res        RECORD;
  v_group_name TEXT;
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
  -- Solo reservas activas y ANTES de la llegada (después ya no se comparte)
  IF v_res.group_arrived_at IS NOT NULL THEN
    RETURN jsonb_build_object('ok', true, 'skipped', true, 'reason', 'already_arrived');
  END IF;
  IF v_res.status IN ('cancelled', 'rejected', 'expired', 'completed') THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_active');
  END IF;
  -- Solo el DÍA del evento (hora de México) — no días antes
  IF v_res.event_date IS NOT NULL
     AND v_res.event_date > (NOW() AT TIME ZONE 'America/Mexico_City')::date THEN
    RETURN jsonb_build_object('ok', false, 'error', 'Aún no es el día del evento.');
  END IF;

  UPDATE reservations SET
    group_en_route_at  = COALESCE(group_en_route_at, CASE WHEN p_start THEN NOW() END),
    transit_lat        = p_lat,
    transit_lng        = p_lng,
    transit_updated_at = NOW(),
    updated_at         = NOW()
  WHERE id = p_reservation_id;

  -- Notificar al cliente SOLO la primera vez
  IF p_start AND v_res.group_en_route_at IS NULL THEN
    INSERT INTO notifications (user_id, type, title, body, data)
    VALUES (v_res.client_id, 'reservation',
      '🚐 ¡Tu grupo va en camino!',
      format('%s ya salió hacia tu evento. Puedes ver cómo se acerca en el mapa de tu reserva.',
             COALESCE(v_res.gname, 'El grupo')),
      jsonb_build_object('reservation_id', p_reservation_id, 'screen', 'Reservations'));
  END IF;

  RETURN jsonb_build_object('ok', true, 'en_route_since', COALESCE(v_res.group_en_route_at, NOW()));
END;
$$;

GRANT EXECUTE ON FUNCTION public.group_update_transit(UUID, FLOAT8, FLOAT8, BOOLEAN) TO authenticated;

COMMIT;

-- ── VERIFICACIONES ────────────────────────────────────────────────────────────
SELECT column_name FROM information_schema.columns
WHERE table_name = 'reservations'
  AND column_name IN ('group_en_route_at','transit_lat','transit_lng','transit_updated_at');
-- Esperado: 4 filas

SELECT proname FROM pg_proc WHERE proname = 'group_update_transit';
-- Esperado: 1 fila

SELECT '473_en_camino_tracking.sql ejecutado ✅' AS status;
