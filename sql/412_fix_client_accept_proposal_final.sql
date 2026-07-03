-- ════════════════════════════════════════════════════════════════════
-- sql/412_fix_client_accept_proposal_final.sql
--
-- Fix definitivo de client_accept_proposal. Corrige:
--
--   BUG 1 (sql/364): busca grupo con WHERE id = negotiating_group_id
--          pero ese campo guarda el auth.uid() del dueño, NO el groups.id
--          → group_not_found siempre → botón "Contratar y pagar" muestra
--            Alert en lugar de navegar a pago.
--
--   BUG 2 (H2): la reserva express quedaba sin arrival_code si el
--          trigger de sql/380 aún no había sido aplicado.
--
-- FIX:
--   1. break_type en event_requests (IF NOT EXISTS — idempotente)
--   2. Correcto WHERE owner_id = v_req.negotiating_group_id LIMIT 1
--   3. arrival_code generado en el RPC (el trigger de sql/380 lo respeta)
--
-- Seguro de correr múltiples veces.
-- ════════════════════════════════════════════════════════════════════

-- ── 1. Columna break_type en event_requests (si no existe) ───────────────────
ALTER TABLE public.event_requests
  ADD COLUMN IF NOT EXISTS break_type TEXT NOT NULL DEFAULT 'A';

-- ── 2. client_accept_proposal — versión final correcta ───────────────────────
CREATE OR REPLACE FUNCTION public.client_accept_proposal(p_request_id UUID)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_req          RECORD;
  v_group        RECORD;
  v_client_total NUMERIC;
  v_group_price  NUMERIC;
  v_commission   NUMERIC;
  v_res_id       UUID;
  v_hours        INT;
  v_code         TEXT;
BEGIN
  -- Leer solicitud
  SELECT * INTO v_req
  FROM   public.event_requests
  WHERE  id = p_request_id;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'request_not_found');
  END IF;

  -- Solo el cliente dueño puede aceptar
  IF v_req.client_id <> auth.uid() THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_owner');
  END IF;

  -- Debe estar en negociación
  IF v_req.status <> 'en_negociacion' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_in_negotiation');
  END IF;

  IF v_req.negotiating_group_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'no_group');
  END IF;

  -- FIX: negotiating_group_id = owner user_id → buscar por owner_id
  SELECT * INTO v_group
  FROM   public.groups
  WHERE  owner_id = v_req.negotiating_group_id
  LIMIT  1;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'group_not_found');
  END IF;

  -- Calcular montos desde proposal_data
  v_hours := COALESCE(v_req.hours, 1);

  v_client_total := COALESCE(
    (v_req.proposal_data->>'total_amount')::NUMERIC,
    (v_req.proposal_data->>'group_price')::NUMERIC,
    (v_req.proposal_data->>'total')::NUMERIC,
    0
  );
  v_group_price := COALESCE(
    (v_req.proposal_data->>'group_price')::NUMERIC,
    (v_req.proposal_data->>'group_earnings')::NUMERIC,
    ROUND(v_client_total / 1.15),
    0
  );
  v_commission := v_client_total - v_group_price;

  -- Generar arrival_code de 4 dígitos (el trigger de sql/380 lo respeta si ya existe)
  v_code := LPAD(FLOOR(RANDOM() * 10000)::TEXT, 4, '0');

  -- Crear reserva
  INSERT INTO public.reservations (
    group_id,
    client_id,
    event_date,
    event_time,
    address,
    total_price,
    base_price,
    platform_commission,
    group_earnings,
    status,
    hours_count,
    event_request_id,
    break_type,
    arrival_code
  ) VALUES (
    v_group.id,
    v_req.client_id,
    v_req.event_date,
    COALESCE((v_req.proposal_data->>'start_time'), v_req.event_time::TEXT, '20:00')::TIME,
    COALESCE(v_req.location_address, v_req.location_city, ''),
    v_client_total,
    v_group_price,
    v_commission,
    v_group_price,
    'accepted',
    v_hours,
    p_request_id,
    COALESCE(v_req.break_type, 'A'),
    v_code
  )
  RETURNING id INTO v_res_id;

  -- Marcar solicitud como aceptada
  UPDATE public.event_requests
  SET
    status                  = 'accepted',
    accepted_by_group_id    = v_group.id,
    accepted_reservation_id = v_res_id
  WHERE id = p_request_id;

  RETURN jsonb_build_object(
    'ok',             true,
    'reservation_id', v_res_id,
    'arrival_code',   v_code
  );

EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$$;

GRANT EXECUTE ON FUNCTION public.client_accept_proposal(UUID) TO authenticated;

-- ── Verificación ──────────────────────────────────────────────────────────────
SELECT position('WHERE owner_id = v_req.negotiating_group_id' IN pg_get_functiondef(oid)) > 0
       AS usa_owner_id_correcto
FROM   pg_proc
WHERE  proname = 'client_accept_proposal'
  AND  pronamespace = 'public'::regnamespace;

SELECT '412_fix_client_accept_proposal_final ✅' AS status;
