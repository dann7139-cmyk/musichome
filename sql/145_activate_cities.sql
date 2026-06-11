-- ════════════════════════════════════════════════════════════════════════════
-- 145_activate_cities.sql
-- Activa las ciudades principales para que aparezcan en CitySelectScreen.
-- Ejecutar DESPUÉS de 144_city_scale_foundation.sql
-- ════════════════════════════════════════════════════════════════════════════

-- ── 1. Asegura que países y estados existen ───────────────────────────────

DO $$
DECLARE
  v_mx_id UUID;
  v_jal   UUID;
  v_cdmx  UUID;
  v_nl    UUID;
  v_pue   UUID;
  v_bc    UUID;
  v_qro   UUID;
  v_ags   UUID;
  v_sin   UUID;
BEGIN

  -- País: México
  INSERT INTO public.countries (code, name, currency_code, currency_symbol,
    payment_provider, commission_rate, timezone, is_active, launch_date)
  VALUES ('MX', 'México', 'MXN', '$', 'mercadopago', 0.15,
          'America/Mexico_City', TRUE, CURRENT_DATE)
  ON CONFLICT (code) DO UPDATE
    SET is_active = TRUE;

  SELECT id INTO v_mx_id FROM public.countries WHERE code = 'MX';

  -- Estados
  INSERT INTO public.states (country_id, code, name)
  VALUES
    (v_mx_id, 'MX-JAL', 'Jalisco'),
    (v_mx_id, 'MX-CMX', 'Ciudad de México'),
    (v_mx_id, 'MX-NLE', 'Nuevo León'),
    (v_mx_id, 'MX-PUE', 'Puebla'),
    (v_mx_id, 'MX-BCN', 'Baja California'),
    (v_mx_id, 'MX-QUE', 'Querétaro'),
    (v_mx_id, 'MX-GRO', 'Guerrero'),
    (v_mx_id, 'MX-YUC', 'Yucatán'),
    (v_mx_id, 'MX-VER', 'Veracruz'),
    (v_mx_id, 'MX-SON', 'Sonora'),
    (v_mx_id, 'MX-AGU', 'Aguascalientes'),
    (v_mx_id, 'MX-SIN', 'Sinaloa'),
    (v_mx_id, 'MX-OAX', 'Oaxaca'),
    (v_mx_id, 'MX-CHH', 'Chihuahua'),
    (v_mx_id, 'MX-MEX', 'Estado de México')
  ON CONFLICT (country_id, code) DO NOTHING;

  SELECT id INTO v_jal  FROM public.states WHERE country_id = v_mx_id AND code = 'MX-JAL';
  SELECT id INTO v_cdmx FROM public.states WHERE country_id = v_mx_id AND code = 'MX-CMX';
  SELECT id INTO v_nl   FROM public.states WHERE country_id = v_mx_id AND code = 'MX-NLE';
  SELECT id INTO v_pue  FROM public.states WHERE country_id = v_mx_id AND code = 'MX-PUE';
  SELECT id INTO v_bc   FROM public.states WHERE country_id = v_mx_id AND code = 'MX-BCN';
  SELECT id INTO v_qro  FROM public.states WHERE country_id = v_mx_id AND code = 'MX-QUE';
  SELECT id INTO v_ags  FROM public.states WHERE country_id = v_mx_id AND code = 'MX-AGU';
  SELECT id INTO v_sin  FROM public.states WHERE country_id = v_mx_id AND code = 'MX-SIN';

  -- ── 2. Inserta / activa ciudades ──────────────────────────────────────

  INSERT INTO public.cities (state_id, country_id, name, lat, lng, is_active, launch_date)
  VALUES
    -- Jalisco
    (v_jal,  v_mx_id, 'Guadalajara',             20.6597,  -103.3496, TRUE, CURRENT_DATE),
    (v_jal,  v_mx_id, 'Zapopan',                 20.7214,  -103.3916, TRUE, CURRENT_DATE),
    (v_jal,  v_mx_id, 'Tlaquepaque',             20.6381,  -103.3069, TRUE, CURRENT_DATE),
    (v_jal,  v_mx_id, 'Puerto Vallarta',          20.6534,  -105.2253, TRUE, CURRENT_DATE),
    -- CDMX
    (v_cdmx, v_mx_id, 'Ciudad de México',         19.4326,   -99.1332, TRUE, CURRENT_DATE),
    -- Nuevo León
    (v_nl,   v_mx_id, 'Monterrey',               25.6866,  -100.3161, TRUE, CURRENT_DATE),
    (v_nl,   v_mx_id, 'San Pedro Garza García',  25.6572,  -100.4023, TRUE, CURRENT_DATE),
    -- Puebla
    (v_pue,  v_mx_id, 'Puebla',                  19.0414,   -98.2063, TRUE, CURRENT_DATE),
    -- Baja California
    (v_bc,   v_mx_id, 'Tijuana',                 32.5027,  -117.0037, TRUE, CURRENT_DATE),
    -- Querétaro
    (v_qro,  v_mx_id, 'Querétaro',               20.5888,  -100.3899, TRUE, CURRENT_DATE),
    -- Aguascalientes
    (v_ags,  v_mx_id, 'Aguascalientes',           21.8853,  -102.2916, TRUE, CURRENT_DATE),
    -- Sinaloa
    (v_sin,  v_mx_id, 'Culiacán',                24.8049,  -107.3940, TRUE, CURRENT_DATE),
    (v_sin,  v_mx_id, 'Mazatlán',                23.2494,  -106.4111, TRUE, CURRENT_DATE)
  ON CONFLICT (state_id, name) DO UPDATE
    SET is_active    = TRUE,
        launch_date  = COALESCE(cities.launch_date, CURRENT_DATE),
        lat          = EXCLUDED.lat,
        lng          = EXCLUDED.lng;

END;
$$;


-- ── 3. Recrea get_active_cities() con tipos correctos (DOUBLE PRECISION) ─

DROP FUNCTION IF EXISTS public.get_active_cities();
CREATE OR REPLACE FUNCTION public.get_active_cities()
RETURNS TABLE (
  id           UUID,
  name         TEXT,
  state_name   TEXT,
  country_name TEXT,
  lat          DOUBLE PRECISION,
  lng          DOUBLE PRECISION,
  group_count  BIGINT,
  demand_level TEXT
)
LANGUAGE plpgsql
SECURITY DEFINER STABLE
SET search_path = public
AS $$
BEGIN
  RETURN QUERY
  SELECT
    c.id,
    c.name,
    COALESCE(s.name,  '') AS state_name,
    COALESCE(co.name, '') AS country_name,
    COALESCE(c.lat,   0::DOUBLE PRECISION) AS lat,
    COALESCE(c.lng,   0::DOUBLE PRECISION) AS lng,
    COUNT(g.id)           AS group_count,
    CASE
      WHEN COUNT(g.id) >= 10 THEN 'high'
      WHEN COUNT(g.id) >= 3  THEN 'normal'
      ELSE                        'new'
    END                   AS demand_level
  FROM   public.cities c
  LEFT JOIN public.states    s  ON s.id  = c.state_id
  LEFT JOIN public.countries co ON co.id = c.country_id
  LEFT JOIN public.groups    g  ON g.city ILIKE c.name
                                 AND g.is_active = true
  WHERE  c.is_active = true
  GROUP BY c.id, c.name, s.name, co.name, c.lat, c.lng
  ORDER BY group_count DESC, c.name ASC;
END;
$$;

GRANT EXECUTE ON FUNCTION public.get_active_cities() TO anon, authenticated;


-- ── 4. Verifica resultado ─────────────────────────────────────────────────

SELECT name, state_name, country_name, group_count, demand_level
FROM   get_active_cities();


SELECT '145_activate_cities.sql ejecutado ✅' AS status;
SELECT COUNT(*) || ' ciudades activas' AS info FROM public.cities WHERE is_active = TRUE;
