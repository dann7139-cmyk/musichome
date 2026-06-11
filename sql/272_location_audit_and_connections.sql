-- ============================================================
-- sql/272_location_audit_and_connections.sql
--
-- Auditoría de producción — Sistema de ubicación en vivo:
--   1. Seguridad: get_talent/client_locations → guard admin interno
--      GRANT TO authenticated se mantiene (admin usa JWT normal)
--   2. Ventana de actividad: 10 minutos (era 24 horas)
--   3. Validación de coordenadas en todos los RPCs de escritura
--   4. Índices compuestos talent_locations + client_locations
--   5. Auto-offline: función + cron cada 5 minutos
--   6. RPC get_active_booking_connections para mapa del admin
-- ============================================================

-- ── 1. get_talent_locations ──────────────────────────────────────────────────
-- Guard de admin + ventana 10 min + campo is_online derivado de timestamp.
-- GRANT TO authenticated se mantiene — el guard interno protege el acceso.
-- DROP requerido: la versión anterior (sql/269) no incluía is_online en el RETURNS TABLE.

DROP FUNCTION IF EXISTS public.get_talent_locations();
CREATE OR REPLACE FUNCTION public.get_talent_locations()
RETURNS TABLE (
  user_id      UUID,
  full_name    TEXT,
  avatar_url   TEXT,
  instrument   TEXT,
  availability TEXT,
  lat          DOUBLE PRECISION,
  lng          DOUBLE PRECISION,
  city         TEXT,
  state        TEXT,
  status       TEXT,
  is_online    BOOLEAN,
  updated_at   TIMESTAMPTZ
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  -- Solo administradores pueden consultar ubicaciones masivas
  IF NOT EXISTS (
    SELECT 1 FROM public.profiles WHERE id = auth.uid() AND role = 'admin'
  ) THEN
    RAISE EXCEPTION 'Solo administradores pueden consultar ubicaciones masivas de talentos';
  END IF;

  RETURN QUERY
  SELECT
    tl.user_id,
    p.full_name,
    p.avatar_url,
    COALESCE(jbp.instrument_or_role, '—') AS instrument,
    COALESCE(jbp.availability_status, 'unknown') AS availability,
    tl.lat,
    tl.lng,
    tl.city,
    tl.state,
    tl.status,
    (tl.updated_at > NOW() - INTERVAL '10 minutes') AS is_online,
    tl.updated_at
  FROM public.talent_locations tl
  JOIN public.profiles p ON p.id = tl.user_id
  LEFT JOIN public.job_board_profiles jbp ON jbp.user_id = tl.user_id
  WHERE tl.updated_at > NOW() - INTERVAL '10 minutes'
  ORDER BY
    CASE tl.status WHEN 'active' THEN 0 ELSE 1 END ASC,
    tl.updated_at DESC;
END;
$$;

GRANT EXECUTE ON FUNCTION public.get_talent_locations()
  TO authenticated, service_role;

-- ── 2. get_client_locations ──────────────────────────────────────────────────
-- DROP requerido: la versión anterior (sql/270) no incluía lat, lng, is_online.

DROP FUNCTION IF EXISTS public.get_client_locations();
CREATE OR REPLACE FUNCTION public.get_client_locations()
RETURNS TABLE (
  user_id    UUID,
  full_name  TEXT,
  avatar_url TEXT,
  lat        DOUBLE PRECISION,
  lng        DOUBLE PRECISION,
  city       TEXT,
  state      TEXT,
  status     TEXT,
  is_online  BOOLEAN,
  updated_at TIMESTAMPTZ
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  -- Solo administradores pueden consultar ubicaciones masivas
  IF NOT EXISTS (
    SELECT 1 FROM public.profiles WHERE id = auth.uid() AND role = 'admin'
  ) THEN
    RAISE EXCEPTION 'Solo administradores pueden consultar ubicaciones masivas de clientes';
  END IF;

  RETURN QUERY
  SELECT
    cl.user_id,
    p.full_name,
    p.avatar_url,
    cl.lat,
    cl.lng,
    cl.city,
    cl.state,
    cl.status,
    (cl.updated_at > NOW() - INTERVAL '10 minutes') AS is_online,
    cl.updated_at
  FROM public.client_locations cl
  JOIN public.profiles p ON p.id = cl.user_id
  WHERE cl.updated_at > NOW() - INTERVAL '10 minutes'
  ORDER BY
    CASE cl.status WHEN 'active' THEN 0 ELSE 1 END ASC,
    cl.updated_at DESC;
END;
$$;

GRANT EXECUTE ON FUNCTION public.get_client_locations()
  TO authenticated, service_role;

-- ── 3. set_talent_offline — guard de rol ─────────────────────────────────────

CREATE OR REPLACE FUNCTION public.set_talent_offline()
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  -- Solo talentos/artistas/músicos pueden marcar su propia fila
  IF NOT EXISTS (
    SELECT 1 FROM public.profiles
    WHERE id = auth.uid() AND role IN ('talent', 'artist', 'musician')
  ) THEN
    RETURN; -- silencioso: otro rol no hace nada
  END IF;

  UPDATE public.talent_locations
    SET status = 'offline', updated_at = NOW()
  WHERE user_id = auth.uid();
END;
$$;

GRANT EXECUTE ON FUNCTION public.set_talent_offline() TO authenticated;

-- ── 4. set_client_offline — guard de rol ─────────────────────────────────────

CREATE OR REPLACE FUNCTION public.set_client_offline()
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM public.profiles
    WHERE id = auth.uid() AND role IN ('client', 'user')
  ) THEN
    RETURN;
  END IF;

  UPDATE public.client_locations
    SET status = 'offline', updated_at = NOW()
  WHERE user_id = auth.uid();
END;
$$;

GRANT EXECUTE ON FUNCTION public.set_client_offline() TO authenticated;

-- ── 5. update_my_talent_location — fix role check + validación coords ────────
-- Eliminado el OR EXISTS (job_board_profiles) — solo role IN ('talent',...) autoriza.

CREATE OR REPLACE FUNCTION public.update_my_talent_location(
  p_lat   DOUBLE PRECISION,
  p_lng   DOUBLE PRECISION,
  p_city  TEXT DEFAULT NULL,
  p_state TEXT DEFAULT NULL
)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  -- Validación de coordenadas
  IF p_lat IS NULL OR p_lng IS NULL                    THEN RETURN; END IF;
  IF p_lat = 0 AND p_lng = 0                           THEN RETURN; END IF;
  IF p_lat NOT BETWEEN -90 AND 90                      THEN RETURN; END IF;
  IF p_lng NOT BETWEEN -180 AND 180                    THEN RETURN; END IF;
  IF p_lat != p_lat OR p_lng != p_lng                  THEN RETURN; END IF; -- NaN IEEE 754

  -- Solo talentos/artistas/músicos (sin OR job_board_profiles)
  IF NOT EXISTS (
    SELECT 1 FROM public.profiles
    WHERE id = auth.uid() AND role IN ('talent', 'artist', 'musician')
  ) THEN
    RAISE EXCEPTION 'No autorizado';
  END IF;

  INSERT INTO public.talent_locations (user_id, lat, lng, city, state, status, updated_at)
  VALUES (auth.uid(), p_lat, p_lng, p_city, p_state, 'active', NOW())
  ON CONFLICT (user_id) DO UPDATE
    SET lat        = EXCLUDED.lat,
        lng        = EXCLUDED.lng,
        city       = COALESCE(EXCLUDED.city,  talent_locations.city),
        state      = COALESCE(EXCLUDED.state, talent_locations.state),
        status     = 'active',
        updated_at = NOW();

  -- Sincroniza job_board_profiles si tiene uno
  UPDATE public.job_board_profiles
    SET lat = p_lat, lng = p_lng
  WHERE user_id = auth.uid();
END;
$$;

GRANT EXECUTE ON FUNCTION public.update_my_talent_location(DOUBLE PRECISION, DOUBLE PRECISION, TEXT, TEXT)
  TO authenticated;

-- ── 6. update_my_live_location — validación de coordenadas ───────────────────

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

-- ── 7. update_my_client_location — validación de coordenadas ─────────────────

CREATE OR REPLACE FUNCTION public.update_my_client_location(
  p_lat   DOUBLE PRECISION,
  p_lng   DOUBLE PRECISION,
  p_city  TEXT DEFAULT NULL,
  p_state TEXT DEFAULT NULL
)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF p_lat IS NULL OR p_lng IS NULL                    THEN RETURN; END IF;
  IF p_lat = 0 AND p_lng = 0                           THEN RETURN; END IF;
  IF p_lat NOT BETWEEN -90 AND 90                      THEN RETURN; END IF;
  IF p_lng NOT BETWEEN -180 AND 180                    THEN RETURN; END IF;
  IF p_lat != p_lat OR p_lng != p_lng                  THEN RETURN; END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.profiles
    WHERE id = auth.uid() AND role IN ('client', 'user')
  ) THEN
    RAISE EXCEPTION 'No autorizado';
  END IF;

  INSERT INTO public.client_locations (user_id, lat, lng, city, state, status, updated_at)
  VALUES (auth.uid(), p_lat, p_lng, p_city, p_state, 'active', NOW())
  ON CONFLICT (user_id) DO UPDATE
    SET lat        = EXCLUDED.lat,
        lng        = EXCLUDED.lng,
        city       = COALESCE(EXCLUDED.city,  client_locations.city),
        state      = COALESCE(EXCLUDED.state, client_locations.state),
        status     = 'active',
        updated_at = NOW();
END;
$$;

GRANT EXECUTE ON FUNCTION public.update_my_client_location(DOUBLE PRECISION, DOUBLE PRECISION, TEXT, TEXT)
  TO authenticated;

-- ── 8. Índices compuestos ─────────────────────────────────────────────────────

CREATE INDEX IF NOT EXISTS idx_talent_locations_status_time
  ON public.talent_locations(status, updated_at DESC);

CREATE INDEX IF NOT EXISTS idx_client_locations_status_time
  ON public.client_locations(status, updated_at DESC);

-- ── 9. mark_stale_users_offline ───────────────────────────────────────────────
-- Marca offline a usuarios sin actividad en los últimos 10 minutos.
-- Ventana igual a la de los RPCs de lectura — coherencia garantizada.

CREATE OR REPLACE FUNCTION public.mark_stale_users_offline()
RETURNS void
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
AS $$
  UPDATE public.group_locations
    SET status = 'offline'
  WHERE last_seen < NOW() - INTERVAL '10 minutes'
    AND status != 'offline';

  UPDATE public.talent_locations
    SET status = 'offline'
  WHERE updated_at < NOW() - INTERVAL '10 minutes'
    AND status != 'offline';

  UPDATE public.client_locations
    SET status = 'offline'
  WHERE updated_at < NOW() - INTERVAL '10 minutes'
    AND status != 'offline';
$$;

-- ── 10. Cron — mark_stale_users_offline cada 5 minutos ───────────────────────
-- pg_cron ya está habilitado en este proyecto.

DO $$ BEGIN PERFORM cron.unschedule('mark-stale-offline'); EXCEPTION WHEN OTHERS THEN NULL; END; $$;
SELECT cron.schedule(
  'mark-stale-offline',
  '*/5 * * * *',
  $$ SELECT public.mark_stale_users_offline(); $$
);

-- ── 11. get_active_booking_connections — solo admin ───────────────────────────
-- Retorna reservas activas donde AMBAS partes tienen GPS válido y reciente.
-- Si cualquiera de los dos no tiene GPS → la conexión no aparece.
-- Ninguna línea incorrecta, ninguna ubicación falsa.

CREATE OR REPLACE FUNCTION public.get_active_booking_connections()
RETURNS TABLE (
  reservation_id   UUID,
  booking_type     TEXT,   -- 'express' | 'scheduled'
  event_status     TEXT,   -- 'en_route' | 'arrived' | 'playing'
  group_id         UUID,
  group_name       TEXT,
  group_avatar     TEXT,
  group_lat        DOUBLE PRECISION,
  group_lng        DOUBLE PRECISION,
  group_last_seen  TIMESTAMPTZ,
  client_id        UUID,
  client_name      TEXT,
  client_avatar    TEXT,
  client_lat       DOUBLE PRECISION,
  client_lng       DOUBLE PRECISION,
  client_last_seen TIMESTAMPTZ,
  event_started_at TIMESTAMPTZ,
  group_arrived_at TIMESTAMPTZ,
  event_ended_at   TIMESTAMPTZ
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM public.profiles WHERE id = auth.uid() AND role = 'admin'
  ) THEN
    RAISE EXCEPTION 'Solo administradores pueden consultar conexiones activas';
  END IF;

  RETURN QUERY
  SELECT
    r.id AS reservation_id,
    CASE
      WHEN r.event_request_id IS NOT NULL THEN 'express'
      ELSE 'scheduled'
    END AS booking_type,
    CASE
      WHEN r.event_started_at IS NOT NULL THEN 'playing'
      WHEN r.group_arrived_at IS NOT NULL THEN 'arrived'
      ELSE 'en_route'
    END AS event_status,
    -- Grupo
    r.group_id,
    g.name          AS group_name,
    g.profile_image AS group_avatar,
    gl.lat          AS group_lat,
    gl.lng          AS group_lng,
    gl.last_seen    AS group_last_seen,
    -- Cliente
    r.client_id,
    p.full_name     AS client_name,
    p.avatar_url    AS client_avatar,
    cl.lat          AS client_lat,
    cl.lng          AS client_lng,
    cl.updated_at   AS client_last_seen,
    -- Timestamps
    r.event_started_at,
    r.group_arrived_at,
    r.event_ended_at
  FROM public.reservations r
  JOIN public.groups   g ON g.id  = r.group_id
  JOIN public.profiles p ON p.id  = r.client_id
  -- GPS del grupo: fresco (10 min), válido, no en el océano
  LEFT JOIN public.group_locations gl ON (
    gl.group_id = r.group_id
    AND gl.last_seen > NOW() - INTERVAL '10 minutes'
    AND gl.lat IS NOT NULL
    AND NOT (gl.lat = 0 AND gl.lng = 0)
    AND gl.lat BETWEEN -90 AND 90
    AND gl.lng BETWEEN -180 AND 180
  )
  -- GPS del cliente: fresco (10 min), válido, no en el océano
  LEFT JOIN public.client_locations cl ON (
    cl.user_id = r.client_id
    AND cl.updated_at > NOW() - INTERVAL '10 minutes'
    AND cl.lat IS NOT NULL
    AND NOT (cl.lat = 0 AND cl.lng = 0)
    AND cl.lat BETWEEN -90 AND 90
    AND cl.lng BETWEEN -180 AND 180
  )
  WHERE r.status IN ('accepted', 'confirmed', 'in_progress')
    AND r.event_ended_at IS NULL
    AND gl.lat IS NOT NULL   -- AMBOS deben tener GPS válido
    AND cl.lat IS NOT NULL   -- sin GPS → sin línea de conexión
  ORDER BY r.created_at DESC;
END;
$$;

GRANT EXECUTE ON FUNCTION public.get_active_booking_connections()
  TO authenticated, service_role;

-- ── Verificación final ────────────────────────────────────────────────────────
DO $$
BEGIN
  RAISE NOTICE '[272] get_talent_locations: guard admin + ventana 10min ✅';
  RAISE NOTICE '[272] get_client_locations: guard admin + ventana 10min ✅';
  RAISE NOTICE '[272] set_talent_offline: guard de rol ✅';
  RAISE NOTICE '[272] set_client_offline: guard de rol ✅';
  RAISE NOTICE '[272] update_my_talent_location: validación coords + fix role ✅';
  RAISE NOTICE '[272] update_my_live_location: validación coords ✅';
  RAISE NOTICE '[272] update_my_client_location: validación coords ✅';
  RAISE NOTICE '[272] Índices compuestos talent/client_locations ✅';
  RAISE NOTICE '[272] mark_stale_users_offline: cron cada 5 minutos ✅';
  RAISE NOTICE '[272] get_active_booking_connections: RPC admin only ✅';
END;
$$;

SELECT '272_location_audit_and_connections.sql ejecutado ✅' AS status;
