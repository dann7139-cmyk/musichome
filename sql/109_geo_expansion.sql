-- ════════════════════════════════════════════════════════════════════════════
-- 109_geo_expansion.sql
-- Arquitectura multi-ciudad y multi-país para escalar la plataforma
--
-- LO QUE IMPLEMENTA ESTE ARCHIVO:
--   1. Tablas geográficas: countries, states, cities
--   2. FK opcionales en groups, event_requests, reservations (sin romper nada)
--   3. group_service_areas — grupos que trabajan en varias ciudades
--   4. Seed data: México + ciudades principales
--   5. resolve_city_id() — mapea texto existente → UUID de ciudad
--   6. check_city_active() — valida si ciudad acepta solicitudes express
--   7. activate_city() — admin activa una ciudad
--   8. get_city_stats() — analytics por ciudad (eventos, grupos, ingresos)
--   9. get_nearby_cities() — ciudades cercanas a un punto
--  10. get_country_config() — moneda, proveedor de pago y timezone por país
--  11. calculate_matching_score() actualizado — bonus por misma ciudad
--  12. get_platform_demand_map() — mapa de demanda para dashboard admin
--  13. notify_new_city_groups() — notifica grupos al activar ciudad
--
-- COMPATIBILIDAD: columnas de texto existentes (city, location_city,
-- location_estado) NO se modifican. Los nuevos FK son NULLABLE.
-- Cero impacto en reservas, propuestas ni pagos.
--
-- Ejecutar DESPUÉS de 108_smart_matching.sql
-- ════════════════════════════════════════════════════════════════════════════


-- ────────────────────────────────────────────────────────────────────────────
-- PARTE 1: TABLAS GEOGRÁFICAS
-- ────────────────────────────────────────────────────────────────────────────

-- ── 1a. COUNTRIES ─────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS public.countries (
  id    UUID    PRIMARY KEY DEFAULT gen_random_uuid(),
  code  CHAR(2) NOT NULL UNIQUE,
  name  TEXT    NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Añadir columnas propias si la tabla ya existía con estructura diferente
ALTER TABLE public.countries ADD COLUMN IF NOT EXISTS currency_code    CHAR(3)      NOT NULL DEFAULT 'MXN';
ALTER TABLE public.countries ADD COLUMN IF NOT EXISTS currency_symbol  TEXT         NOT NULL DEFAULT '$';
ALTER TABLE public.countries ADD COLUMN IF NOT EXISTS payment_provider TEXT         NOT NULL DEFAULT 'mercadopago';
ALTER TABLE public.countries ADD COLUMN IF NOT EXISTS commission_rate  NUMERIC(5,4) NOT NULL DEFAULT 0.15;
ALTER TABLE public.countries ADD COLUMN IF NOT EXISTS timezone         TEXT         NOT NULL DEFAULT 'America/Mexico_City';
ALTER TABLE public.countries ADD COLUMN IF NOT EXISTS is_active        BOOLEAN      NOT NULL DEFAULT FALSE;
ALTER TABLE public.countries ADD COLUMN IF NOT EXISTS launch_date      DATE;

-- Constraint de payment_provider (solo si no existe)
DO $$ BEGIN
  ALTER TABLE public.countries
    ADD CONSTRAINT countries_payment_provider_check
    CHECK (payment_provider IN ('mercadopago','stripe','paypal'));
EXCEPTION WHEN duplicate_object THEN NULL; END; $$;

CREATE INDEX IF NOT EXISTS idx_countries_code     ON public.countries(code);
CREATE INDEX IF NOT EXISTS idx_countries_active   ON public.countries(is_active) WHERE is_active = TRUE;

-- ── 1b. STATES ────────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS public.states (
  id    UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  name  TEXT NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

ALTER TABLE public.states ADD COLUMN IF NOT EXISTS country_id UUID REFERENCES public.countries(id) ON DELETE CASCADE;
ALTER TABLE public.states ADD COLUMN IF NOT EXISTS code       TEXT;
ALTER TABLE public.states ADD COLUMN IF NOT EXISTS timezone   TEXT;

DO $$ BEGIN
  ALTER TABLE public.states ADD CONSTRAINT states_country_code_unique UNIQUE (country_id, code);
EXCEPTION WHEN duplicate_object THEN NULL; END; $$;

CREATE INDEX IF NOT EXISTS idx_states_country ON public.states(country_id);

-- ── 1c. CITIES ────────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS public.cities (
  id    UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  name  TEXT NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

ALTER TABLE public.cities ADD COLUMN IF NOT EXISTS state_id   UUID REFERENCES public.states(id)   ON DELETE CASCADE;
ALTER TABLE public.cities ADD COLUMN IF NOT EXISTS country_id UUID REFERENCES public.countries(id) ON DELETE CASCADE;
ALTER TABLE public.cities ADD COLUMN IF NOT EXISTS lat         DOUBLE PRECISION;
ALTER TABLE public.cities ADD COLUMN IF NOT EXISTS lng         DOUBLE PRECISION;
ALTER TABLE public.cities ADD COLUMN IF NOT EXISTS timezone    TEXT;
ALTER TABLE public.cities ADD COLUMN IF NOT EXISTS is_active   BOOLEAN NOT NULL DEFAULT FALSE;
ALTER TABLE public.cities ADD COLUMN IF NOT EXISTS launch_date DATE;

DO $$ BEGIN
  ALTER TABLE public.cities ADD CONSTRAINT cities_state_name_unique UNIQUE (state_id, name);
EXCEPTION WHEN duplicate_object THEN NULL; END; $$;

CREATE INDEX IF NOT EXISTS idx_cities_state   ON public.cities(state_id);
CREATE INDEX IF NOT EXISTS idx_cities_country ON public.cities(country_id);
CREATE INDEX IF NOT EXISTS idx_cities_active  ON public.cities(is_active) WHERE is_active = TRUE;
CREATE INDEX IF NOT EXISTS idx_cities_coords  ON public.cities(lat, lng)  WHERE lat IS NOT NULL;

-- RLS: ciudades visibles por todos (son datos públicos)
ALTER TABLE public.countries ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.states    ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.cities    ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "countries_public_read" ON public.countries;
CREATE POLICY "countries_public_read" ON public.countries FOR SELECT USING (TRUE);

DROP POLICY IF EXISTS "states_public_read" ON public.states;
CREATE POLICY "states_public_read" ON public.states FOR SELECT USING (TRUE);

DROP POLICY IF EXISTS "cities_public_read" ON public.cities;
CREATE POLICY "cities_public_read" ON public.cities FOR SELECT USING (TRUE);


-- ────────────────────────────────────────────────────────────────────────────
-- PARTE 2: FK OPCIONALES EN TABLAS EXISTENTES
-- ────────────────────────────────────────────────────────────────────────────
-- NULLABLE para preservar compatibilidad total con código existente.
-- Las columnas de texto (city, location_city, etc.) NO se tocan.

ALTER TABLE public.groups
  ADD COLUMN IF NOT EXISTS city_id    UUID REFERENCES public.cities(id),
  ADD COLUMN IF NOT EXISTS state_id   UUID REFERENCES public.states(id),
  ADD COLUMN IF NOT EXISTS country_id UUID REFERENCES public.countries(id);

ALTER TABLE public.event_requests
  ADD COLUMN IF NOT EXISTS city_id    UUID REFERENCES public.cities(id),
  ADD COLUMN IF NOT EXISTS state_id   UUID REFERENCES public.states(id),
  ADD COLUMN IF NOT EXISTS country_id UUID REFERENCES public.countries(id);

ALTER TABLE public.reservations
  ADD COLUMN IF NOT EXISTS city_id    UUID REFERENCES public.cities(id),
  ADD COLUMN IF NOT EXISTS state_id   UUID REFERENCES public.states(id),
  ADD COLUMN IF NOT EXISTS country_id UUID REFERENCES public.countries(id);

CREATE INDEX IF NOT EXISTS idx_groups_city       ON public.groups(city_id)    WHERE city_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_groups_country    ON public.groups(country_id) WHERE country_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_er_city           ON public.event_requests(city_id) WHERE city_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_reservations_city ON public.reservations(city_id) WHERE city_id IS NOT NULL;


-- ────────────────────────────────────────────────────────────────────────────
-- PARTE 3: GROUP_SERVICE_AREAS
-- ────────────────────────────────────────────────────────────────────────────
-- Permite que un grupo trabaje en varias ciudades con radios diferentes.

CREATE TABLE IF NOT EXISTS public.group_service_areas (
  id          UUID    PRIMARY KEY DEFAULT gen_random_uuid(),
  group_id    UUID    NOT NULL REFERENCES public.groups(id) ON DELETE CASCADE,
  city_id     UUID    NOT NULL REFERENCES public.cities(id) ON DELETE CASCADE,
  radius_km   NUMERIC(6,2) NOT NULL DEFAULT 25,
  is_primary  BOOLEAN NOT NULL DEFAULT FALSE,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (group_id, city_id)
);

CREATE INDEX IF NOT EXISTS idx_service_areas_group ON public.group_service_areas(group_id);
CREATE INDEX IF NOT EXISTS idx_service_areas_city  ON public.group_service_areas(city_id);

-- RLS: dueño del grupo gestiona sus áreas; todos pueden leer
ALTER TABLE public.group_service_areas ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "service_areas_public_read" ON public.group_service_areas;
CREATE POLICY "service_areas_public_read"
  ON public.group_service_areas FOR SELECT USING (TRUE);

DROP POLICY IF EXISTS "service_areas_owner_write" ON public.group_service_areas;
CREATE POLICY "service_areas_owner_write"
  ON public.group_service_areas FOR ALL
  USING (EXISTS (
    SELECT 1 FROM public.groups g
    WHERE g.id = group_id AND g.owner_id = auth.uid()
  ));


-- ────────────────────────────────────────────────────────────────────────────
-- PARTE 4: SEED DATA — MÉXICO
-- ────────────────────────────────────────────────────────────────────────────

DO $$
DECLARE
  v_mx_id UUID;
  v_jal   UUID;
  v_cdmx  UUID;
  v_nl    UUID;
  v_pue   UUID;
  v_bc    UUID;
  v_qro   UUID;
BEGIN

  -- ── País: México ──────────────────────────────────────────────────────
  INSERT INTO public.countries (code, name, currency_code, currency_symbol,
    payment_provider, commission_rate, timezone, is_active, launch_date)
  VALUES ('MX', 'México', 'MXN', '$', 'mercadopago', 0.15,
          'America/Mexico_City', TRUE, CURRENT_DATE)
  ON CONFLICT (code) DO UPDATE
    SET name             = EXCLUDED.name,
        currency_code    = EXCLUDED.currency_code,
        payment_provider = EXCLUDED.payment_provider,
        is_active        = EXCLUDED.is_active;

  SELECT id INTO v_mx_id FROM public.countries WHERE code = 'MX';

  -- ── País: USA (pre-registrado, inactivo) ─────────────────────────────
  INSERT INTO public.countries (code, name, currency_code, currency_symbol,
    payment_provider, commission_rate, timezone, is_active)
  VALUES ('US', 'United States', 'USD', '$', 'stripe', 0.15, 'America/New_York', FALSE)
  ON CONFLICT (code) DO NOTHING;

  -- ── País: España (pre-registrado, inactivo) ──────────────────────────
  INSERT INTO public.countries (code, name, currency_code, currency_symbol,
    payment_provider, commission_rate, timezone, is_active)
  VALUES ('ES', 'España', 'EUR', '€', 'stripe', 0.12, 'Europe/Madrid', FALSE)
  ON CONFLICT (code) DO NOTHING;

  -- ── Estados de México ─────────────────────────────────────────────────
  INSERT INTO public.states (country_id, code, name)
  VALUES
    (v_mx_id, 'MX-JAL',  'Jalisco'),
    (v_mx_id, 'MX-CMX',  'Ciudad de México'),
    (v_mx_id, 'MX-NLE',  'Nuevo León'),
    (v_mx_id, 'MX-PUE',  'Puebla'),
    (v_mx_id, 'MX-BCN',  'Baja California'),
    (v_mx_id, 'MX-QUE',  'Querétaro'),
    (v_mx_id, 'MX-GRO',  'Guerrero'),
    (v_mx_id, 'MX-YUC',  'Yucatán'),
    (v_mx_id, 'MX-VER',  'Veracruz'),
    (v_mx_id, 'MX-SON',  'Sonora')
  ON CONFLICT (country_id, code) DO NOTHING;

  SELECT id INTO v_jal  FROM public.states WHERE country_id = v_mx_id AND code = 'MX-JAL';
  SELECT id INTO v_cdmx FROM public.states WHERE country_id = v_mx_id AND code = 'MX-CMX';
  SELECT id INTO v_nl   FROM public.states WHERE country_id = v_mx_id AND code = 'MX-NLE';
  SELECT id INTO v_pue  FROM public.states WHERE country_id = v_mx_id AND code = 'MX-PUE';
  SELECT id INTO v_bc   FROM public.states WHERE country_id = v_mx_id AND code = 'MX-BCN';
  SELECT id INTO v_qro  FROM public.states WHERE country_id = v_mx_id AND code = 'MX-QUE';

  -- ── Ciudades ──────────────────────────────────────────────────────────
  INSERT INTO public.cities (state_id, country_id, name, lat, lng, is_active, launch_date)
  VALUES
    -- Jalisco
    (v_jal, v_mx_id, 'Guadalajara',    20.6597,  -103.3496, TRUE,  CURRENT_DATE),
    (v_jal, v_mx_id, 'Zapopan',        20.7214,  -103.3916, TRUE,  CURRENT_DATE),
    (v_jal, v_mx_id, 'Tlaquepaque',    20.6381,  -103.3069, FALSE, NULL),
    (v_jal, v_mx_id, 'Puerto Vallarta', 20.6534, -105.2253, FALSE, NULL),
    -- CDMX
    (v_cdmx, v_mx_id, 'Ciudad de México', 19.4326, -99.1332, FALSE, NULL),
    -- Nuevo León
    (v_nl,  v_mx_id, 'Monterrey',      25.6866,  -100.3161, FALSE, NULL),
    (v_nl,  v_mx_id, 'San Pedro Garza García', 25.6572, -100.4023, FALSE, NULL),
    -- Puebla
    (v_pue, v_mx_id, 'Puebla',         19.0414,  -98.2063,  FALSE, NULL),
    -- Baja California
    (v_bc,  v_mx_id, 'Tijuana',        32.5027,  -117.0037, FALSE, NULL),
    (v_bc,  v_mx_id, 'Ensenada',       31.8676,  -116.5956, FALSE, NULL),
    -- Querétaro
    (v_qro, v_mx_id, 'Querétaro',      20.5888,  -100.3899, FALSE, NULL)
  ON CONFLICT (state_id, name) DO UPDATE
    SET lat       = EXCLUDED.lat,
        lng       = EXCLUDED.lng,
        is_active = GREATEST(cities.is_active, EXCLUDED.is_active);

END;
$$;


-- ────────────────────────────────────────────────────────────────────────────
-- PARTE 5: resolve_city_id()
-- ────────────────────────────────────────────────────────────────────────────
-- Mapea el texto libre de ciudad (location_city / groups.city) a un UUID.
-- Usado para backfill y en triggers de INSERT.
-- Búsqueda: nombre exacto → ILIKE → NULL si no encuentra.

CREATE OR REPLACE FUNCTION public.resolve_city_id(
  p_city_name  TEXT,
  p_state_name TEXT DEFAULT NULL,
  p_country_code CHAR(2) DEFAULT 'MX'
)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_city_id UUID;
BEGIN
  SELECT c.id INTO v_city_id
  FROM   public.cities c
  JOIN   public.countries co ON co.id = c.country_id
  LEFT JOIN public.states s  ON s.id  = c.state_id
  WHERE  co.code = UPPER(p_country_code)
    AND  (
      LOWER(TRIM(c.name)) = LOWER(TRIM(p_city_name))
      OR c.name ILIKE '%' || TRIM(p_city_name) || '%'
    )
    AND  (
      p_state_name IS NULL
      OR LOWER(TRIM(s.name)) = LOWER(TRIM(p_state_name))
      OR s.name ILIKE '%' || TRIM(p_state_name) || '%'
    )
  ORDER BY
    -- Preferir coincidencia exacta sobre parcial
    CASE WHEN LOWER(TRIM(c.name)) = LOWER(TRIM(p_city_name)) THEN 0 ELSE 1 END
  LIMIT 1;

  RETURN v_city_id;  -- NULL si no se encuentra
END;
$$;

GRANT EXECUTE ON FUNCTION public.resolve_city_id(TEXT, TEXT, CHAR(2)) TO authenticated, service_role;

-- Backfill: asociar grupos existentes con su city_id según la columna text 'city'
DO $$
DECLARE
  v_mx CHAR(2) := 'MX';
BEGIN
  UPDATE public.groups g
  SET city_id = public.resolve_city_id(g.city, NULL, v_mx)
  WHERE g.city IS NOT NULL AND g.city_id IS NULL;

  UPDATE public.groups g
  SET country_id = (SELECT id FROM public.countries WHERE code = v_mx)
  WHERE g.country_id IS NULL;
END;
$$;


-- ────────────────────────────────────────────────────────────────────────────
-- PARTE 6: check_city_active()
-- ────────────────────────────────────────────────────────────────────────────
-- Verifica si una ciudad acepta nuevas solicitudes express.
-- Llamado antes de INSERT en event_requests (puede ser un trigger o RPC).

CREATE OR REPLACE FUNCTION public.check_city_active(
  p_city_id   UUID  DEFAULT NULL,
  p_city_name TEXT  DEFAULT NULL,
  p_country_code CHAR(2) DEFAULT 'MX'
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_city RECORD;
BEGIN
  -- Resolver por ID o por nombre
  IF p_city_id IS NOT NULL THEN
    SELECT c.*, co.name AS country_name, co.currency_code, co.timezone AS country_tz
    INTO   v_city
    FROM   public.cities c
    JOIN   public.countries co ON co.id = c.country_id
    WHERE  c.id = p_city_id;
  ELSE
    SELECT c.*, co.name AS country_name, co.currency_code, co.timezone AS country_tz
    INTO   v_city
    FROM   public.cities c
    JOIN   public.countries co ON co.id = c.country_id
    WHERE  co.code = UPPER(p_country_code)
      AND  LOWER(TRIM(c.name)) = LOWER(TRIM(p_city_name))
    LIMIT  1;
  END IF;

  IF NOT FOUND THEN
    RETURN jsonb_build_object(
      'active',  FALSE,
      'reason',  'city_not_found',
      'message', 'Esta ciudad aún no está registrada en la plataforma.'
    );
  END IF;

  IF NOT v_city.is_active THEN
    RETURN jsonb_build_object(
      'active',      FALSE,
      'city_name',   v_city.name,
      'reason',      'city_inactive',
      'message',     'Pronto llegaremos a ' || v_city.name || '. ¡Regístrate para ser de los primeros!'
    );
  END IF;

  RETURN jsonb_build_object(
    'active',        TRUE,
    'city_id',       v_city.id,
    'city_name',     v_city.name,
    'timezone',      COALESCE(v_city.timezone, v_city.country_tz),
    'currency_code', v_city.currency_code
  );

EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('active', FALSE, 'error', SQLERRM);
END;
$$;

GRANT EXECUTE ON FUNCTION public.check_city_active(UUID, TEXT, CHAR(2)) TO authenticated, anon;


-- ────────────────────────────────────────────────────────────────────────────
-- PARTE 7: activate_city()
-- ────────────────────────────────────────────────────────────────────────────
-- Solo admin. Activa una ciudad y notifica a los grupos registrados en ella.

CREATE OR REPLACE FUNCTION public.activate_city(p_city_id UUID)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_city       RECORD;
  v_is_admin   BOOLEAN;
  v_notified   INT;
BEGIN
  -- Solo admins
  SELECT EXISTS (
    SELECT 1 FROM public.profiles WHERE id = auth.uid() AND role = 'admin'
  ) INTO v_is_admin;

  IF NOT v_is_admin THEN
    RETURN jsonb_build_object('ok', FALSE, 'error', 'unauthorized');
  END IF;

  SELECT c.*, s.name AS state_name
  INTO   v_city
  FROM   public.cities c
  JOIN   public.states s ON s.id = c.state_id
  WHERE  c.id = p_city_id;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', FALSE, 'error', 'city_not_found');
  END IF;

  IF v_city.is_active THEN
    RETURN jsonb_build_object('ok', TRUE, 'message', 'Ciudad ya estaba activa', 'city', v_city.name);
  END IF;

  UPDATE public.cities
  SET is_active   = TRUE,
      launch_date = CURRENT_DATE
  WHERE id = p_city_id;

  -- Notificar a grupos de la ciudad
  SELECT public.notify_new_city_groups(p_city_id) INTO v_notified;

  RETURN jsonb_build_object(
    'ok',          TRUE,
    'city',        v_city.name,
    'state',       v_city.state_name,
    'groups_notified', v_notified
  );

EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('ok', FALSE, 'error', SQLERRM);
END;
$$;

GRANT EXECUTE ON FUNCTION public.activate_city(UUID) TO authenticated;


-- ────────────────────────────────────────────────────────────────────────────
-- PARTE 8: get_city_stats()
-- ────────────────────────────────────────────────────────────────────────────
-- Analytics por ciudad: eventos, grupos, ingresos, tasa de aceptación.

CREATE OR REPLACE FUNCTION public.get_city_stats(
  p_city_id    UUID    DEFAULT NULL,
  p_city_name  TEXT    DEFAULT NULL,
  p_days_back  INT     DEFAULT 30
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_city_id    UUID;
  v_city_name  TEXT;
  v_since      TIMESTAMPTZ;
  v_total_events      BIGINT;
  v_active_groups     BIGINT;
  v_total_revenue     NUMERIC;
  v_acceptance_rate   NUMERIC;
  v_avg_response_min  NUMERIC;
  v_express_count     BIGINT;
BEGIN
  -- Resolver ciudad
  IF p_city_id IS NOT NULL THEN
    v_city_id := p_city_id;
    SELECT name INTO v_city_name FROM public.cities WHERE id = p_city_id;
  ELSE
    v_city_id   := public.resolve_city_id(p_city_name);
    v_city_name := p_city_name;
  END IF;

  v_since := NOW() - (p_days_back || ' days')::INTERVAL;

  -- ── Eventos completados ─────────────────────────────────────────────
  SELECT COUNT(*) INTO v_total_events
  FROM public.reservations r
  WHERE r.city_id  = v_city_id
    AND r.status   = 'completed'
    AND r.created_at >= v_since;

  -- Fallback: usar city_id de grupos cuando reservaciones no tienen city_id
  IF v_total_events = 0 AND v_city_id IS NOT NULL THEN
    SELECT COUNT(*) INTO v_total_events
    FROM public.reservations r
    JOIN public.groups g ON g.id = r.group_id
    WHERE g.city_id = v_city_id
      AND r.status  = 'completed'
      AND r.created_at >= v_since;
  END IF;

  -- ── Grupos activos en la ciudad ─────────────────────────────────────
  SELECT COUNT(*) INTO v_active_groups
  FROM public.groups g
  WHERE g.city_id   = v_city_id
    AND g.is_active = TRUE;

  -- ── Ingresos totales (total_price de reservas completadas) ──────────
  SELECT COALESCE(SUM(r.total_price), 0) INTO v_total_revenue
  FROM public.reservations r
  JOIN public.groups g ON g.id = r.group_id
  WHERE g.city_id = v_city_id
    AND r.status  = 'completed'
    AND r.created_at >= v_since;

  -- ── Tasa de aceptación de solicitudes express ───────────────────────
  SELECT
    CASE WHEN COUNT(*) = 0 THEN NULL
         ELSE ROUND(COUNT(*) FILTER (WHERE status = 'accepted')::NUMERIC / COUNT(*) * 100, 1)
    END
  INTO v_acceptance_rate
  FROM public.event_requests er
  WHERE er.city_id  = v_city_id
    AND er.created_at >= v_since;

  -- Fallback por location_city
  IF v_acceptance_rate IS NULL THEN
    SELECT
      CASE WHEN COUNT(*) = 0 THEN 0
           ELSE ROUND(COUNT(*) FILTER (WHERE status = 'accepted')::NUMERIC / COUNT(*) * 100, 1)
      END
    INTO v_acceptance_rate
    FROM public.event_requests er
    WHERE LOWER(TRIM(er.location_city)) = LOWER(TRIM(v_city_name))
      AND er.created_at >= v_since;
  END IF;

  -- ── Solicitudes express en el período ──────────────────────────────
  SELECT COUNT(*) INTO v_express_count
  FROM public.event_requests er
  WHERE LOWER(TRIM(er.location_city)) = LOWER(TRIM(v_city_name))
    AND er.created_at >= v_since;

  -- ── Tiempo de respuesta promedio (minutos) ──────────────────────────
  SELECT ROUND(AVG(EXTRACT(EPOCH FROM (pl.proposed_at - er.created_at)) / 60)::NUMERIC, 1)
  INTO   v_avg_response_min
  FROM   public.proposal_logs pl
  JOIN   public.event_requests er ON er.id = pl.request_id
  JOIN   public.groups g ON g.id = pl.group_id
  WHERE  g.city_id = v_city_id
    AND  pl.proposed_at >= v_since;

  RETURN jsonb_build_object(
    'ok',               TRUE,
    'city',             v_city_name,
    'city_id',          v_city_id,
    'period_days',      p_days_back,
    'events_completed', COALESCE(v_total_events, 0),
    'active_groups',    COALESCE(v_active_groups, 0),
    'total_revenue',    COALESCE(v_total_revenue, 0),
    'acceptance_rate',  COALESCE(v_acceptance_rate, 0),
    'express_requests', COALESCE(v_express_count, 0),
    'avg_response_min', COALESCE(v_avg_response_min, 0)
  );

EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('ok', FALSE, 'error', SQLERRM);
END;
$$;

GRANT EXECUTE ON FUNCTION public.get_city_stats(UUID, TEXT, INT) TO authenticated;


-- ────────────────────────────────────────────────────────────────────────────
-- PARTE 9: get_nearby_cities()
-- ────────────────────────────────────────────────────────────────────────────
-- Devuelve ciudades cercanas a un punto, opcionalmente solo las activas.

CREATE OR REPLACE FUNCTION public.get_nearby_cities(
  p_lat      DOUBLE PRECISION,
  p_lng      DOUBLE PRECISION,
  p_radius_km NUMERIC DEFAULT 100,
  p_only_active BOOLEAN DEFAULT TRUE
)
RETURNS TABLE (
  city_id      UUID,
  city_name    TEXT,
  state_name   TEXT,
  distance_km  NUMERIC,
  is_active    BOOLEAN,
  active_groups BIGINT
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  RETURN QUERY
  SELECT
    c.id,
    c.name,
    s.name,
    ROUND(haversine_km(c.lat, c.lng, p_lat, p_lng)::NUMERIC, 1),
    c.is_active,
    COUNT(g.id) FILTER (WHERE g.is_active = TRUE)
  FROM public.cities c
  JOIN public.states s ON s.id = c.state_id
  LEFT JOIN public.groups g ON g.city_id = c.id
  WHERE c.lat IS NOT NULL
    AND haversine_km(c.lat, c.lng, p_lat, p_lng) <= p_radius_km
    AND (NOT p_only_active OR c.is_active = TRUE)
  GROUP BY c.id, c.name, s.name, c.lat, c.lng, c.is_active
  ORDER BY haversine_km(c.lat, c.lng, p_lat, p_lng) ASC;
END;
$$;

GRANT EXECUTE ON FUNCTION public.get_nearby_cities(DOUBLE PRECISION, DOUBLE PRECISION, NUMERIC, BOOLEAN) TO authenticated, anon;


-- ────────────────────────────────────────────────────────────────────────────
-- PARTE 10: get_country_config()
-- ────────────────────────────────────────────────────────────────────────────
-- Devuelve configuración de moneda, pago y timezone para un país.
-- El frontend usa esto al mostrar precios y configurar el proveedor de pago.

CREATE OR REPLACE FUNCTION public.get_country_config(p_country_code CHAR(2) DEFAULT 'MX')
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_country RECORD;
BEGIN
  SELECT * INTO v_country
  FROM public.countries
  WHERE code = UPPER(p_country_code);

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', FALSE, 'error', 'country_not_found');
  END IF;

  RETURN jsonb_build_object(
    'ok',              TRUE,
    'country_code',    v_country.code,
    'country_name',    v_country.name,
    'currency_code',   v_country.currency_code,
    'currency_symbol', v_country.currency_symbol,
    'payment_provider', v_country.payment_provider,
    'commission_rate', v_country.commission_rate,
    'timezone',        v_country.timezone,
    'is_active',       v_country.is_active
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.get_country_config(CHAR(2)) TO authenticated, anon;


-- ────────────────────────────────────────────────────────────────────────────
-- PARTE 11: calculate_matching_score() ACTUALIZADO
-- ────────────────────────────────────────────────────────────────────────────
-- Agrega bonus por ciudad: +15 pts si el grupo está en la misma ciudad,
-- +8 pts si está en una zona de servicio que cubre la ciudad del evento.
-- El resto de la fórmula es idéntico al de 108.

CREATE OR REPLACE FUNCTION public.calculate_matching_score(
  p_group_id   UUID,
  p_request_id UUID
)
RETURNS NUMERIC
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_req            RECORD;
  v_group          RECORD;
  v_dist_km        NUMERIC;
  v_dist_score     NUMERIC;
  v_rank_score     NUMERIC;
  v_rel_score      NUMERIC;
  v_resp_score     NUMERIC;
  v_activity_score NUMERIC;
  v_city_bonus     NUMERIC := 0;
  v_total          NUMERIC;
BEGIN
  SELECT * INTO v_req FROM public.event_requests WHERE id = p_request_id;
  IF NOT FOUND THEN RETURN 0; END IF;

  SELECT g.*, gl.lat, gl.lng
  INTO   v_group
  FROM   public.groups g
  LEFT JOIN public.group_locations gl ON gl.group_id = g.id
  WHERE  g.id = p_group_id;

  IF NOT FOUND THEN RETURN 0; END IF;

  -- ── Puntaje de distancia (30 %) ────────────────────────────────────────
  IF v_group.lat IS NOT NULL AND v_req.event_lat IS NOT NULL THEN
    v_dist_km := haversine_km(v_group.lat, v_group.lng, v_req.event_lat, v_req.event_lng);
    v_dist_score := CASE
      WHEN v_dist_km <=  5 THEN 100
      WHEN v_dist_km <= 10 THEN 70
      WHEN v_dist_km <= 25 THEN 40
      ELSE                       20
    END;
  ELSE
    v_dist_score := 50;
  END IF;

  -- ── Puntaje de ranking (25 %) ──────────────────────────────────────────
  v_rank_score := LEAST(COALESCE(v_group.ranking_score, 0) / 5.0 * 100, 100);

  -- ── Puntaje de confiabilidad (20 %) ───────────────────────────────────
  v_rel_score := COALESCE(v_group.reliability_score, 0);

  -- ── Puntaje de velocidad de respuesta (15 %) ──────────────────────────
  SELECT CASE
    WHEN COUNT(*) = 0 THEN 50
    ELSE
      CASE
        WHEN AVG(EXTRACT(EPOCH FROM (pl.proposed_at - er.created_at)) / 60) <  5 THEN 100
        WHEN AVG(EXTRACT(EPOCH FROM (pl.proposed_at - er.created_at)) / 60) < 15 THEN 80
        WHEN AVG(EXTRACT(EPOCH FROM (pl.proposed_at - er.created_at)) / 60) < 30 THEN 60
        WHEN AVG(EXTRACT(EPOCH FROM (pl.proposed_at - er.created_at)) / 60) < 60 THEN 40
        ELSE 20
      END
  END
  INTO v_resp_score
  FROM public.proposal_logs pl
  JOIN public.event_requests er ON er.id = pl.request_id
  WHERE pl.group_id = p_group_id
    AND pl.proposed_at >= NOW() - INTERVAL '60 days';

  v_resp_score := COALESCE(v_resp_score, 50);

  -- ── Puntaje de actividad reciente (10 %) ──────────────────────────────
  SELECT LEAST(COUNT(*) * 10, 100)
  INTO   v_activity_score
  FROM   public.reservations
  WHERE  group_id = p_group_id
    AND  status   = 'completed'
    AND  updated_at >= NOW() - INTERVAL '30 days';

  v_activity_score := COALESCE(v_activity_score, 0);

  -- ── Bonus por ciudad (nuevo en 109) ───────────────────────────────────
  -- Misma ciudad: +15 pts
  IF v_req.city_id IS NOT NULL AND v_group.city_id = v_req.city_id THEN
    v_city_bonus := 15;
  -- Ciudad cubierta por zona de servicio del grupo: +8 pts
  ELSIF v_req.city_id IS NOT NULL AND EXISTS (
    SELECT 1 FROM public.group_service_areas gsa
    WHERE gsa.group_id = p_group_id AND gsa.city_id = v_req.city_id
  ) THEN
    v_city_bonus := 8;
  END IF;

  -- ── Total ponderado ───────────────────────────────────────────────────
  v_total :=
      (v_dist_score     * 0.30)
    + (v_rank_score     * 0.25)
    + (v_rel_score      * 0.20)
    + (v_resp_score     * 0.15)
    + (v_activity_score * 0.10)
    + v_city_bonus;

  -- Bonus: disponible ahora → +10 pts
  IF COALESCE(v_group.available_now, FALSE) THEN
    v_total := v_total + 10;
  END IF;

  RETURN LEAST(GREATEST(v_total, 0), 100);

EXCEPTION WHEN OTHERS THEN
  RETURN 0;
END;
$$;

GRANT EXECUTE ON FUNCTION public.calculate_matching_score(UUID, UUID) TO authenticated, service_role;


-- ────────────────────────────────────────────────────────────────────────────
-- PARTE 12: get_platform_demand_map()
-- ────────────────────────────────────────────────────────────────────────────
-- Para el dashboard admin: muestra todas las ciudades con su nivel de actividad.
-- Útil para identificar dónde abrir nuevos mercados.

CREATE OR REPLACE FUNCTION public.get_platform_demand_map(p_days_back INT DEFAULT 30)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_since  TIMESTAMPTZ;
  v_result JSONB;
BEGIN
  v_since := NOW() - (p_days_back || ' days')::INTERVAL;

  SELECT jsonb_agg(row_to_json(t))
  INTO   v_result
  FROM (
    SELECT
      c.id                 AS city_id,
      c.name               AS city_name,
      s.name               AS state_name,
      co.name              AS country_name,
      co.currency_code,
      c.is_active,
      c.lat,
      c.lng,
      COUNT(DISTINCT g.id) FILTER (WHERE g.is_active = TRUE)  AS active_groups,
      COUNT(DISTINCT er.id)                                    AS express_requests,
      COUNT(DISTINCT r.id)  FILTER (WHERE r.status = 'completed') AS completed_events,
      COALESCE(SUM(r.total_price) FILTER (WHERE r.status = 'completed'), 0) AS revenue,
      -- Señal de demanda: solicitudes sin ciudad activa = mercado potencial
      CASE
        WHEN NOT c.is_active AND COUNT(er.id) > 0 THEN 'high_potential'
        WHEN c.is_active AND COUNT(DISTINCT g.id) FILTER (WHERE g.is_active) < 3 THEN 'needs_supply'
        WHEN c.is_active THEN 'operational'
        ELSE 'inactive'
      END AS market_status
    FROM      public.cities c
    JOIN      public.states    s  ON s.id  = c.state_id
    JOIN      public.countries co ON co.id = c.country_id
    LEFT JOIN public.groups    g  ON g.city_id = c.id
    LEFT JOIN public.event_requests er
      ON  LOWER(TRIM(er.location_city)) = LOWER(TRIM(c.name))
      AND er.created_at >= v_since
    LEFT JOIN public.reservations r ON r.group_id = g.id AND r.created_at >= v_since
    GROUP BY c.id, c.name, s.name, co.name, co.currency_code, c.is_active, c.lat, c.lng
    ORDER BY express_requests DESC, active_groups DESC
  ) t;

  RETURN jsonb_build_object(
    'ok',   TRUE,
    'data', COALESCE(v_result, '[]'::JSONB),
    'period_days', p_days_back
  );

EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('ok', FALSE, 'error', SQLERRM);
END;
$$;

GRANT EXECUTE ON FUNCTION public.get_platform_demand_map(INT) TO authenticated;


-- ────────────────────────────────────────────────────────────────────────────
-- PARTE 13: notify_new_city_groups()
-- ────────────────────────────────────────────────────────────────────────────
-- Notifica a todos los grupos de una ciudad cuando se activa.
-- También notifica a grupos de ciudades cercanas (radio 25 km) para que
-- registren la ciudad como zona de servicio.

CREATE OR REPLACE FUNCTION public.notify_new_city_groups(p_city_id UUID)
RETURNS INT
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_city   RECORD;
  v_group  RECORD;
  v_count  INT := 0;
BEGIN
  SELECT c.*, s.name AS state_name
  INTO   v_city
  FROM   public.cities c
  JOIN   public.states s ON s.id = c.state_id
  WHERE  c.id = p_city_id;

  IF NOT FOUND THEN RETURN 0; END IF;

  -- ── Grupos registrados en la ciudad ────────────────────────────────
  FOR v_group IN
    SELECT g.owner_id FROM public.groups g
    WHERE  g.city_id = p_city_id AND g.is_active = TRUE
  LOOP
    INSERT INTO public.notifications (user_id, type, title, body, data)
    VALUES (
      v_group.owner_id,
      'system',
      '🚀 ¡' || v_city.name || ' ya está activa!',
      'La plataforma está ahora disponible en ' || v_city.name || ', ' ||
      v_city.state_name || '. ¡Empieza a recibir solicitudes de eventos en tu ciudad!',
      jsonb_build_object(
        'screen',   'Dashboard',
        'city_id',  p_city_id,
        'action',   'city_launched'
      )
    );
    v_count := v_count + 1;
  END LOOP;

  -- ── Grupos de ciudades cercanas (≤ 25 km) ───────────────────────────
  IF v_city.lat IS NOT NULL THEN
    FOR v_group IN
      SELECT DISTINCT g.owner_id
      FROM   public.groups g
      JOIN   public.group_locations gl ON gl.group_id = g.id
      WHERE  g.city_id != p_city_id
        AND  g.is_active = TRUE
        AND  haversine_km(gl.lat, gl.lng, v_city.lat, v_city.lng) <= 25
    LOOP
      INSERT INTO public.notifications (user_id, type, title, body, data)
      VALUES (
        v_group.owner_id,
        'system',
        '🗺️ Nueva ciudad cerca de ti: ' || v_city.name,
        'La plataforma llegó a ' || v_city.name || ', que está cerca de tu ubicación. ' ||
        'Agrega ' || v_city.name || ' como zona de servicio para recibir más solicitudes.',
        jsonb_build_object(
          'screen',   'Dashboard',
          'city_id',  p_city_id,
          'action',   'add_service_area'
        )
      );
      v_count := v_count + 1;
    END LOOP;
  END IF;

  RETURN v_count;
END;
$$;

GRANT EXECUTE ON FUNCTION public.notify_new_city_groups(UUID) TO service_role, authenticated;


-- ════════════════════════════════════════════════════════════════════════════
-- USO DESDE EL FRONTEND
-- ════════════════════════════════════════════════════════════════════════════
--
-- ── Verificar si ciudad acepta solicitudes (antes de crear solicitud) ──
--    supabase.rpc('check_city_active', { p_city_name: 'Guadalajara' })
--    → { active: true, city_id, timezone, currency_code }
--    Si active=false, mostrar mensaje de "próximamente".
--
-- ── Obtener config de país (moneda, pago) ─────────────────────────────
--    supabase.rpc('get_country_config', { p_country_code: 'MX' })
--    → { currency_code: 'MXN', payment_provider: 'mercadopago', timezone: ... }
--
-- ── Buscar ciudades cercanas ──────────────────────────────────────────
--    supabase.rpc('get_nearby_cities', { p_lat: 20.66, p_lng: -103.35, p_radius_km: 50 })
--    → [{ city_id, city_name, distance_km, is_active, active_groups }]
--
-- ── Analytics de ciudad (admin) ──────────────────────────────────────
--    supabase.rpc('get_city_stats', { p_city_name: 'Guadalajara', p_days_back: 30 })
--    → { events_completed, active_groups, total_revenue, acceptance_rate }
--
-- ── Mapa de demanda global (admin dashboard) ─────────────────────────
--    supabase.rpc('get_platform_demand_map', { p_days_back: 30 })
--    → [{ city_name, express_requests, active_groups, revenue, market_status }]
--    market_status: 'operational' | 'needs_supply' | 'high_potential' | 'inactive'
--
-- ── Activar ciudad nueva (admin) ─────────────────────────────────────
--    supabase.rpc('activate_city', { p_city_id: uuid })
--    → Activa la ciudad + notifica grupos automáticamente.
--
-- ── Grupo registra zona de servicio adicional ─────────────────────────
--    supabase.from('group_service_areas').insert({
--      group_id: myGroupId, city_id: cityId, radius_km: 20
--    })
--
-- ── INSERT de solicitud express con city_id ───────────────────────────
--    supabase.from('event_requests').insert({
--      ..., city_id: cityId, state_id: stateId, country_id: countryId
--    })
--    → El matching inteligente ya prioriza grupos de la misma ciudad.
--
-- ── Zonas horarias ────────────────────────────────────────────────────
--    Todas las fechas se almacenan en UTC en Supabase.
--    El frontend convierte usando el timezone del país/ciudad:
--    const tz = config.timezone // e.g. 'America/Mexico_City'
--    dayjs.utc(event_date).tz(tz).format(...)
-- ════════════════════════════════════════════════════════════════════════════

SELECT '109_geo_expansion: multi-ciudad + multi-país + analytics + matching geo ✅' AS status;
