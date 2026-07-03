-- ════════════════════════════════════════════════════════════════════
-- sql/369_fix_v_is_express_detection.sql
--
-- PROBLEMA: 4 overloads de propose_event_request en DB.
--   PostgreSQL puede resolver a una versión antigua que no tiene
--   el bypass Express, devolviendo too_close_to_event.
--
-- SOLUCIÓN:
--   1. Eliminar TODOS los overloads de propose_event_request
--      (dinámico — funciona sin conocer las firmas exactas).
--   2. Crear una única versión correcta.
--   3. Fix de v_is_express: verifica si EXISTIÓ un dispatch
--      para este grupo (cualquier status), no solo activos.
--
-- BASE: sql/367 completo + solo este cambio en v_is_express:
--   ANTES: AND ed.status NOT IN ('expired', 'ignored', 'taken')
--   DESPUÉS: (sin filtro de status)
--
-- NO TOCA: pagos, wallets, Stripe, auth, webhooks.
-- ════════════════════════════════════════════════════════════════════

BEGIN;

-- ── 1. Eliminar TODOS los overloads de propose_event_request ──────────────────
DO $$
DECLARE
  r RECORD;
BEGIN
  FOR r IN
    SELECT oid::regprocedure AS sig
    FROM   pg_proc
    WHERE  proname        = 'propose_event_request'
      AND  pronamespace   = 'public'::regnamespace
  LOOP
    EXECUTE 'DROP FUNCTION IF EXISTS ' || r.sig || ' CASCADE';
  END LOOP;
END;
$$;


-- ── 2. Versión única y correcta de propose_event_request ─────────────────────
--
--   Cambio respecto a sql/367:
--     v_is_express detecta el canal Express verificando si ALGUNA VEZ
--     existió un dispatch para este grupo+request, sin filtro de status.
--     Esto hace que el bypass sea robusto aunque el dispatch haya
--     expirado, sido ignorado o marcado como taken.

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
  SELECT * INTO v_group
  FROM   public.groups
  WHERE  owner_id = auth.uid()
  LIMIT  1;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'no_group_found');
  END IF;

  SELECT * INTO v_req
  FROM   public.event_requests
  WHERE  id = p_request_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'request_not_found');
  END IF;

  -- Error granular: solicitud ya expiró o canceló
  IF v_req.status IN ('expired', 'cancelled') THEN
    RETURN jsonb_build_object('ok', false, 'error', 'request_expired');
  END IF;

  -- Multi-propuesta: acepta 'open' Y 'en_negociacion'
  IF v_req.status NOT IN ('open', 'en_negociacion') THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_available');
  END IF;

  IF v_req.expires_at < NOW() THEN
    RETURN jsonb_build_object('ok', false, 'error', 'request_expired');
  END IF;

  -- Detectar canal Express: ¿ALGUNA VEZ existió un dispatch para este grupo?
  -- Sin filtro de status — el bypass aplica aunque el dispatch haya expirado,
  -- sido ignorado o tomado, porque Express = evento urgente por definición.
  SELECT EXISTS (
    SELECT 1 FROM public.express_dispatches ed
    WHERE  ed.request_id = p_request_id
      AND  ed.group_id   = v_group.id
  ) INTO v_is_express;

  -- Guard de proximidad (2 h) — SOLO para solicitudes programadas (no Express)
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

  -- ── Cálculo de precios ────────────────────────────────────────────────────
  v_hours       := COALESCE(v_req.hours, 3);
  v_base_price  := COALESCE(p_price_per_hour, 0) * v_hours;
  v_base_total  := v_base_price + COALESCE(p_travel_cost, 0);
  v_multiplier  := COALESCE(v_req.demand_multiplier, 1.000);
  v_group_total := ROUND(v_base_total * v_multiplier);
  v_express_fee := ROUND(v_group_total * 0.15);
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

  -- ── Upsert en event_request_proposals (multi-propuesta) ──────────────────
  INSERT INTO public.event_request_proposals
    (request_id, group_id, group_owner_id, proposal_data)
  VALUES
    (p_request_id, v_group.id, auth.uid(), v_proposal_data)
  ON CONFLICT (request_id, group_id)
  DO UPDATE SET
    proposal_data = EXCLUDED.proposal_data,
    updated_at    = NOW();

  -- ── Primera propuesta: marcar 'en_negociacion' (compat. client_accept_proposal)
  v_is_first := v_req.status = 'open';

  IF v_is_first THEN
    UPDATE public.event_requests
    SET
      status               = 'en_negociacion',
      negotiating_group_id = auth.uid(),
      proposal_data        = v_proposal_data
    WHERE id = p_request_id;
  END IF;

  -- ── Notificar al cliente ──────────────────────────────────────────────────
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

-- V1: Solo debe existir 1 overload (los 4 viejos fueron eliminados)
SELECT COUNT(*) AS total_overloads
FROM pg_proc
WHERE proname      = 'propose_event_request'
  AND pronamespace = 'public'::regnamespace;

-- V2: Acepta 'en_negociacion' (BUG 1 fix)
SELECT position('en_negociacion' IN pg_get_functiondef(oid)) > 0 AS acepta_en_negociacion
FROM pg_proc
WHERE proname      = 'propose_event_request'
  AND pronamespace = 'public'::regnamespace;

-- V3: v_is_express SIN filtro de status (BUG 3 fix)
SELECT position('NOT IN' IN pg_get_functiondef(oid)) = 0 AS sin_filtro_status
FROM pg_proc
WHERE proname      = 'propose_event_request'
  AND pronamespace = 'public'::regnamespace;

-- V4: La función retorna is_express en el JSON de éxito
SELECT position('is_express' IN pg_get_functiondef(oid)) > 0 AS retorna_is_express
FROM pg_proc
WHERE proname      = 'propose_event_request'
  AND pronamespace = 'public'::regnamespace;
