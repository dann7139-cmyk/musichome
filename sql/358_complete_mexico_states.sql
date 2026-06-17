-- ════════════════════════════════════════════════════════════════════
-- sql/358_complete_mexico_states.sql
--
-- Completa el catálogo de estados de México:
--   Parte A: Actualiza timezone en los 15 estados ya existentes.
--   Parte B: Inserta los 17 estados faltantes (ON CONFLICT DO NOTHING).
-- Resultado esperado: 32 estados con country_id = MX y timezone lleno.
--
-- ISO 3166-2:MX — todos los códigos verificados contra el estándar.
-- ════════════════════════════════════════════════════════════════════


-- ── A. Actualizar timezone en estados existentes ──────────────────────────────

UPDATE public.states
SET timezone = CASE code
  -- Zona Central (America/Mexico_City) — mayoría del país
  WHEN 'MX-AGU' THEN 'America/Mexico_City'   -- Aguascalientes
  WHEN 'MX-CMX' THEN 'America/Mexico_City'   -- Ciudad de México
  WHEN 'MX-GRO' THEN 'America/Mexico_City'   -- Guerrero
  WHEN 'MX-JAL' THEN 'America/Mexico_City'   -- Jalisco
  WHEN 'MX-MEX' THEN 'America/Mexico_City'   -- Estado de México
  WHEN 'MX-OAX' THEN 'America/Mexico_City'   -- Oaxaca
  WHEN 'MX-PUE' THEN 'America/Mexico_City'   -- Puebla
  WHEN 'MX-QUE' THEN 'America/Mexico_City'   -- Querétaro
  WHEN 'MX-VER' THEN 'America/Mexico_City'   -- Veracruz
  WHEN 'MX-YUC' THEN 'America/Mexico_City'   -- Yucatán
  -- Zona Central (America/Monterrey) — noreste
  WHEN 'MX-NLE' THEN 'America/Monterrey'     -- Nuevo León
  -- Zona Pacífico (America/Mazatlan) — noroeste medio
  WHEN 'MX-SIN' THEN 'America/Mazatlan'      -- Sinaloa
  -- Zona Noroeste — casos especiales
  WHEN 'MX-BCN' THEN 'America/Tijuana'       -- Baja California (sigue DST de USA)
  WHEN 'MX-CHH' THEN 'America/Chihuahua'     -- Chihuahua
  WHEN 'MX-SON' THEN 'America/Hermosillo'    -- Sonora (sin cambio de horario)
END
WHERE code IN (
  'MX-AGU','MX-BCN','MX-CHH','MX-CMX','MX-GRO',
  'MX-JAL','MX-MEX','MX-NLE','MX-OAX','MX-PUE',
  'MX-QUE','MX-SIN','MX-SON','MX-VER','MX-YUC'
)
  AND country_id = (SELECT id FROM public.countries WHERE code = 'MX');


-- ── B. Insertar 17 estados faltantes ─────────────────────────────────────────

INSERT INTO public.states (name, country_id, code, timezone)
VALUES
  -- Zona Pacífico (America/Mazatlan)
  ('Baja California Sur', (SELECT id FROM public.countries WHERE code = 'MX'), 'MX-BCS', 'America/Mazatlan'),
  ('Nayarit',             (SELECT id FROM public.countries WHERE code = 'MX'), 'MX-NAY', 'America/Mazatlan'),

  -- Zona Cancún — sin cambio de horario desde 2015 (UTC-5 fijo)
  ('Quintana Roo',        (SELECT id FROM public.countries WHERE code = 'MX'), 'MX-ROO', 'America/Cancun'),

  -- Zona Central (America/Monterrey) — noreste
  ('Coahuila',            (SELECT id FROM public.countries WHERE code = 'MX'), 'MX-COA', 'America/Monterrey'),
  ('Durango',             (SELECT id FROM public.countries WHERE code = 'MX'), 'MX-DUR', 'America/Monterrey'),
  ('Tamaulipas',          (SELECT id FROM public.countries WHERE code = 'MX'), 'MX-TAM', 'America/Matamoros'),

  -- Zona Central (America/Mexico_City) — centro y sur
  ('Campeche',            (SELECT id FROM public.countries WHERE code = 'MX'), 'MX-CAM', 'America/Mexico_City'),
  ('Chiapas',             (SELECT id FROM public.countries WHERE code = 'MX'), 'MX-CHP', 'America/Mexico_City'),
  ('Colima',              (SELECT id FROM public.countries WHERE code = 'MX'), 'MX-COL', 'America/Mexico_City'),
  ('Guanajuato',          (SELECT id FROM public.countries WHERE code = 'MX'), 'MX-GUA', 'America/Mexico_City'),
  ('Hidalgo',             (SELECT id FROM public.countries WHERE code = 'MX'), 'MX-HID', 'America/Mexico_City'),
  ('Michoacán',           (SELECT id FROM public.countries WHERE code = 'MX'), 'MX-MIC', 'America/Mexico_City'),
  ('Morelos',             (SELECT id FROM public.countries WHERE code = 'MX'), 'MX-MOR', 'America/Mexico_City'),
  ('San Luis Potosí',     (SELECT id FROM public.countries WHERE code = 'MX'), 'MX-SLP', 'America/Mexico_City'),
  ('Tabasco',             (SELECT id FROM public.countries WHERE code = 'MX'), 'MX-TAB', 'America/Mexico_City'),
  ('Tlaxcala',            (SELECT id FROM public.countries WHERE code = 'MX'), 'MX-TLA', 'America/Mexico_City'),
  ('Zacatecas',           (SELECT id FROM public.countries WHERE code = 'MX'), 'MX-ZAC', 'America/Mexico_City')

ON CONFLICT (country_id, code) DO NOTHING;


-- ── Verificación ─────────────────────────────────────────────────────────────
-- Esperado: total=32, con_timezone=32, sin_timezone=0

SELECT
  COUNT(*)                                        AS total_estados_mx,
  COUNT(timezone)                                 AS con_timezone,
  COUNT(*) FILTER (WHERE timezone IS NULL)        AS sin_timezone
FROM public.states
WHERE country_id = (SELECT id FROM public.countries WHERE code = 'MX');
