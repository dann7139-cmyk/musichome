-- ============================================================
-- sql/266_usa_cities_and_profile_sync.sql
--
-- 1. Agrega Estados Unidos con sus estados y ciudades principales
--    al selector de ciudad (cities table).
-- 2. Sincroniza profiles.state de talentos/clientes que tienen
--    estado en job_board_profiles o groups pero null en profiles.
-- 3. Sincroniza profiles.country de todos los registros con
--    country null usando stateToCountry equivalente en SQL.
--
-- Idempotente: ON CONFLICT DO NOTHING / DO UPDATE.
-- ============================================================

DO $$
DECLARE
  v_us_id UUID;
  -- Estados USA
  v_ca UUID; v_tx UUID; v_ny UUID; v_fl UUID;
  v_il UUID; v_wa UUID; v_az UUID; v_co UUID;
  v_nv UUID; v_ga UUID; v_ma UUID; v_nc UUID;
BEGIN

  -- ── País: Estados Unidos ──────────────────────────────────────────────────
  INSERT INTO public.countries (code, name, currency_code, currency_symbol,
    payment_provider, commission_rate, timezone, is_active, launch_date)
  VALUES ('US', 'Estados Unidos', 'USD', '$', 'stripe', 0.15,
          'America/New_York', TRUE, CURRENT_DATE)
  ON CONFLICT (code) DO UPDATE
    SET is_active = TRUE, name = EXCLUDED.name;

  SELECT id INTO v_us_id FROM public.countries WHERE code = 'US';

  -- ── Estados USA ───────────────────────────────────────────────────────────
  INSERT INTO public.states (country_id, code, name)
  VALUES
    (v_us_id, 'US-CA', 'California'),
    (v_us_id, 'US-TX', 'Texas'),
    (v_us_id, 'US-NY', 'New York'),
    (v_us_id, 'US-FL', 'Florida'),
    (v_us_id, 'US-IL', 'Illinois'),
    (v_us_id, 'US-WA', 'Washington'),
    (v_us_id, 'US-AZ', 'Arizona'),
    (v_us_id, 'US-CO', 'Colorado'),
    (v_us_id, 'US-NV', 'Nevada'),
    (v_us_id, 'US-GA', 'Georgia'),
    (v_us_id, 'US-MA', 'Massachusetts'),
    (v_us_id, 'US-NC', 'North Carolina')
  ON CONFLICT (country_id, code) DO NOTHING;

  SELECT id INTO v_ca FROM public.states WHERE country_id = v_us_id AND code = 'US-CA';
  SELECT id INTO v_tx FROM public.states WHERE country_id = v_us_id AND code = 'US-TX';
  SELECT id INTO v_ny FROM public.states WHERE country_id = v_us_id AND code = 'US-NY';
  SELECT id INTO v_fl FROM public.states WHERE country_id = v_us_id AND code = 'US-FL';
  SELECT id INTO v_il FROM public.states WHERE country_id = v_us_id AND code = 'US-IL';
  SELECT id INTO v_wa FROM public.states WHERE country_id = v_us_id AND code = 'US-WA';
  SELECT id INTO v_az FROM public.states WHERE country_id = v_us_id AND code = 'US-AZ';
  SELECT id INTO v_co FROM public.states WHERE country_id = v_us_id AND code = 'US-CO';
  SELECT id INTO v_nv FROM public.states WHERE country_id = v_us_id AND code = 'US-NV';
  SELECT id INTO v_ga FROM public.states WHERE country_id = v_us_id AND code = 'US-GA';
  SELECT id INTO v_ma FROM public.states WHERE country_id = v_us_id AND code = 'US-MA';
  SELECT id INTO v_nc FROM public.states WHERE country_id = v_us_id AND code = 'US-NC';

  -- ── Ciudades USA ─────────────────────────────────────────────────────────
  INSERT INTO public.cities (state_id, country_id, name, lat, lng, is_active, launch_date)
  VALUES
    -- California
    (v_ca, v_us_id, 'Los Angeles',     34.0522, -118.2437, TRUE, CURRENT_DATE),
    (v_ca, v_us_id, 'San Francisco',   37.7749, -122.4194, TRUE, CURRENT_DATE),
    (v_ca, v_us_id, 'San Diego',       32.7157, -117.1611, TRUE, CURRENT_DATE),
    -- Texas
    (v_tx, v_us_id, 'Houston',         29.7604,  -95.3698, TRUE, CURRENT_DATE),
    (v_tx, v_us_id, 'Dallas',          32.7767,  -96.7970, TRUE, CURRENT_DATE),
    (v_tx, v_us_id, 'San Antonio',     29.4241,  -98.4936, TRUE, CURRENT_DATE),
    (v_tx, v_us_id, 'Austin',          30.2672,  -97.7431, TRUE, CURRENT_DATE),
    -- New York
    (v_ny, v_us_id, 'New York City',   40.7128,  -74.0060, TRUE, CURRENT_DATE),
    (v_ny, v_us_id, 'Buffalo',         42.8864,  -78.8784, TRUE, CURRENT_DATE),
    -- Florida
    (v_fl, v_us_id, 'Miami',           25.7617,  -80.1918, TRUE, CURRENT_DATE),
    (v_fl, v_us_id, 'Orlando',         28.5383,  -81.3792, TRUE, CURRENT_DATE),
    (v_fl, v_us_id, 'Tampa',           27.9506,  -82.4572, TRUE, CURRENT_DATE),
    -- Illinois
    (v_il, v_us_id, 'Chicago',         41.8781,  -87.6298, TRUE, CURRENT_DATE),
    -- Washington
    (v_wa, v_us_id, 'Seattle',         47.6062, -122.3321, TRUE, CURRENT_DATE),
    -- Arizona
    (v_az, v_us_id, 'Phoenix',         33.4484, -112.0740, TRUE, CURRENT_DATE),
    -- Colorado
    (v_co, v_us_id, 'Denver',          39.7392, -104.9903, TRUE, CURRENT_DATE),
    -- Nevada
    (v_nv, v_us_id, 'Las Vegas',       36.1699, -115.1398, TRUE, CURRENT_DATE),
    -- Georgia
    (v_ga, v_us_id, 'Atlanta',         33.7490,  -84.3880, TRUE, CURRENT_DATE),
    -- Massachusetts
    (v_ma, v_us_id, 'Boston',          42.3601,  -71.0589, TRUE, CURRENT_DATE),
    -- North Carolina
    (v_nc, v_us_id, 'Charlotte',       35.2271,  -80.8431, TRUE, CURRENT_DATE)
  ON CONFLICT DO NOTHING;

  RAISE NOTICE 'Ciudades de Estados Unidos agregadas al selector ✅';
END;
$$;


-- ── Sincronizar profiles.state para dueños de grupos sin estado ──────────────
-- Cubre: grupos México, USA y cualquier otro.
UPDATE public.profiles p
SET
  state   = g.state,
  country = COALESCE(NULLIF(p.country, ''), g.country, 'México'),
  updated_at = NOW()
FROM public.groups g
WHERE g.owner_id     = p.id
  AND g.state        IS NOT NULL
  AND TRIM(g.state)  != ''
  AND (p.state IS NULL OR TRIM(p.state) = '');


-- ── Sincronizar profiles.state para talentos con invitación aceptada ─────────
-- Si el talento tiene una invitación aceptada de un grupo, hereda el estado.
UPDATE public.profiles p
SET
  state      = g.state,
  country    = COALESCE(NULLIF(p.country, ''), g.country, 'México'),
  updated_at = NOW()
FROM public.job_invitations ji
JOIN public.groups g ON g.id = ji.group_id
WHERE ji.invited_user_id = p.id
  AND ji.status          = 'accepted'
  AND g.state            IS NOT NULL
  AND TRIM(g.state)      != ''
  AND (p.state IS NULL OR TRIM(p.state) = '');


-- ── Verificación ─────────────────────────────────────────────────────────────
SELECT
  p.full_name,
  p.role,
  p.city,
  p.state,
  p.country
FROM public.profiles p
WHERE p.state IS NOT NULL
ORDER BY p.country, p.state, p.role
LIMIT 40;

SELECT 'SQL 266 ejecutado ✅ — US cities added, profiles synced' AS status;
