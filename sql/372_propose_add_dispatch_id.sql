-- ════════════════════════════════════════════════════════════════════
-- sql/372_propose_add_dispatch_id.sql
--
-- PROBLEMA: v_is_express = false aunque el grupo llegó por flujo Express.
--   Causas posibles:
--     a) El grupo accedió desde OpenRequestsScreen (sin dispatch creado
--        para él) → guard 2h dispara correctamente pero inesperadamente.
--     b) Alguna edge-case donde la consulta por group+request no encuentra
--        el registro aunque exista.
--
-- FIX: Agregar p_dispatch_id UUID DEFAULT NULL.
--   Si el frontend pasa el dispatchId (viene de IncomingExpressScreen o
--   ExpressCarousel), el SQL lo verifica directamente → v_is_express=true.
--   Si no se pasa, el fallback existente por group+request sigue activo.
--
-- CAMBIO ÚNICO respecto a sql/370:
--   - Parámetro p_dispatch_id UUID DEFAULT NULL (posición 11).
--   - Bloque de detección v_is_express usa 2 pasos.
--
-- NO TOCA: pagos, wallets, Stripe, auth, webhooks.
-- ════════════════════════════════════════════════════════════════════

BEGIN;

-- Drop todos los overloads (igual que sql/369)
DO $$
DECLARE r RECORD;
BEGIN
  FOR r IN
    SELECT oid::regprocedure AS sig
    FROM pg_proc
    WHERE proname      = 'propose_event_request'
      AND pronamespace = 'public'::regnamespace
  LOOP
    EXECUTE 'DROP FUNCTION IF EXISTS ' || r.sig || ' CASCADE';
  END LOOP;
END;
$$;

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
  p_start_time     TEXT     DEFAULT NULL,
  p_dispatch_id    UUID     DEFAULT NULL   -- nuevo: Express bypass directo
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
  --    Paso A: el frontend pasó el dispatchId → verificar que pertenece
  --            a este grupo (validación de seguridad).
  IF p_dispatch_id IS NOT NULL THEN
    SELECT EXISTS (
      SELECT 1 FROM public.express_dispatches
      WHERE  id       = p_dispatch_id
        AND  group_id = v_group.id
    ) INTO v_is_express;
  END IF;

  --    Paso B: fallback — buscar cualquier dispatch para este grupo+request
  --            (útil cuando el frontend no pasa dispatchId).
  IF NOT v_is_express THEN
    SELECT EXISTS (
      SELECT 1 FROM public.express_dispatches ed
      WHERE  ed.request_id = p_request_id
        AND  ed.group_id   = v_group.id
    ) INTO v_is_express;
  END IF;

  -- ── 4. Checks de estado ───────────────────────────────────────────────────
  IF v_req.status = 'cancelled' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'request_expired');
  END IF;

  IF v_req.status NOT IN ('open', 'en_negociacion', 'expired') THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_available');
  END IF;

  -- Para solicitudes NO Express: respetar expires_at
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
  UUID, NUMERIC, NUMERIC, NUMERIC, NUMERIC, NUMERIC, TEXT, JSONB, TEXT, TEXT, UUID
) TO authenticated;

COMMIT;


-- ════════════════════════════════════════════════════════════════════
-- VERIFICACIONES
-- ════════════════════════════════════════════════════════════════════

-- V1: 1 solo overload
SELECT COUNT(*) AS total_overloads
FROM pg_proc
WHERE proname      = 'propose_event_request'
  AND pronamespace = 'public'::regnamespace;

-- V2: El overload tiene 11 argumentos (p_dispatch_id añadido)
SELECT pronargs AS num_args
FROM pg_proc
WHERE proname      = 'propose_event_request'
  AND pronamespace = 'public'::regnamespace;

-- V3: v_is_express detectado antes de expires_at
SELECT
  position('v_is_express' IN pg_get_functiondef(oid)) <
  position('expires_at'   IN pg_get_functiondef(oid)) AS express_antes_que_expires
FROM pg_proc
WHERE proname      = 'propose_event_request'
  AND pronamespace = 'public'::regnamespace;

-- V4: Guard 2h sigue protegido por NOT v_is_express
SELECT position('NOT v_is_express' IN pg_get_functiondef(oid)) > 0 AS guard_protegido
FROM pg_proc
WHERE proname      = 'propose_event_request'
  AND pronamespace = 'public'::regnamespace;
