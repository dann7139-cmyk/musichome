-- ════════════════════════════════════════════════════════════════════════════
-- 126_surge_pricing.sql
-- Precios dinámicos (surge) suaves para cotizaciones y solicitudes express.
--
--   1. demand_multiplier en event_requests  — factor almacenado al crear
--   2. get_surge_factor(p_genre, p_city)    — calcula factor en tiempo real
--
-- Lógica:
--   open_requests    = solicitudes 'open' del mismo género (y ciudad si aplica)
--   available_groups = grupos activos del mismo género
--   raw_factor       = open_requests / GREATEST(1, available_groups)
--   surge_factor     = LEAST(1.15, GREATEST(1.0, raw_factor))   ← máx 15%
--
--   factor < 1.03  → low    → sin mensaje
--   factor < 1.08  → medium → mensaje de valor moderado
--   factor >= 1.08 → high   → mensaje de valor con garantía reforzada
--
-- El incremento se distribuye entre el grupo y la plataforma.
-- Los mensajes destacan seguridad y respaldo del servicio — no "alta demanda".
-- No afecta reservas programadas ni el flow de pago existente.
--
-- Ejecutar DESPUÉS de 125_bidding_system.sql
-- ════════════════════════════════════════════════════════════════════════════


-- ── 1. demand_multiplier en event_requests ────────────────────────────────────

ALTER TABLE public.event_requests
  ADD COLUMN IF NOT EXISTS demand_multiplier NUMERIC DEFAULT 1;

-- Solicitudes existentes quedan con multiplier = 1 (sin cambios en pagos).


-- ── 2. get_surge_factor ───────────────────────────────────────────────────────
-- Devuelve el factor de demanda para un género (y ciudad opcional).
-- Llamado por el cliente al seleccionar género y por el grupo antes de cotizar.

DROP FUNCTION IF EXISTS public.get_surge_factor(TEXT, TEXT);
CREATE OR REPLACE FUNCTION public.get_surge_factor(
  p_genre TEXT DEFAULT NULL,
  p_city  TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER STABLE
SET search_path = public
AS $$
DECLARE
  v_open_requests    INT := 0;
  v_available_groups INT := 0;
  v_raw_factor       NUMERIC;
  v_surge_factor     NUMERIC;
  v_level            TEXT;
  v_message          TEXT;
  v_client_message   TEXT;
BEGIN
  -- ── Solicitudes abiertas (aún no aceptadas, no expiradas) ─────────────────
  SELECT COUNT(*) INTO v_open_requests
  FROM public.event_requests
  WHERE status = 'open'
    AND expires_at > now()
    AND (p_genre IS NULL OR genre ILIKE p_genre)
    AND (p_city  IS NULL OR location_city ILIKE p_city);

  -- ── Grupos disponibles del mismo género ───────────────────────────────────
  SELECT COUNT(*) INTO v_available_groups
  FROM public.groups
  WHERE is_active = true
    AND (p_genre IS NULL OR genre ILIKE p_genre);

  -- ── Calcular factor ───────────────────────────────────────────────────────
  -- Máximo 15% sobre precio base → nunca excesivo frente al mercado
  v_raw_factor   := v_open_requests::NUMERIC / GREATEST(1, v_available_groups);
  v_surge_factor := LEAST(1.15, GREATEST(1.0, ROUND(v_raw_factor, 2)));

  -- ── Determinar nivel y mensaje ────────────────────────────────────────────
  -- Mensajes orientados al valor percibido, no a "alta demanda"
  IF v_surge_factor >= 1.08 THEN
    v_level          := 'high';
    v_message        := '✨ Servicio con respaldo garantizado';
    v_client_message := 'Reserva protegida por la app · Pago seguro y garantía de servicio';
  ELSIF v_surge_factor >= 1.03 THEN
    v_level          := 'medium';
    v_message        := '✨ Reserva con respaldo de plataforma';
    v_client_message := 'Reserva protegida · Pago seguro y garantía de servicio';
  ELSE
    v_level          := 'low';
    v_message        := '';
    v_client_message := '';
  END IF;

  RETURN jsonb_build_object(
    'surge_factor',      v_surge_factor,
    'level',             v_level,
    'message',           v_message,
    'client_message',    v_client_message,
    'open_requests',     v_open_requests,
    'available_groups',  v_available_groups
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.get_surge_factor(TEXT, TEXT) TO anon, authenticated;


SELECT '126_surge_pricing.sql ejecutado ✅' AS status;
SELECT 'Nueva columna: demand_multiplier en event_requests (DEFAULT 1)' AS cols;
SELECT 'RPC: get_surge_factor(p_genre, p_city) → surge_factor, level, message' AS rpc;
SELECT 'Niveles: low (<1.03) · medium (<1.08) · high (≥1.08)' AS levels;
SELECT 'Máximo multiplicador: 1.15 (+15%)' AS max;
