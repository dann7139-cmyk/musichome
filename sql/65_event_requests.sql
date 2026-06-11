-- ════════════════════════════════════════════════════════════════════
-- 65_event_requests.sql
-- Sistema de Solicitud Inmediata (tipo Uber):
--   El cliente elige un género musical y su solicitud llega a TODOS
--   los grupos de ese género. El primer grupo que acepta se queda
--   con el evento.
--
-- Ejecutar DESPUÉS de los scripts anteriores.
-- ════════════════════════════════════════════════════════════════════

CREATE TABLE IF NOT EXISTS public.event_requests (
  id                      UUID          PRIMARY KEY DEFAULT gen_random_uuid(),
  client_id               UUID          NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,

  -- Género musical solicitado (filtra qué grupos lo ven)
  genre                   TEXT          NOT NULL,

  -- Datos del evento
  event_type              TEXT          NOT NULL,
  event_date              DATE          NOT NULL,
  event_time              TEXT,                        -- 'HH:MM'
  hours                   INTEGER       NOT NULL DEFAULT 3 CHECK (hours >= 1),
  guest_count             INTEGER,

  -- Ubicación  (dirección completa oculta hasta anticipo pagado)
  location_city           TEXT          NOT NULL,
  location_municipio      TEXT,
  location_estado         TEXT          NOT NULL,
  location_address        TEXT,         -- oculta a grupos antes del anticipo

  -- Detalles extra del lugar
  venue_covered           TEXT,
  venue_size              TEXT,
  needs_sound             TEXT,
  comments                TEXT,

  -- Presupuesto orientativo del cliente (opcional)
  budget_max              NUMERIC(12,2),

  -- Estado de la solicitud
  status                  TEXT          NOT NULL DEFAULT 'open'
                            CHECK (status IN ('open', 'accepted', 'cancelled', 'expired')),

  -- Quién la aceptó
  accepted_by_group_id    UUID          REFERENCES public.groups(id),
  accepted_reservation_id UUID          REFERENCES public.reservations(id),

  created_at              TIMESTAMPTZ   NOT NULL DEFAULT NOW(),
  expires_at              TIMESTAMPTZ   NOT NULL DEFAULT NOW() + INTERVAL '48 hours'
);

CREATE INDEX IF NOT EXISTS idx_er_client  ON public.event_requests(client_id);
CREATE INDEX IF NOT EXISTS idx_er_genre   ON public.event_requests(genre);
CREATE INDEX IF NOT EXISTS idx_er_status  ON public.event_requests(status);
CREATE INDEX IF NOT EXISTS idx_er_expires ON public.event_requests(expires_at);
CREATE INDEX IF NOT EXISTS idx_er_date    ON public.event_requests(event_date);

-- ── RLS ──────────────────────────────────────────────────────────────────────
ALTER TABLE public.event_requests ENABLE ROW LEVEL SECURITY;

-- Cliente ve sus propias solicitudes
DROP POLICY IF EXISTS "er_client_select" ON public.event_requests;
CREATE POLICY "er_client_select"
  ON public.event_requests FOR SELECT
  USING (auth.uid() = client_id);

-- Cliente puede crear solicitudes
DROP POLICY IF EXISTS "er_client_insert" ON public.event_requests;
CREATE POLICY "er_client_insert"
  ON public.event_requests FOR INSERT
  WITH CHECK (auth.uid() = client_id);

-- Cliente puede cancelar su propia solicitud
DROP POLICY IF EXISTS "er_client_update" ON public.event_requests;
CREATE POLICY "er_client_update"
  ON public.event_requests FOR UPDATE
  USING (auth.uid() = client_id)
  WITH CHECK (auth.uid() = client_id);

-- Grupos ven SOLO solicitudes abiertas que coinciden con su género
DROP POLICY IF EXISTS "er_group_select" ON public.event_requests;
CREATE POLICY "er_group_select"
  ON public.event_requests FOR SELECT
  USING (
    status     = 'open'
    AND expires_at > NOW()
    AND EXISTS (
      SELECT 1 FROM public.groups
      WHERE owner_id = auth.uid()
        AND genre     = event_requests.genre
    )
  );

-- Admin ve todo
DROP POLICY IF EXISTS "er_admin_all" ON public.event_requests;
CREATE POLICY "er_admin_all"
  ON public.event_requests FOR ALL
  USING (EXISTS (SELECT 1 FROM public.profiles WHERE id = auth.uid() AND role = 'admin'));

-- Service role sin restricción (para Edge Functions)
DROP POLICY IF EXISTS "er_service_all" ON public.event_requests;
CREATE POLICY "er_service_all"
  ON public.event_requests FOR ALL
  USING (true) WITH CHECK (true);

-- ── RPC: obtener solicitudes abiertas para el grupo del usuario ────────────
-- Retorna SOLO las solicitudes que coinciden con el género del grupo del dueño
CREATE OR REPLACE FUNCTION public.get_open_requests_for_group()
RETURNS SETOF public.event_requests
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT er.*
  FROM   public.event_requests er
  JOIN   public.groups          g  ON g.genre = er.genre
  WHERE  g.owner_id    = auth.uid()
    AND  er.status     = 'open'
    AND  er.expires_at > NOW()
  ORDER  BY er.created_at DESC;
$$;

GRANT EXECUTE ON FUNCTION public.get_open_requests_for_group() TO authenticated;

-- ── RPC: aceptar solicitud abierta (primer grupo en aceptar gana) ─────────
CREATE OR REPLACE FUNCTION public.accept_event_request(
  p_request_id UUID
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_request RECORD;
  v_group   RECORD;
BEGIN
  -- Grupo del usuario autenticado
  SELECT * INTO v_group
  FROM   public.groups
  WHERE  owner_id = auth.uid()
  LIMIT  1;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'no_group_found');
  END IF;

  -- Bloquear la fila para evitar race conditions
  SELECT * INTO v_request
  FROM   public.event_requests
  WHERE  id = p_request_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'request_not_found');
  END IF;

  IF v_request.status <> 'open' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'request_already_taken');
  END IF;

  IF v_request.expires_at < NOW() THEN
    RETURN jsonb_build_object('ok', false, 'error', 'request_expired');
  END IF;

  -- Verificar coincidencia de género
  IF v_group.genre <> v_request.genre THEN
    RETURN jsonb_build_object('ok', false, 'error', 'genre_mismatch');
  END IF;

  -- Marcar como aceptada
  UPDATE public.event_requests
  SET status               = 'accepted',
      accepted_by_group_id = v_group.id
  WHERE id = p_request_id;

  -- Notificar al cliente
  INSERT INTO public.notifications (user_id, type, title, body, data)
  VALUES (
    v_request.client_id,
    'booking',
    '🎵 ¡Grupo confirmado!',
    'El grupo "' || v_group.name || '" aceptó tu solicitud para el ' ||
    TO_CHAR(v_request.event_date, 'DD/MM/YYYY') ||
    '. Pronto recibirás los detalles para confirmar el evento.',
    jsonb_build_object(
      'request_id', p_request_id,
      'group_id',   v_group.id,
      'screen',     'ClientRequests'
    )
  );

  -- Notificar al dueño del grupo (confirmación)
  INSERT INTO public.notifications (user_id, type, title, body, data)
  VALUES (
    auth.uid(),
    'booking',
    '✅ Evento aceptado exitosamente',
    'Aceptaste el evento del ' || TO_CHAR(v_request.event_date, 'DD/MM/YYYY') ||
    ' en ' || v_request.location_city || ', ' || v_request.location_estado ||
    '. El cliente será notificado.',
    jsonb_build_object(
      'request_id', p_request_id,
      'screen',     'OpenRequests'
    )
  );

  RETURN jsonb_build_object(
    'ok',         true,
    'request_id', p_request_id,
    'group_id',   v_group.id,
    'client_id',  v_request.client_id,
    'group_name', v_group.name
  );

EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$$;

GRANT EXECUTE ON FUNCTION public.accept_event_request(UUID) TO authenticated;

SELECT '65_event_requests: tabla + RPCs get_open_requests_for_group + accept_event_request ✅' AS status;
