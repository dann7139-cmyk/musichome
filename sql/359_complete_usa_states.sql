-- ════════════════════════════════════════════════════════════════════
-- sql/359_complete_usa_states.sql
--
-- Completa el catálogo de estados de USA + DC:
--   Parte A: Actualiza timezone en los 12 estados ya existentes.
--   Parte B: Inserta 38 estados + DC faltantes (ON CONFLICT DO NOTHING).
-- Resultado esperado: 51 entradas (50 estados + DC) con timezone lleno.
--
-- ISO 3166-2:US — todos los códigos verificados contra el estándar.
-- Notas de timezone:
--   - Indiana usa Eastern pero históricamente America/Indiana/Indianapolis;
--     se usa America/New_York por simplicidad y compatibilidad.
--   - Tennessee tiene split E/C; se usa Central (mayoría de la población).
--   - Kentucky tiene split E/C; se usa Eastern (mayoría de la población).
--   - Idaho tiene split P/M; se usa Mountain (mayoría de la población al sur).
--   - Nevada tiene enclaves Mountain; se usa Pacific como timezone oficial.
--   - AZ: America/Phoenix no usa DST (excepto Navajo Nation).
-- ════════════════════════════════════════════════════════════════════


-- ── A. Actualizar timezone en estados existentes ──────────────────────────────

UPDATE public.states
SET timezone = CASE code
  -- Pacífico
  WHEN 'US-CA' THEN 'America/Los_Angeles'
  WHEN 'US-NV' THEN 'America/Los_Angeles'
  WHEN 'US-WA' THEN 'America/Los_Angeles'
  -- Montaña
  WHEN 'US-CO' THEN 'America/Denver'
  -- Montaña sin DST
  WHEN 'US-AZ' THEN 'America/Phoenix'
  -- Central
  WHEN 'US-IL' THEN 'America/Chicago'
  WHEN 'US-TX' THEN 'America/Chicago'
  -- Eastern
  WHEN 'US-FL' THEN 'America/New_York'
  WHEN 'US-GA' THEN 'America/New_York'
  WHEN 'US-MA' THEN 'America/New_York'
  WHEN 'US-NY' THEN 'America/New_York'
  WHEN 'US-NC' THEN 'America/New_York'
END
WHERE code IN (
  'US-CA','US-NV','US-WA',
  'US-CO','US-AZ',
  'US-IL','US-TX',
  'US-FL','US-GA','US-MA','US-NY','US-NC'
)
  AND country_id = (SELECT id FROM public.countries WHERE code = 'US');


-- ── B. Insertar 38 estados + DC faltantes ────────────────────────────────────

INSERT INTO public.states (name, country_id, code, timezone)
VALUES

  -- ── Pacífico (America/Los_Angeles) ───────────────────────────────────────
  ('Oregon',                (SELECT id FROM public.countries WHERE code = 'US'), 'US-OR', 'America/Los_Angeles'),

  -- ── Montaña (America/Denver) ─────────────────────────────────────────────
  ('Idaho',                 (SELECT id FROM public.countries WHERE code = 'US'), 'US-ID', 'America/Denver'),
  ('Montana',               (SELECT id FROM public.countries WHERE code = 'US'), 'US-MT', 'America/Denver'),
  ('New Mexico',            (SELECT id FROM public.countries WHERE code = 'US'), 'US-NM', 'America/Denver'),
  ('Utah',                  (SELECT id FROM public.countries WHERE code = 'US'), 'US-UT', 'America/Denver'),
  ('Wyoming',               (SELECT id FROM public.countries WHERE code = 'US'), 'US-WY', 'America/Denver'),

  -- ── Central (America/Chicago) ─────────────────────────────────────────────
  ('Alabama',               (SELECT id FROM public.countries WHERE code = 'US'), 'US-AL', 'America/Chicago'),
  ('Arkansas',              (SELECT id FROM public.countries WHERE code = 'US'), 'US-AR', 'America/Chicago'),
  ('Iowa',                  (SELECT id FROM public.countries WHERE code = 'US'), 'US-IA', 'America/Chicago'),
  ('Kansas',                (SELECT id FROM public.countries WHERE code = 'US'), 'US-KS', 'America/Chicago'),
  ('Louisiana',             (SELECT id FROM public.countries WHERE code = 'US'), 'US-LA', 'America/Chicago'),
  ('Minnesota',             (SELECT id FROM public.countries WHERE code = 'US'), 'US-MN', 'America/Chicago'),
  ('Mississippi',           (SELECT id FROM public.countries WHERE code = 'US'), 'US-MS', 'America/Chicago'),
  ('Missouri',              (SELECT id FROM public.countries WHERE code = 'US'), 'US-MO', 'America/Chicago'),
  ('Nebraska',              (SELECT id FROM public.countries WHERE code = 'US'), 'US-NE', 'America/Chicago'),
  ('North Dakota',          (SELECT id FROM public.countries WHERE code = 'US'), 'US-ND', 'America/Chicago'),
  ('Oklahoma',              (SELECT id FROM public.countries WHERE code = 'US'), 'US-OK', 'America/Chicago'),
  ('South Dakota',          (SELECT id FROM public.countries WHERE code = 'US'), 'US-SD', 'America/Chicago'),
  ('Tennessee',             (SELECT id FROM public.countries WHERE code = 'US'), 'US-TN', 'America/Chicago'),
  ('Wisconsin',             (SELECT id FROM public.countries WHERE code = 'US'), 'US-WI', 'America/Chicago'),

  -- ── Eastern (America/New_York) ────────────────────────────────────────────
  ('Connecticut',           (SELECT id FROM public.countries WHERE code = 'US'), 'US-CT', 'America/New_York'),
  ('Delaware',              (SELECT id FROM public.countries WHERE code = 'US'), 'US-DE', 'America/New_York'),
  ('District of Columbia',  (SELECT id FROM public.countries WHERE code = 'US'), 'US-DC', 'America/New_York'),
  ('Indiana',               (SELECT id FROM public.countries WHERE code = 'US'), 'US-IN', 'America/New_York'),
  ('Kentucky',              (SELECT id FROM public.countries WHERE code = 'US'), 'US-KY', 'America/New_York'),
  ('Maine',                 (SELECT id FROM public.countries WHERE code = 'US'), 'US-ME', 'America/New_York'),
  ('Maryland',              (SELECT id FROM public.countries WHERE code = 'US'), 'US-MD', 'America/New_York'),
  ('Michigan',              (SELECT id FROM public.countries WHERE code = 'US'), 'US-MI', 'America/New_York'),
  ('New Hampshire',         (SELECT id FROM public.countries WHERE code = 'US'), 'US-NH', 'America/New_York'),
  ('New Jersey',            (SELECT id FROM public.countries WHERE code = 'US'), 'US-NJ', 'America/New_York'),
  ('Ohio',                  (SELECT id FROM public.countries WHERE code = 'US'), 'US-OH', 'America/New_York'),
  ('Pennsylvania',          (SELECT id FROM public.countries WHERE code = 'US'), 'US-PA', 'America/New_York'),
  ('Rhode Island',          (SELECT id FROM public.countries WHERE code = 'US'), 'US-RI', 'America/New_York'),
  ('South Carolina',        (SELECT id FROM public.countries WHERE code = 'US'), 'US-SC', 'America/New_York'),
  ('Virginia',              (SELECT id FROM public.countries WHERE code = 'US'), 'US-VA', 'America/New_York'),
  ('Vermont',               (SELECT id FROM public.countries WHERE code = 'US'), 'US-VT', 'America/New_York'),
  ('West Virginia',         (SELECT id FROM public.countries WHERE code = 'US'), 'US-WV', 'America/New_York'),

  -- ── Alaska ───────────────────────────────────────────────────────────────
  ('Alaska',                (SELECT id FROM public.countries WHERE code = 'US'), 'US-AK', 'America/Anchorage'),

  -- ── Hawaii ───────────────────────────────────────────────────────────────
  ('Hawaii',                (SELECT id FROM public.countries WHERE code = 'US'), 'US-HI', 'Pacific/Honolulu')

ON CONFLICT (country_id, code) DO NOTHING;


-- ── Verificación ─────────────────────────────────────────────────────────────
-- Esperado: total=51, con_timezone=51, sin_timezone=0

SELECT
  COUNT(*)                                        AS total_estados_us,
  COUNT(timezone)                                 AS con_timezone,
  COUNT(*) FILTER (WHERE timezone IS NULL)        AS sin_timezone
FROM public.states
WHERE country_id = (SELECT id FROM public.countries WHERE code = 'US');


-- ── Verificación consolidada (para pegar al final de los 3 SQLs) ─────────────

SELECT
  c.code                                          AS pais,
  COUNT(s.id)                                     AS total_estados,
  COUNT(s.timezone)                               AS con_timezone,
  COUNT(*) FILTER (WHERE s.timezone IS NULL)      AS sin_timezone
FROM public.countries c
LEFT JOIN public.states s ON s.country_id = c.id
WHERE c.is_active = TRUE
GROUP BY c.code
ORDER BY c.code;
