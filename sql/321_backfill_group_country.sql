-- 321_backfill_group_country.sql
-- Rellena groups.country para los 14 grupos que tienen country = NULL.
-- Deriva el país a partir del estado usando la misma lógica que stateToCountry()
-- en el frontend (locationUtils.ts).
-- No modifica grupos que ya tienen country establecido.

-- Estados mexicanos
UPDATE public.groups
SET country = 'México'
WHERE country IS NULL
  AND state IN (
    'Aguascalientes', 'Baja California', 'Baja California Sur', 'Campeche',
    'Chiapas', 'Chihuahua', 'Ciudad de México', 'CDMX', 'Coahuila', 'Colima',
    'Durango', 'Guanajuato', 'Guerrero', 'Hidalgo', 'Jalisco',
    'Estado de México', 'Michoacán', 'Morelos', 'Nayarit',
    'Nuevo León', 'Oaxaca', 'Puebla', 'Querétaro', 'Quintana Roo',
    'San Luis Potosí', 'Sinaloa', 'Sonora', 'Tabasco', 'Tamaulipas',
    'Tlaxcala', 'Veracruz', 'Yucatán', 'Zacatecas'
  );

-- Estados de EE. UU.
UPDATE public.groups
SET country = 'Estados Unidos'
WHERE country IS NULL
  AND state IN (
    'Alabama', 'Alaska', 'Arizona', 'Arkansas', 'California', 'Colorado',
    'Connecticut', 'Delaware', 'Florida', 'Georgia', 'Hawaii', 'Idaho',
    'Illinois', 'Indiana', 'Iowa', 'Kansas', 'Kentucky', 'Louisiana',
    'Maine', 'Maryland', 'Massachusetts', 'Michigan', 'Minnesota', 'Mississippi',
    'Missouri', 'Montana', 'Nebraska', 'Nevada', 'New Hampshire', 'New Jersey',
    'New Mexico', 'New York', 'North Carolina', 'North Dakota', 'Ohio',
    'Oklahoma', 'Oregon', 'Pennsylvania', 'Rhode Island', 'South Carolina',
    'South Dakota', 'Tennessee', 'Texas', 'Utah', 'Vermont', 'Virginia',
    'Washington', 'West Virginia', 'Wisconsin', 'Wyoming', 'District of Columbia'
  );

-- Fallback: cualquier grupo aún sin country → México (sede principal del producto)
UPDATE public.groups
SET country = 'México'
WHERE country IS NULL;

-- Verificación final (debe mostrar 0 filas con country IS NULL)
SELECT id, name, state, country
FROM public.groups
WHERE country IS NULL;
