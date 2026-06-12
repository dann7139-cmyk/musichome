-- ============================================================
-- sql/328_location_history.sql
--
-- HISTORIAL DE RUTA para el mapa en vivo del admin.
--
--   1. Tabla group_location_history — un punto por update de GPS
--   2. RLS: lectura solo admin (escritura vía RPC SECURITY DEFINER)
--   3. update_my_live_location v3 — INSERT histórico en el branch
--      de grupo, con throttle de 2 min (anti-duplicados del OS).
--      Solo se ejecuta con GPS real validado → los grupos con
--      ubicación aproximada por ciudad nunca generan historial.
--   4. Retención: cron horario borra registros > 48 horas
--   5. RPC get_group_route(p_group_id, p_hours) — guard admin
--
-- No cambia el UPSERT actual de group_locations ni el Realtime.
-- ============================================================

-- ── 1. Tabla ──────────────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS public.group_location_history (
  id          BIGSERIAL PRIMARY KEY,
  group_id    UUID NOT NULL REFERENCES public.groups(id) ON DELETE CASCADE,
  lat         DOUBLE PRECISION NOT NULL,
  lng         DOUBLE PRECISION NOT NULL,
  recorded_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_glh_group_time
  ON public.group_location_history(group_id, recorded_at DESC);

-- Para el purge por retención
CREATE INDEX IF NOT EXISTS idx_glh_recorded_at
  ON public.group_location_history(recorded_at);

-- ── 2. RLS — lectura solo admin ───────────────────────────────────────────────
-- Los INSERT entran por update_my_live_location (SECURITY DEFINER),
-- que corre como owner y no pasa por RLS. No hay policy de escritura
-- a propósito: nadie escribe directo a esta tabla.

ALTER TABLE public.group_location_history ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "admin_read_location_history" ON public.group_location_history;
CREATE POLICY "admin_read_location_history" ON public.group_location_history
  FOR SELECT
  USING (
    EXISTS (SELECT 1 FROM public.profiles WHERE id = auth.uid() AND role = 'admin')
  );

-- ── 3. update_my_live_location v3 — añade historial en branch grupo ───────────
-- Idéntico a sql/272 + INSERT histórico con throttle de 2 minutos.

CREATE OR REPLACE FUNCTION public.update_my_live_location(
  p_lat   DOUBLE PRECISION,
  p_lng   DOUBLE PRECISION,
  p_city  TEXT DEFAULT NULL,
  p_state TEXT DEFAULT NULL
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_role     TEXT;
  v_group_id UUID;
BEGIN
  -- Validación de coordenadas (5 checks)
  IF p_lat IS NULL OR p_lng IS NULL                    THEN RETURN; END IF;
  IF p_lat = 0 AND p_lng = 0                           THEN RETURN; END IF;
  IF p_lat NOT BETWEEN -90 AND 90                      THEN RETURN; END IF;
  IF p_lng NOT BETWEEN -180 AND 180                    THEN RETURN; END IF;
  IF p_lat != p_lat OR p_lng != p_lng                  THEN RETURN; END IF; -- NaN

  SELECT role INTO v_role FROM public.profiles WHERE id = auth.uid();
  IF v_role IS NULL THEN RETURN; END IF;

  IF v_role = 'group' THEN
    SELECT id INTO v_group_id FROM public.groups WHERE owner_id = auth.uid() LIMIT 1;
    IF v_group_id IS NULL THEN RETURN; END IF;

    INSERT INTO public.group_locations (group_id, lat, lng, city, status, last_seen)
    VALUES (v_group_id, p_lat, p_lng, p_city, 'active', NOW())
    ON CONFLICT (group_id) DO UPDATE
      SET lat       = EXCLUDED.lat,
          lng       = EXCLUDED.lng,
          city      = COALESCE(EXCLUDED.city, group_locations.city),
          status    = 'active',
          last_seen = NOW();

    -- Historial de ruta — solo llega aquí con GPS real validado.
    -- Throttle 2 min: el OS a veces entrega ráfagas de ubicaciones.
    IF NOT EXISTS (
      SELECT 1 FROM public.group_location_history h
      WHERE h.group_id = v_group_id
        AND h.recorded_at > NOW() - INTERVAL '2 minutes'
    ) THEN
      INSERT INTO public.group_location_history (group_id, lat, lng)
      VALUES (v_group_id, p_lat, p_lng);
    END IF;

  ELSIF v_role IN ('talent', 'artist', 'musician') THEN
    INSERT INTO public.talent_locations (user_id, lat, lng, city, state, status, updated_at)
    VALUES (auth.uid(), p_lat, p_lng, p_city, p_state, 'active', NOW())
    ON CONFLICT (user_id) DO UPDATE
      SET lat        = EXCLUDED.lat,
          lng        = EXCLUDED.lng,
          city       = COALESCE(EXCLUDED.city,  talent_locations.city),
          state      = COALESCE(EXCLUDED.state, talent_locations.state),
          status     = 'active',
          updated_at = NOW();

    UPDATE public.job_board_profiles
      SET lat = p_lat, lng = p_lng
    WHERE user_id = auth.uid();

  ELSIF v_role IN ('client', 'user') THEN
    INSERT INTO public.client_locations (user_id, lat, lng, city, state, status, updated_at)
    VALUES (auth.uid(), p_lat, p_lng, p_city, p_state, 'active', NOW())
    ON CONFLICT (user_id) DO UPDATE
      SET lat        = EXCLUDED.lat,
          lng        = EXCLUDED.lng,
          city       = COALESCE(EXCLUDED.city,  client_locations.city),
          state      = COALESCE(EXCLUDED.state, client_locations.state),
          status     = 'active',
          updated_at = NOW();
  END IF;
END;
$$;

GRANT EXECUTE ON FUNCTION public.update_my_live_location(DOUBLE PRECISION, DOUBLE PRECISION, TEXT, TEXT)
  TO authenticated;

-- ── 4. Retención 48h — purge horario con pg_cron ──────────────────────────────

CREATE OR REPLACE FUNCTION public.purge_group_location_history()
RETURNS void
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
AS $$
  DELETE FROM public.group_location_history
  WHERE recorded_at < NOW() - INTERVAL '48 hours';
$$;

DO $$ BEGIN PERFORM cron.unschedule('purge-location-history'); EXCEPTION WHEN OTHERS THEN NULL; END; $$;
SELECT cron.schedule(
  'purge-location-history',
  '17 * * * *',  -- minuto 17 de cada hora (evita pico de :00)
  $$ SELECT public.purge_group_location_history(); $$
);

-- ── 5. RPC get_group_route — guard admin ──────────────────────────────────────

DROP FUNCTION IF EXISTS public.get_group_route(UUID, INT);

CREATE OR REPLACE FUNCTION public.get_group_route(
  p_group_id UUID,
  p_hours    INT DEFAULT 12
)
RETURNS TABLE (
  lat         DOUBLE PRECISION,
  lng         DOUBLE PRECISION,
  recorded_at TIMESTAMPTZ
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_hours INT;
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM public.profiles WHERE id = auth.uid() AND role = 'admin'
  ) THEN
    RAISE EXCEPTION 'Solo administradores pueden consultar rutas de grupos';
  END IF;

  -- Clamp: 1..48 horas (la retención es 48h)
  v_hours := LEAST(GREATEST(COALESCE(p_hours, 12), 1), 48);

  RETURN QUERY
  SELECT h.lat, h.lng, h.recorded_at
  FROM public.group_location_history h
  WHERE h.group_id = p_group_id
    AND h.recorded_at > NOW() - (v_hours || ' hours')::INTERVAL
  ORDER BY h.recorded_at ASC;
END;
$$;

GRANT EXECUTE ON FUNCTION public.get_group_route(UUID, INT)
  TO authenticated, service_role;

-- ── Verificación final ────────────────────────────────────────────────────────
DO $$
BEGIN
  RAISE NOTICE '[328] group_location_history: tabla + índices + RLS admin-only ✅';
  RAISE NOTICE '[328] update_my_live_location v3: historial con throttle 2 min ✅';
  RAISE NOTICE '[328] purge_group_location_history: cron horario, retención 48h ✅';
  RAISE NOTICE '[328] get_group_route: RPC admin only ✅';
END;
$$;

SELECT '328_location_history.sql ejecutado ✅' AS status;
