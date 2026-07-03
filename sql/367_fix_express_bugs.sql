-- ════════════════════════════════════════════════════════════════════
-- sql/367_fix_express_bugs.sql
--
-- Prerrequisito: sql/323_multi_proposals.sql ya aplicado
--                (tabla event_request_proposals existe)
--
-- FIXES:
--   BUG 1 — Multi-propuesta: status NOT IN ('open','en_negociacion')
--            + upsert en event_request_proposals (restaura base sql/323)
--   BUG 3 — Guard 2h omitido para solicitudes Express (v_is_express)
--   PLUS  — Ventana Express 3 → 15 min
--            release_expired_express_locks retorna jsonb (antes: void/int)
--
-- NO TOCA: pagos, wallets, Stripe, auth, webhooks.
-- ════════════════════════════════════════════════════════════════════

BEGIN;


-- ── 1. dispatch_express_request: ventana 3 → 15 minutos ──────────────────────

CREATE OR REPLACE FUNCTION public.dispatch_express_request(
  p_request_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_request         public.event_requests%ROWTYPE;
  v_group_row       RECORD;
  v_dispatched      int := 0;
  v_window_minutes  int := 15;
  v_max_groups      int := 10;
BEGIN
  SELECT * INTO v_request
  FROM public.event_requests
  WHERE id = p_request_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'request_not_found');
  END IF;

  IF v_request.status <> 'open' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'request_not_open', 'status', v_request.status);
  END IF;

  FOR v_group_row IN
    SELECT g.id AS group_id
    FROM public.groups g
    WHERE
      g.genre = v_request.genre
      AND (
        lower(trim(g.city))  = lower(trim(v_request.location_city))
        OR lower(trim(g.state)) = lower(trim(v_request.location_estado))
      )
      AND g.is_active = true
      AND g.suspended_at IS NULL
      AND NOT EXISTS (
        SELECT 1 FROM public.express_dispatches ed
        WHERE ed.request_id = p_request_id
          AND ed.group_id   = g.id
      )
    ORDER BY
      (lower(trim(g.city)) = lower(trim(v_request.location_city))) DESC,
      g.is_verified DESC,
      g.rating DESC NULLS LAST
    LIMIT v_max_groups
  LOOP
    INSERT INTO public.express_dispatches (
      request_id, group_id, status, expires_at
    )
    VALUES (
      p_request_id,
      v_group_row.group_id,
      'pending_broadcast',
      NOW() + (v_window_minutes || ' minutes')::interval
    )
    ON CONFLICT DO NOTHING;

    v_dispatched := v_dispatched + 1;
  END LOOP;

  IF v_dispatched > 0 THEN
    UPDATE public.event_requests
    SET express_window_until = NOW() + (v_window_minutes || ' minutes')::interval
    WHERE id = p_request_id;
  END IF;

  RETURN jsonb_build_object(
    'ok',         true,
    'dispatched', v_dispatched,
    'request_id', p_request_id,
    'window_min', v_window_minutes
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.dispatch_express_request(uuid) TO authenticated;


-- ── 2. release_expired_express_locks: DROP + CREATE (tipo cambió a jsonb) ─────

DROP FUNCTION IF EXISTS public.release_expired_express_locks();

CREATE FUNCTION public.release_expired_express_locks()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_released int := 0;
BEGIN
  -- Solo marca dispatches vencidos — NO cambia event_requests.status.
  -- La solicitud sigue 'open' para que otros grupos puedan proponer.
  UPDATE public.express_dispatches
  SET    status     = 'expired',
         updated_at = NOW()
  WHERE  status    IN ('pending_broadcast', 'locked')
    AND  expires_at < NOW();

  GET DIAGNOSTICS v_released = ROW_COUNT;

  RETURN jsonb_build_object(
    'ok',       true,
    'released', v_released,
    'ran_at',   NOW()
  );

EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$$;

GRANT EXECUTE ON FUNCTION public.release_expired_express_locks() TO service_role;


-- ── 3. propose_event_request: sql/323 completo + bypass Express + errores ────
--
--  Cambios respecto a sql/323:
--    · Error granular 'request_expired' para status IN ('expired','cancelled')
--    · v_is_express: detecta dispatch activo → omite guard de 2 horas
--    · Retorna campo 'is_express' en el JSON de éxito

CREATE OR REPLACE FUNCTION public.propose_event_request(
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

  -- BUG 1 FIX: acepta 'open' Y 'en_negociacion' — multi-propuesta
  IF v_req.status NOT IN ('open', 'en_negociacion') THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_available');
  END IF;

  IF v_req.expires_at < NOW() THEN
    RETURN jsonb_build_object('ok', false, 'error', 'request_expired');
  END IF;

  -- BUG 3 FIX: detectar si el grupo viene del canal Express
  SELECT EXISTS (
    SELECT 1 FROM public.express_dispatches ed
    WHERE  ed.request_id = p_request_id
      AND  ed.group_id   = v_group.id
      AND  ed.status     NOT IN ('expired', 'ignored', 'taken')
  ) INTO v_is_express;

  -- Guard de proximidad (2 h) — omitido para Express (por diseño: son eventos urgentes)
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
-- 4 VERIFICACIONES (ejecutar después del COMMIT)
-- ════════════════════════════════════════════════════════════════════

-- V1: Las 3 funciones existen
SELECT routine_name, data_type AS returns
FROM information_schema.routines
WHERE routine_schema = 'public'
  AND routine_name IN (
    'dispatch_express_request',
    'release_expired_express_locks',
    'propose_event_request'
  )
ORDER BY routine_name;

-- V2: release_expired_express_locks retorna jsonb (no void/int)
SELECT data_type
FROM information_schema.routines
WHERE routine_schema = 'public'
  AND routine_name = 'release_expired_express_locks';

-- V3: dispatch_express_request usa ventana 15 min
SELECT position('15' IN pg_get_functiondef(oid)) > 0 AS tiene_15min
FROM pg_proc
WHERE proname = 'dispatch_express_request'
  AND pronamespace = 'public'::regnamespace;

-- V4: propose_event_request acepta 'en_negociacion' (BUG 1 fix)
SELECT position('en_negociacion' IN pg_get_functiondef(oid)) > 0 AS acepta_en_negociacion
FROM pg_proc
WHERE proname = 'propose_event_request'
  AND pronamespace = 'public'::regnamespace;
