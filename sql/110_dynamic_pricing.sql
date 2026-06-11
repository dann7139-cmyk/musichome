-- ════════════════════════════════════════════════════════════════════════════
-- 110_dynamic_pricing.sql
-- Precio dinámico por demanda (multiplicador máximo 15%)
--
-- LO QUE IMPLEMENTA:
--   1. demand_multiplier en event_requests
--   2. get_demand_multiplier() — calcula ratio solicitudes/grupos
--   3. Trigger BEFORE INSERT en event_requests — asigna multiplier automático
--   4. propose_event_request actualizado — aplica multiplier al precio
--   5. notify_high_demand_groups() — notifica grupos cuando hay alta demanda
--
-- Lógica de multiplicador:
--   ratio ≤ 1  → ×1.00 (sin cambio)
--   ratio 1–2  → ×1.05 (+5%)
--   ratio 2–3  → ×1.08 (+8%)
--   ratio 3–4  → ×1.12 (+12%)
--   ratio ≥ 4  → ×1.15 (+15%)  ← máximo absoluto
--   Horas pico (vie/sáb 18-00h): +0.03 extra (cap 1.15)
--
-- Distribución del aumento:
--   El grupo naturalmente recibe ~85% del total (incluyendo aumento),
--   la plataforma ~15%. El ratio de aumento sigue el split normal.
--
-- NO modifica el flujo de pagos ni de reservas.
-- Ejecutar DESPUÉS de 87_start_time_proposal.sql
-- ════════════════════════════════════════════════════════════════════════════


-- ── 1. Columna demand_multiplier en event_requests ───────────────────────────
ALTER TABLE public.event_requests
  ADD COLUMN IF NOT EXISTS demand_multiplier NUMERIC(4,3) NOT NULL DEFAULT 1.000;

COMMENT ON COLUMN public.event_requests.demand_multiplier IS
  'Multiplicador de precio por demanda (1.00-1.15). Se calcula al crear la solicitud.';


-- ── 2. get_demand_multiplier() ───────────────────────────────────────────────
-- Calcula el multiplicador basado en solicitudes activas vs grupos disponibles.
-- También aplica bonus por horas pico (viernes/sábado noche).

CREATE OR REPLACE FUNCTION public.get_demand_multiplier(
  p_city       TEXT,
  p_event_date DATE    DEFAULT NULL,
  p_event_time TIME    DEFAULT NULL
)
RETURNS NUMERIC(4,3)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_active_requests  INT;
  v_available_groups INT;
  v_demand_ratio     NUMERIC;
  v_multiplier       NUMERIC(4,3);
  v_is_peak_hour     BOOLEAN := FALSE;
BEGIN
  -- Horas pico: viernes (DOW=5) o sábado (DOW=6), desde las 18:00
  IF p_event_date IS NOT NULL AND p_event_time IS NOT NULL THEN
    v_is_peak_hour := (
      EXTRACT(DOW FROM p_event_date) IN (5, 6)
      AND p_event_time >= '18:00:00'
    );
  END IF;

  -- Solicitudes abiertas en la ciudad
  SELECT COUNT(*) INTO v_active_requests
  FROM   public.event_requests
  WHERE  LOWER(TRIM(location_city)) = LOWER(TRIM(p_city))
    AND  status IN ('open', 'en_negociacion')
    AND  (expires_at IS NULL OR expires_at > NOW());

  -- Grupos disponibles ahora en la ciudad
  SELECT COUNT(*) INTO v_available_groups
  FROM   public.groups
  WHERE  LOWER(TRIM(city)) = LOWER(TRIM(p_city))
    AND  is_active     = TRUE
    AND  available_now = TRUE;

  -- Fallback: todos los grupos activos si ninguno está "disponible ahora"
  IF v_available_groups = 0 THEN
    SELECT COUNT(*) INTO v_available_groups
    FROM   public.groups
    WHERE  LOWER(TRIM(city)) = LOWER(TRIM(p_city))
      AND  is_active = TRUE;
  END IF;

  -- Evitar división por cero
  IF v_available_groups = 0 THEN
    v_demand_ratio := 4.0;
  ELSE
    v_demand_ratio := v_active_requests::NUMERIC / v_available_groups::NUMERIC;
  END IF;

  -- Tabla de multiplicadores
  v_multiplier := CASE
    WHEN v_demand_ratio <= 1 THEN 1.000
    WHEN v_demand_ratio <= 2 THEN 1.050
    WHEN v_demand_ratio <= 3 THEN 1.080
    WHEN v_demand_ratio <= 4 THEN 1.120
    ELSE                          1.150
  END;

  -- Bonus horas pico (+0.03 si ya hay surge, nunca supera 1.15)
  IF v_is_peak_hour AND v_multiplier > 1.000 THEN
    v_multiplier := LEAST(v_multiplier + 0.030, 1.150);
  END IF;

  RETURN v_multiplier;

EXCEPTION WHEN OTHERS THEN
  RETURN 1.000; -- fallback seguro
END;
$$;

GRANT EXECUTE ON FUNCTION public.get_demand_multiplier(TEXT, DATE, TIME) TO authenticated, anon, service_role;


-- ── 3. Trigger: asignar demand_multiplier al crear solicitud ─────────────────
-- Se ejecuta automáticamente en cada INSERT en event_requests.
-- El cliente no necesita hacer nada extra.

CREATE OR REPLACE FUNCTION public.trg_set_demand_multiplier()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_event_time TIME := NULL;
BEGIN
  IF NEW.event_time IS NOT NULL THEN
    BEGIN
      v_event_time := NEW.event_time::TIME;
    EXCEPTION WHEN OTHERS THEN
      v_event_time := NULL;
    END;
  END IF;

  IF NEW.location_city IS NOT NULL THEN
    NEW.demand_multiplier := public.get_demand_multiplier(
      NEW.location_city,
      NEW.event_date,
      v_event_time
    );
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_demand_multiplier ON public.event_requests;
CREATE TRIGGER trg_demand_multiplier
  BEFORE INSERT ON public.event_requests
  FOR EACH ROW
  EXECUTE FUNCTION public.trg_set_demand_multiplier();


-- ── 4. propose_event_request actualizado con precio dinámico ─────────────────
-- Misma firma que SQL 87. Aplica demand_multiplier al total calculado.
-- Guarda base_amount (antes) y total_amount (después de multiplier).

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
  v_base_price     NUMERIC;   -- precio antes del multiplicador
  v_base_total     NUMERIC;   -- subtotal sin multiplier
  v_multiplier     NUMERIC;   -- demand_multiplier de la solicitud
  v_total          NUMERIC;   -- precio final con multiplier
  v_comm           NUMERIC;
  v_earnings       NUMERIC;
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

  IF v_req.status <> 'open' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_available');
  END IF;

  IF v_req.expires_at < NOW() THEN
    RETURN jsonb_build_object('ok', false, 'error', 'request_expired');
  END IF;

  IF v_group.genre <> v_req.genre THEN
    RETURN jsonb_build_object('ok', false, 'error', 'genre_mismatch');
  END IF;

  -- ── Calcular precio base (sin demand multiplier) ──────────────────────────
  v_hours      := COALESCE(v_req.hours, 3);
  v_base_price := COALESCE(p_price_per_hour, 0) * v_hours;
  v_base_total := v_base_price + COALESCE(p_travel_cost, 0);

  -- ── Aplicar multiplicador de demanda ─────────────────────────────────────
  v_multiplier := COALESCE(v_req.demand_multiplier, 1.000);
  v_total      := ROUND(v_base_total * v_multiplier);

  -- ── Comisión y ganancias sobre el precio final ────────────────────────────
  v_comm     := v_hours * 150;   -- comisión fija por hora (igual que antes)
  v_earnings := GREATEST(v_total - v_comm, 0);

  -- ── Actualizar solicitud ──────────────────────────────────────────────────
  UPDATE public.event_requests
  SET
    status               = 'en_negociacion',
    negotiating_group_id = auth.uid(),
    proposal_data        = jsonb_build_object(
      'price_per_hour',    p_price_per_hour,
      'travel_cost',       COALESCE(p_travel_cost, 0),
      'base_price',        v_base_price,
      'base_total',        v_base_total,          -- subtotal antes del multiplier
      'demand_multiplier', v_multiplier,          -- para que el cliente lo vea
      'total_amount',      v_total,               -- precio final que paga el cliente
      'commission_amount', v_comm,
      'group_earnings',    v_earnings,
      'overtime_1h_price', p_overtime_1h,
      'overtime_2h_price', p_overtime_2h,
      'overtime_3h_price', p_overtime_3h,
      'notes',             p_notes,
      'member_dist',       p_member_dist,
      'arrival_time',      p_arrival_time,
      'start_time',        p_start_time
    )
  WHERE id = p_request_id;

  -- ── Notificar al cliente ──────────────────────────────────────────────────
  INSERT INTO public.notifications (user_id, type, title, body, data)
  VALUES (
    v_req.client_id,
    'booking',
    '📋 ¡Recibiste una cotización!',
    '"' || v_group.name || '" quiere tocar en tu evento' ||
    CASE WHEN p_price_per_hour IS NOT NULL
      THEN '. Total: $' || TRUNC(v_total)::TEXT || ' MXN' ||
           CASE
             WHEN p_start_time   IS NOT NULL THEN '. Tocan a las ' || p_start_time || '.'
             WHEN p_arrival_time IS NOT NULL THEN '. Llegan a las ' || p_arrival_time || '.'
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

  RETURN jsonb_build_object(
    'ok',              true,
    'group_name',      v_group.name,
    'group_id',        v_group.id,
    'base_total',      v_base_total,
    'demand_multiplier', v_multiplier,
    'total',           v_total
  );

EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$$;

GRANT EXECUTE ON FUNCTION public.propose_event_request(UUID, NUMERIC, NUMERIC, NUMERIC, NUMERIC, NUMERIC, TEXT, JSONB, TEXT, TEXT) TO authenticated;


-- ── 5. notify_high_demand_groups() ───────────────────────────────────────────
-- Notifica a grupos de una ciudad cuando el multiplier es > 1.
-- Llamar desde un cron job o cuando se crea una solicitud express.

CREATE OR REPLACE FUNCTION public.notify_high_demand_groups(p_city TEXT)
RETURNS INT
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_multiplier NUMERIC;
  v_group      RECORD;
  v_count      INT := 0;
BEGIN
  v_multiplier := public.get_demand_multiplier(p_city);

  -- Solo notificar si hay surge real
  IF v_multiplier <= 1.000 THEN
    RETURN 0;
  END IF;

  -- Notificar grupos activos que NO están en modo "disponible ahora"
  FOR v_group IN
    SELECT owner_id
    FROM   public.groups
    WHERE  LOWER(TRIM(city)) = LOWER(TRIM(p_city))
      AND  is_active     = TRUE
      AND  available_now = FALSE
  LOOP
    INSERT INTO public.notifications (user_id, type, title, body, data)
    VALUES (
      v_group.owner_id,
      'system',
      '🔥 Alta demanda en ' || p_city,
      'Hay muchos eventos solicitados en tu zona. Activa "Disponible ahora" para recibir más solicitudes y aumentar tus ingresos.',
      jsonb_build_object(
        'action', 'activate_availability',
        'city',   p_city,
        'screen', 'Dashboard'
      )
    );
    v_count := v_count + 1;
  END LOOP;

  RETURN v_count;

EXCEPTION WHEN OTHERS THEN
  RETURN 0;
END;
$$;

GRANT EXECUTE ON FUNCTION public.notify_high_demand_groups(TEXT) TO authenticated, service_role;


SELECT '110_dynamic_pricing: multiplicador de demanda (máx 15%) + trigger + notificaciones ✅' AS status;
