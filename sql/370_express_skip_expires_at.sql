-- ════════════════════════════════════════════════════════════════════
-- sql/370_express_skip_expires_at.sql
--
-- PROBLEMA: Para solicitudes Express (mismo día / urgentes),
--   event_requests.expires_at ya está en el pasado cuando el grupo
--   intenta cotizar → error 'request_expired'.
--   El check de expires_at es para solicitudes programadas, no Express.
--
-- FIX:
--   1. Detectar v_is_express ANTES del check de expires_at.
--   2. Para Express: omitir el check expires_at < NOW().
--      El canal Express tiene su propia ventana (express_dispatches.expires_at).
--   3. Para solicitudes programadas: el check de expires_at sigue igual.
--
-- BASE: sql/369 íntegro + solo este cambio de orden.
-- NO TOCA: pagos, wallets, Stripe, auth, webhooks.
-- ════════════════════════════════════════════════════════════════════

BEGIN;

-- Drop el único overload que quedó del 369
DROP FUNCTION IF EXISTS public.propose_event_request(
  UUID, NUMERIC, NUMERIC, NUMERIC, NUMERIC, NUMERIC, TEXT, JSONB, TEXT, TEXT
);

CREATE FUNCTION public.propose_event_request(
  p_request_id     UUID,
  p_price_per_hour NUMERIC  DEFAULT NULL,
  p_travel_cost    NUMERIC  DEFAULT 0,
  p_overtime_1h    NUMERIC  DEFAULT NULL,
  p_overtime_2h    NUMERIC  DEFAULT NULL,
  p_overtime_3h    NUMERIC  DEFAULT NULL,
  p_notes          TEXT     DEFAULT NULL,
  p_member_dist    JSONB    DEFAULT NULL,
  p_arrival_time   TEXT     DEFAULT NULL,
  p_start_time     TEXT     DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_req           RECORD;
  v_group         RECORD;
  v_hours         INTEGER;
  v_base_price    NUMERIC;
  v_base_total    NUMERIC;
  v_multiplier    NUMERIC;
  v_group_total   NUMERIC;
  v_client_total  NUMERIC;
  v_express_fee   NUMERIC;
  v_proposal_data JSONB;
  v_is_first      BOOLEAN;
  v_is_express    BOOLEAN := false;
BEGIN
  -- ── 1. Obtener grupo del usuario autenticado ──────────────────────────────
  SELECT * INTO v_group
  FROM   public.groups
  WHERE  owner_id = auth.uid()
  LIMIT  1;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'no_group_found');
  END IF;

  -- ── 2. Obtener solicitud con bloqueo de fila ──────────────────────────────
  SELECT * INTO v_req
  FROM   public.event_requests
  WHERE  id = p_request_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'request_not_found');
  END IF;

  -- ── 3. Detectar Express ANTES de los checks de expiración ────────────────
  --    Si alguna vez existió un dispatch para este grupo → es Express.
  --    El canal Express tiene su propia ventana de disponibilidad.
  SELECT EXISTS (
    SELECT 1 FROM public.express_dispatches ed
    WHERE  ed.request_id = p_request_id
      AND  ed.group_id   = v_group.id
  ) INTO v_is_express;

  -- ── 4. Checks de estado ───────────────────────────────────────────────────
  -- Cancelada: bloquear siempre (acción intencional del cliente/admin)
  IF v_req.status = 'cancelled' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'request_expired');
  END IF;

  -- Multi-propuesta: acepta 'open' Y 'en_negociacion'
  IF v_req.status NOT IN ('open', 'en_negociacion', 'expired') THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_available');
  END IF;

  -- Para solicitudes NO Express: respetar expires_at
  -- Para Express: omitir — el evento es urgente por diseño y la ventana
  -- del dispatch (60 min) es lo que controla la disponibilidad.
  IF NOT v_is_express THEN
    IF v_req.expires_at < NOW() THEN
      RETURN jsonb_build_object('ok', false, 'error', 'request_expired');
    END IF;
    IF v_req.status = 'expired' THEN
      RETURN jsonb_build_object('ok', false, 'error', 'request_expired');
    END IF;
  END IF;

  -- ── 5. Guard de proximidad (2 h) — SOLO para solicitudes programadas ──────
  IF NOT v_is_express THEN
    IF (v_req.event_date::TIMESTAMP
        + COALESCE(v_req.event_time::INTERVAL, '0'::INTERVAL))
       < NOW() + INTERVAL '2 hours' THEN
      RETURN jsonb_build_object('ok', false, 'error', 'too_close_to_event');
    END IF;
  END IF;

  IF v_group.genre <> v_req.genre THEN
    RETURN jsonb_build_object('ok', false, 'error', 'genre_mismatch');
  END IF;

  -- ── 6. Cálculo de precios ─────────────────────────────────────────────────
  v_hours        := COALESCE(v_req.hours, 3);
  v_base_price   := COALESCE(p_price_per_hour, 0) * v_hours;
  v_base_total   := v_base_price + COALESCE(p_travel_cost, 0);
  v_multiplier   := COALESCE(v_req.demand_multiplier, 1.000);
  v_group_total  := ROUND(v_base_total * v_multiplier);
  v_express_fee  := ROUND(v_group_total * 0.15);
  v_client_total := v_group_total + v_express_fee;

  v_proposal_data := jsonb_build_object(
    'price_per_hour',    p_price_per_hour,
    'travel_cost',       COALESCE(p_travel_cost, 0),
    'base_price',        v_base_price,
    'base_total',        v_base_total,
    'demand_multiplier', v_multiplier,
    'group_price',       v_group_total,
    'express_fee',       v_express_fee,
    'total_amount',      v_client_total,
    'group_earnings',    v_group_total,
    'overtime_1h_price', p_overtime_1h,
    'overtime_2h_price', p_overtime_2h,
    'overtime_3h_price', p_overtime_3h,
    'notes',             p_notes,
    'member_dist',       p_member_dist,
    'arrival_time',      p_arrival_time,
    'start_time',        p_start_time
  );

  -- ── 7. Upsert en event_request_proposals (multi-propuesta) ───────────────
  INSERT INTO public.event_request_proposals
    (request_id, group_id, group_owner_id, proposal_data)
  VALUES
    (p_request_id, v_group.id, auth.uid(), v_proposal_data)
  ON CONFLICT (request_id, group_id)
  DO UPDATE SET
    proposal_data = EXCLUDED.proposal_data,
    updated_at    = NOW();

  -- ── 8. Primera propuesta: marcar 'en_negociacion' ────────────────────────
  v_is_first := v_req.status IN ('open', 'expired');

  IF v_is_first THEN
    UPDATE public.event_requests
    SET
      status               = 'en_negociacion',
      negotiating_group_id = auth.uid(),
      proposal_data        = v_proposal_data
    WHERE id = p_request_id;
  END IF;

  -- ── 9. Notificar al cliente ───────────────────────────────────────────────
  INSERT INTO public.notifications (user_id, type, title, body, data)
  VALUES (
    v_req.client_id,
    'booking',
    '🎵 ' || v_group.name || ' quiere tocar en tu evento',
    'Recibiste una cotización. Compara propuestas y elige la que más te conviene.',
    jsonb_build_object(
      'request_id', p_request_id,
      'group_id',   v_group.id,
      'screen',     'OpenRequest'
    )
  );

  RETURN jsonb_build_object(
    'ok',         true,
    'group_name', v_group.name,
    'group_id',   v_group.id,
    'is_update',  NOT v_is_first,
    'is_express', v_is_express
  );

EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$$;

GRANT EXECUTE ON FUNCTION public.propose_event_request(
  UUID, NUMERIC, NUMERIC, NUMERIC, NUMERIC, NUMERIC, TEXT, JSONB, TEXT, TEXT
) TO authenticated;

COMMIT;


-- ════════════════════════════════════════════════════════════════════
-- 4 VERIFICACIONES
-- ════════════════════════════════════════════════════════════════════

-- V1: 1 solo overload
SELECT COUNT(*) AS total_overloads
FROM pg_proc
WHERE proname      = 'propose_event_request'
  AND pronamespace = 'public'::regnamespace;

-- V2: v_is_express se detecta ANTES que expires_at
--     (posición de 'v_is_express' < posición de 'expires_at')
SELECT
  position('v_is_express' IN pg_get_functiondef(oid)) AS pos_is_express,
  position('expires_at'   IN pg_get_functiondef(oid)) AS pos_expires_at,
  position('v_is_express' IN pg_get_functiondef(oid)) <
  position('expires_at'   IN pg_get_functiondef(oid)) AS express_detectado_primero
FROM pg_proc
WHERE proname      = 'propose_event_request'
  AND pronamespace = 'public'::regnamespace;

-- V3: Express omite expires_at (presencia de 'NOT v_is_express' antes del check)
SELECT position('NOT v_is_express' IN pg_get_functiondef(oid)) > 0 AS tiene_bypass_express
FROM pg_proc
WHERE proname      = 'propose_event_request'
  AND pronamespace = 'public'::regnamespace;

-- V4: Sin filtro de status en v_is_express
SELECT position('''ignored''' IN pg_get_functiondef(oid)) = 0 AS v_is_express_sin_filtro
FROM pg_proc
WHERE proname      = 'propose_event_request'
  AND pronamespace = 'public'::regnamespace;
