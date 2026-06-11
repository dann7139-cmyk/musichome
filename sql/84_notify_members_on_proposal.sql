-- ════════════════════════════════════════════════════════════════════
-- 84_notify_members_on_proposal.sql
-- Cuando el dueño del grupo envía una cotización express, se notifica
-- a todos los integrantes aceptados del grupo:
--   "⚡ Hay una tocada express a las [hora] — estate atento"
-- ════════════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION public.propose_event_request(
  p_request_id     UUID,
  p_price_per_hour NUMERIC  DEFAULT NULL,
  p_travel_cost    NUMERIC  DEFAULT 0,
  p_overtime_1h    NUMERIC  DEFAULT NULL,
  p_overtime_2h    NUMERIC  DEFAULT NULL,
  p_overtime_3h    NUMERIC  DEFAULT NULL,
  p_notes          TEXT     DEFAULT NULL,
  p_member_dist    JSONB    DEFAULT NULL,
  p_arrival_time   TEXT     DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_req     RECORD;
  v_group   RECORD;
  v_hours   NUMERIC;
  v_base    NUMERIC;
  v_total   NUMERIC;
  v_comm    NUMERIC;
  v_member  RECORD;
BEGIN
  -- ── Verificar que auth.uid() es dueño de un grupo ──────────────────
  SELECT * INTO v_group
  FROM   public.groups
  WHERE  owner_id = auth.uid()
  LIMIT  1;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'no_group_found');
  END IF;

  -- ── Obtener y bloquear la solicitud ────────────────────────────────
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

  -- ── Calcular precios ───────────────────────────────────────────────
  v_hours := COALESCE(v_req.hours, 3);
  v_base  := COALESCE(p_price_per_hour, 0) * v_hours;
  v_total := v_base + COALESCE(p_travel_cost, 0);
  v_comm  := CEIL(v_hours) * 150;   -- comisión por hora completa

  -- ── Actualizar la solicitud ────────────────────────────────────────
  UPDATE public.event_requests
  SET
    status               = 'en_negociacion',
    negotiating_group_id = auth.uid(),
    proposal_data        = jsonb_build_object(
      'price_per_hour',    p_price_per_hour,
      'travel_cost',       COALESCE(p_travel_cost, 0),
      'base_price',        v_base,
      'total_amount',      v_total,
      'commission_amount', v_comm,
      'group_earnings',    GREATEST(v_total - v_comm, 0),
      'overtime_1h_price', p_overtime_1h,
      'overtime_2h_price', p_overtime_2h,
      'overtime_3h_price', p_overtime_3h,
      'notes',             p_notes,
      'member_dist',       p_member_dist,
      'arrival_time',      p_arrival_time
    )
  WHERE id = p_request_id;

  -- ── Notificar al cliente ───────────────────────────────────────────
  INSERT INTO public.notifications (user_id, type, title, body, data)
  VALUES (
    v_req.client_id,
    'booking',
    '📋 ¡Recibiste una cotización!',
    '"' || v_group.name || '" quiere tocar en tu evento' ||
    CASE WHEN p_price_per_hour IS NOT NULL
      THEN '. Total: $' || TRUNC(v_total)::TEXT || ' MXN' ||
           CASE WHEN p_arrival_time IS NOT NULL
             THEN '. Llegan a las ' || p_arrival_time || '.'
             ELSE '. Toca para ver la propuesta.'
           END
      ELSE '. Revisa su propuesta y decide si lo contratas.'
    END,
    jsonb_build_object(
      'request_id', p_request_id,
      'group_id',   v_group.id,
      'screen',     'OpenRequest'
    )
  );

  -- ── Notificar a los integrantes del grupo ──────────────────────────
  -- Recorre todos los miembros aceptados del grupo (excluyendo al dueño
  -- que ya sabe que envió la propuesta)
  FOR v_member IN
    SELECT ji.invited_user_id
    FROM   public.job_invitations ji
    WHERE  ji.group_id = v_group.id
      AND  ji.status   = 'accepted'
      AND  ji.invited_user_id <> auth.uid()
  LOOP
    INSERT INTO public.notifications (user_id, type, title, body, data)
    VALUES (
      v_member.invited_user_id,
      'booking',
      '⚡ ¡Posible tocada express!',
      CASE WHEN p_arrival_time IS NOT NULL
        THEN 'Tu grupo cotizó para tocar a las ' || p_arrival_time || '. Estate atento — si el cliente acepta, ¡prepárate!'
        ELSE 'Tu grupo envió una cotización express. Estate atento — si el cliente acepta, ¡prepárate!'
      END,
      jsonb_build_object(
        'request_id', p_request_id,
        'group_id',   v_group.id,
        'screen',     'MemberEvents'
      )
    );
  END LOOP;

  RETURN jsonb_build_object(
    'ok',         true,
    'group_name', v_group.name,
    'group_id',   v_group.id,
    'total',      v_total
  );

EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$$;

GRANT EXECUTE ON FUNCTION public.propose_event_request(UUID, NUMERIC, NUMERIC, NUMERIC, NUMERIC, NUMERIC, TEXT, JSONB, TEXT) TO authenticated;

SELECT '84_notify_members_on_proposal: integrantes notificados al cotizar express ✅' AS status;
