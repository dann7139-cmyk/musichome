-- ════════════════════════════════════════════════════════════════════
-- 323_multi_proposals.sql
--
-- Permite que TODOS los grupos envíen cotización a una solicitud abierta.
-- Antes: solo el primer grupo bloqueaba la solicitud ('en_negociacion').
-- Ahora: múltiples grupos proponen, el cliente compara y elige.
--
-- CAMBIOS:
--   1. Nueva tabla event_request_proposals — una fila por grupo por solicitud
--   2. propose_event_request — upsert en proposals, no bloquea por status
--   3. La solicitud sigue cambiando a 'en_negociacion' en la primera propuesta
--      (para mantener compatibilidad con client_accept_proposal)
--      pero TODOS pueden proponer aunque ya esté 'en_negociacion'
-- ════════════════════════════════════════════════════════════════════

-- ── 1. Tabla de propuestas ────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.event_request_proposals (
  id             UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  request_id     UUID        NOT NULL REFERENCES public.event_requests(id) ON DELETE CASCADE,
  group_id       UUID        NOT NULL REFERENCES public.groups(id)         ON DELETE CASCADE,
  group_owner_id UUID        NOT NULL REFERENCES auth.users(id),
  proposal_data  JSONB       NOT NULL DEFAULT '{}',
  created_at     TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at     TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE(request_id, group_id)
);

CREATE INDEX IF NOT EXISTS idx_erp_request ON public.event_request_proposals(request_id);
CREATE INDEX IF NOT EXISTS idx_erp_group   ON public.event_request_proposals(group_id);

ALTER TABLE public.event_request_proposals ENABLE ROW LEVEL SECURITY;

-- Grupo ve sus propias propuestas
DROP POLICY IF EXISTS "erp_group_own" ON public.event_request_proposals;
CREATE POLICY "erp_group_own"
  ON public.event_request_proposals FOR ALL
  USING (group_owner_id = auth.uid());

-- Cliente ve las propuestas de sus solicitudes
DROP POLICY IF EXISTS "erp_client_view" ON public.event_request_proposals;
CREATE POLICY "erp_client_view"
  ON public.event_request_proposals FOR SELECT
  USING (
    EXISTS (
      SELECT 1 FROM public.event_requests
      WHERE id = request_id AND client_id = auth.uid()
    )
  );

-- Admin ve todo
DROP POLICY IF EXISTS "erp_admin" ON public.event_request_proposals;
CREATE POLICY "erp_admin"
  ON public.event_request_proposals FOR ALL
  USING (
    EXISTS (SELECT 1 FROM public.profiles WHERE id = auth.uid() AND role = 'admin')
  );

GRANT SELECT, INSERT, UPDATE ON public.event_request_proposals TO authenticated;

-- ── 2. propose_event_request: permite múltiples propuestas ───────────────────
--    Diferencia clave: acepta status='open' OR 'en_negociacion'
--    Upsert en event_request_proposals (uno por grupo por solicitud)
--    Mantiene negotiating_group_id + proposal_data para compat con client_accept_proposal

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
  v_req            RECORD;
  v_group          RECORD;
  v_hours          INTEGER;
  v_base_price     NUMERIC;
  v_base_total     NUMERIC;
  v_multiplier     NUMERIC;
  v_group_total    NUMERIC;
  v_client_total   NUMERIC;
  v_express_fee    NUMERIC;
  v_proposal_data  JSONB;
  v_is_first       BOOLEAN;
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

  -- Permitir 'open' Y 'en_negociacion' — ambos aceptan nuevas propuestas
  IF v_req.status NOT IN ('open', 'en_negociacion') THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_available');
  END IF;

  IF v_req.expires_at < NOW() THEN
    RETURN jsonb_build_object('ok', false, 'error', 'request_expired');
  END IF;

  IF v_group.genre <> v_req.genre THEN
    RETURN jsonb_build_object('ok', false, 'error', 'genre_mismatch');
  END IF;

  -- ── Calcular precios ──────────────────────────────────────────────────────
  v_hours      := COALESCE(v_req.hours, 3);
  v_base_price := COALESCE(p_price_per_hour, 0) * v_hours;
  v_base_total := v_base_price + COALESCE(p_travel_cost, 0);

  v_multiplier  := COALESCE(v_req.demand_multiplier, 1.000);
  v_group_total := ROUND(v_base_total * v_multiplier);
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

  -- ── Guardar en proposals (upsert — permite actualizar) ───────────────────
  INSERT INTO public.event_request_proposals
    (request_id, group_id, group_owner_id, proposal_data)
  VALUES
    (p_request_id, v_group.id, auth.uid(), v_proposal_data)
  ON CONFLICT (request_id, group_id)
  DO UPDATE SET
    proposal_data = EXCLUDED.proposal_data,
    updated_at    = NOW();

  -- ── Primera propuesta: marcar solicitud como 'en_negociacion' ─────────────
  -- Las siguientes propuestas de otros grupos no cambian el estado ni
  -- sobreescriben negotiating_group_id (para no romper client_accept_proposal)
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
    'is_update',  NOT v_is_first
  );

EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$$;

GRANT EXECUTE ON FUNCTION public.propose_event_request(UUID, NUMERIC, NUMERIC, NUMERIC, NUMERIC, NUMERIC, TEXT, JSONB, TEXT, TEXT) TO authenticated;

SELECT '323_multi_proposals: event_request_proposals + propose multi-quote ✅' AS status;
