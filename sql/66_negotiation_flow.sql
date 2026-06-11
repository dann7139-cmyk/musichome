-- ════════════════════════════════════════════════════════════════════
-- 66_negotiation_flow.sql
-- Sistema de negociación Uber-style:
--   El grupo "propone" en lugar de confirmar directamente.
--   El cliente recibe la propuesta y puede aceptar o rechazar.
--   Si rechaza → solicitud vuelve a 'open' para otros grupos.
--   Otros grupos ven el estado 'en_negociacion' y se mantienen atentos.
--
-- Ejecutar DESPUÉS de 65_event_requests.sql
-- ════════════════════════════════════════════════════════════════════

-- ── 1. Nueva columna: quién está en negociación actualmente ──────────────────
ALTER TABLE public.event_requests
  ADD COLUMN IF NOT EXISTS negotiating_group_id UUID REFERENCES auth.users(id) ON DELETE SET NULL;

CREATE INDEX IF NOT EXISTS idx_er_negotiating ON public.event_requests(negotiating_group_id);

-- ── 2. Ampliar CHECK de status ────────────────────────────────────────────────
ALTER TABLE public.event_requests
  DROP CONSTRAINT IF EXISTS event_requests_status_check;

ALTER TABLE public.event_requests
  ADD CONSTRAINT event_requests_status_check
  CHECK (status IN ('open', 'en_negociacion', 'accepted', 'cancelled', 'expired'));

-- ── 3. RLS: grupos también ven solicitudes en_negociacion ─────────────────────
--    (para que se mantengan atentos en caso de que el cliente rechace)
DROP POLICY IF EXISTS "er_group_select" ON public.event_requests;
CREATE POLICY "er_group_select"
  ON public.event_requests FOR SELECT
  USING (
    status IN ('open', 'en_negociacion')
    AND expires_at > NOW()
    AND EXISTS (
      SELECT 1 FROM public.groups
      WHERE owner_id = auth.uid()
        AND genre    = event_requests.genre
    )
  );

-- ── 4. RPC: Grupo propone manejar la solicitud ────────────────────────────────
--    → Estado: 'en_negociacion'  |  cliente recibe notificación
CREATE OR REPLACE FUNCTION public.propose_event_request(p_request_id UUID)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_req   RECORD;
  v_group RECORD;
BEGIN
  SELECT * INTO v_group
  FROM   public.groups
  WHERE  owner_id = auth.uid()
  LIMIT  1;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'no_group_found');
  END IF;

  -- Bloquear fila (evita race condition)
  SELECT * INTO v_req
  FROM   public.event_requests
  WHERE  id = p_request_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'request_not_found');
  END IF;

  IF v_req.status <> 'open' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_available');
  END IF;

  IF v_req.expires_at < NOW() THEN
    RETURN jsonb_build_object('ok', false, 'error', 'request_expired');
  END IF;

  IF v_group.genre <> v_req.genre THEN
    RETURN jsonb_build_object('ok', false, 'error', 'genre_mismatch');
  END IF;

  UPDATE public.event_requests
  SET    status               = 'en_negociacion',
         negotiating_group_id = auth.uid()
  WHERE  id = p_request_id;

  -- Notificar al cliente (llega como push aunque no tenga la app abierta)
  INSERT INTO public.notifications (user_id, type, title, body, data)
  VALUES (
    v_req.client_id,
    'booking',
    '🎵 ¡Un grupo quiere tocar en tu evento!',
    '"' || v_group.name || '" está interesado. Revisa su propuesta y decide si lo contratas.',
    jsonb_build_object(
      'request_id', p_request_id,
      'group_id',   v_group.id,
      'screen',     'OpenRequest'
    )
  );

  RETURN jsonb_build_object('ok', true, 'group_name', v_group.name, 'group_id', v_group.id);

EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$$;

GRANT EXECUTE ON FUNCTION public.propose_event_request(UUID) TO authenticated;

-- ── 5. RPC: Cliente acepta la propuesta del grupo ─────────────────────────────
--    → Estado: 'accepted'  |  grupo recibe confirmación push
CREATE OR REPLACE FUNCTION public.client_accept_proposal(p_request_id UUID)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_req   RECORD;
  v_group RECORD;
BEGIN
  SELECT * INTO v_req
  FROM   public.event_requests
  WHERE  id        = p_request_id
    AND  client_id = auth.uid()
  FOR UPDATE;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_found');
  END IF;

  IF v_req.status <> 'en_negociacion' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_in_negotiation');
  END IF;

  SELECT * INTO v_group
  FROM   public.groups
  WHERE  owner_id = v_req.negotiating_group_id
  LIMIT  1;

  UPDATE public.event_requests
  SET    status               = 'accepted',
         accepted_by_group_id = v_group.id
  WHERE  id = p_request_id;

  -- Confirmar al grupo (push aunque esté cerrada la app)
  INSERT INTO public.notifications (user_id, type, title, body, data)
  VALUES (
    v_req.negotiating_group_id,
    'booking',
    '🎉 ¡El cliente aceptó tu propuesta!',
    'El evento del ' || TO_CHAR(v_req.event_date, 'DD/MM/YYYY') ||
    ' en ' || v_req.location_city || ' está confirmado. ¡Prepárate!',
    jsonb_build_object(
      'request_id', p_request_id,
      'screen',     'OpenRequests'
    )
  );

  RETURN jsonb_build_object('ok', true, 'group_id', v_group.id, 'group_name', v_group.name);

EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$$;

GRANT EXECUTE ON FUNCTION public.client_accept_proposal(UUID) TO authenticated;

-- ── 6. RPC: Cliente rechaza la propuesta ──────────────────────────────────────
--    → Estado vuelve a 'open'  |  grupo rechazado recibe notificación
CREATE OR REPLACE FUNCTION public.client_reject_proposal(p_request_id UUID)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_req RECORD;
BEGIN
  SELECT * INTO v_req
  FROM   public.event_requests
  WHERE  id        = p_request_id
    AND  client_id = auth.uid()
  FOR UPDATE;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_found');
  END IF;

  IF v_req.status <> 'en_negociacion' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_in_negotiation');
  END IF;

  -- Notificar al grupo que fue rechazado
  INSERT INTO public.notifications (user_id, type, title, body, data)
  VALUES (
    v_req.negotiating_group_id,
    'booking',
    '❌ El cliente rechazó la propuesta',
    'La solicitud volvió a estar disponible. Otro grupo puede tomarla antes.',
    jsonb_build_object(
      'request_id', p_request_id,
      'screen',     'OpenRequests'
    )
  );

  -- Devolver a 'open' — disponible para todos de nuevo
  UPDATE public.event_requests
  SET    status               = 'open',
         negotiating_group_id = NULL
  WHERE  id = p_request_id;

  RETURN jsonb_build_object('ok', true);

EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$$;

GRANT EXECUTE ON FUNCTION public.client_reject_proposal(UUID) TO authenticated;

-- ── 7. Cron de push: asegurarse de que el job existe ─────────────────────────
-- (Si ya tienes pg_cron configurado, descomenta esto)
-- SELECT cron.schedule(
--   'send-push-every-minute',
--   '* * * * *',
--   $$SELECT net.http_post(
--     url      := current_setting('app.supabase_url') || '/functions/v1/send-push-notification',
--     headers  := jsonb_build_object('Authorization', 'Bearer ' || current_setting('app.service_role_key')),
--     body     := '{}'::jsonb
--   )$$
-- );

SELECT '66_negotiation_flow: propose / client_accept / client_reject + RLS actualizado ✅' AS status;
