-- ════════════════════════════════════════════════════════════════════
-- 68_accept_creates_reservation.sql
-- Al aceptar una propuesta de solicitud inmediata, se crea
-- automáticamente una reserva (status 'pending') para que el grupo
-- la confirme y el flujo normal de pago/confirmación continúe.
--
-- Cambios:
--   1. ADD COLUMN event_request_id a reservations (trazabilidad)
--   2. ADD COLUMN hours_count a reservations (horas de servicio)
--   3. RLS: grupos ven sus propias solicitudes aceptadas
--   4. client_accept_proposal → crea reserva + notifica
--
-- Ejecutar DESPUÉS de 67_proposal_data.sql
-- ════════════════════════════════════════════════════════════════════

-- ── 1. Columnas extra en reservations ────────────────────────────────────────
ALTER TABLE public.reservations
  ADD COLUMN IF NOT EXISTS event_request_id UUID REFERENCES public.event_requests(id) ON DELETE SET NULL;

ALTER TABLE public.reservations
  ADD COLUMN IF NOT EXISTS hours_count INTEGER;

CREATE INDEX IF NOT EXISTS idx_reservations_event_request
  ON public.reservations(event_request_id);

-- ── 2. RLS: el grupo dueño puede leer sus solicitudes aceptadas ───────────────
DROP POLICY IF EXISTS "er_group_accepted_select" ON public.event_requests;
CREATE POLICY "er_group_accepted_select"
  ON public.event_requests FOR SELECT
  USING (
    status = 'accepted'
    AND EXISTS (
      SELECT 1 FROM public.groups
      WHERE owner_id = auth.uid()
        AND id = event_requests.accepted_by_group_id
    )
  );

-- ── 3. client_accept_proposal actualizado ────────────────────────────────────
--    Crea una reserva en estado 'pending' con los datos del proposal_data.
--    El grupo la ve en su ReservationsScreen y puede confirmarla.
CREATE OR REPLACE FUNCTION public.client_accept_proposal(p_request_id UUID)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_req      RECORD;
  v_group    RECORD;
  v_res_id   UUID;
  v_total    NUMERIC;
  v_comm     NUMERIC;
  v_earnings NUMERIC;
  v_address  TEXT;
BEGIN
  -- Bloquear la fila (evita race condition)
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

  -- Traer datos del grupo que propuso
  SELECT * INTO v_group
  FROM   public.groups
  WHERE  owner_id = v_req.negotiating_group_id
  LIMIT  1;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'group_not_found');
  END IF;

  -- Montos del proposal_data
  v_total    := GREATEST(COALESCE((v_req.proposal_data->>'total_amount')::NUMERIC,    0), 0);
  v_comm     := GREATEST(COALESCE((v_req.proposal_data->>'commission_amount')::NUMERIC, 0), 0);
  v_earnings := GREATEST(COALESCE((v_req.proposal_data->>'group_earnings')::NUMERIC,   0), 0);

  -- Dirección: usar la completa si existe, si no usar ciudad + estado
  v_address := COALESCE(
    NULLIF(v_req.location_address, ''),
    v_req.location_city || ', ' || v_req.location_estado
  );

  -- Crear reserva en 'pending' (grupo confirma → cliente paga)
  INSERT INTO public.reservations (
    group_id,
    client_id,
    event_date,
    event_time,
    address,
    notes,
    total_price,
    platform_commission,
    group_earnings,
    status,
    hours_count,
    event_request_id
  )
  VALUES (
    v_group.id,
    v_req.client_id,
    v_req.event_date,
    v_req.event_time::TIME,
    v_address,
    v_req.proposal_data->>'notes',
    v_total,
    v_comm,
    v_earnings,
    'pending',
    v_req.hours,
    p_request_id
  )
  RETURNING id INTO v_res_id;

  -- Marcar la solicitud como aceptada y enlazar la reserva creada
  UPDATE public.event_requests
  SET
    status                  = 'accepted',
    accepted_by_group_id    = v_group.id,
    accepted_reservation_id = v_res_id
  WHERE id = p_request_id;

  -- Notificar al grupo (además del trigger automático de reserva)
  INSERT INTO public.notifications (user_id, type, title, body, data)
  VALUES (
    v_req.negotiating_group_id,
    'booking',
    '🎉 ¡El cliente aceptó tu propuesta!',
    'El evento del ' || TO_CHAR(v_req.event_date, 'DD/MM/YYYY') ||
    ' en ' || v_req.location_city ||
    ' está listo. Confírmalo para que el cliente pueda pagar.',
    jsonb_build_object(
      'request_id',     p_request_id,
      'reservation_id', v_res_id,
      'screen',         'GroupReservations'
    )
  );

  RETURN jsonb_build_object(
    'ok',             true,
    'group_id',       v_group.id,
    'group_name',     v_group.name,
    'reservation_id', v_res_id
  );

EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$$;

GRANT EXECUTE ON FUNCTION public.client_accept_proposal(UUID) TO authenticated;

SELECT '68_accept_creates_reservation: reserva auto-creada al aceptar propuesta ✅' AS status;
