-- ════════════════════════════════════════════════════════════════════
-- 324_fix_connections_event_date.sql
--
-- Bug fix: get_active_booking_connections mostraba grupos como
-- "en camino" aunque su evento fuera la próxima semana.
-- Causa: WHERE incluía 'accepted' y 'confirmed' sin filtro de fecha.
-- Fix: agregar DATE(r.event_date) = CURRENT_DATE — solo el día del evento.
-- ════════════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION public.get_active_booking_connections()
RETURNS TABLE (
  reservation_id   UUID,
  booking_type     TEXT,
  event_status     TEXT,
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
    r.group_id,
    g.name          AS group_name,
    g.profile_image AS group_avatar,
    gl.lat          AS group_lat,
    gl.lng          AS group_lng,
    gl.last_seen    AS group_last_seen,
    r.client_id,
    p.full_name     AS client_name,
    p.avatar_url    AS client_avatar,
    cl.lat          AS client_lat,
    cl.lng          AS client_lng,
    cl.updated_at   AS client_last_seen,
    r.event_started_at,
    r.group_arrived_at,
    r.event_ended_at
  FROM public.reservations r
  JOIN public.groups   g ON g.id  = r.group_id
  JOIN public.profiles p ON p.id  = r.client_id
  LEFT JOIN public.group_locations gl ON (
    gl.group_id = r.group_id
    AND gl.last_seen > NOW() - INTERVAL '10 minutes'
    AND gl.lat IS NOT NULL
    AND NOT (gl.lat = 0 AND gl.lng = 0)
    AND gl.lat BETWEEN -90 AND 90
    AND gl.lng BETWEEN -180 AND 180
  )
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
    AND DATE(r.event_date) = CURRENT_DATE   -- ← SOLO el día del evento
    AND gl.lat IS NOT NULL
    AND cl.lat IS NOT NULL
  ORDER BY r.created_at DESC;
END;
$$;

GRANT EXECUTE ON FUNCTION public.get_active_booking_connections()
  TO authenticated, service_role;

SELECT '324_fix_connections_event_date: solo muestra grupos cuyo evento es hoy ✅' AS status;
