-- ============================================================
-- DARICEFY - 13_categories_paso2.sql
-- FASE 1 – PASO 2: Inserta categorías faltantes del plan.
-- Safe to re-run: ON CONFLICT DO NOTHING en todos los inserts.
-- Run AFTER 09_categories.sql
-- ============================================================

-- ─────────────────────────────────────────────────
-- STEP 1: Expand the type CHECK constraint
-- Allows new types: rental, audio, decoration, multimedia
-- ─────────────────────────────────────────────────
ALTER TABLE public.categories DROP CONSTRAINT IF EXISTS categories_type_check;
ALTER TABLE public.categories
  ADD CONSTRAINT categories_type_check
  CHECK (type IN ('music', 'entertainment', 'service', 'rental', 'audio', 'decoration', 'multimedia'));

-- ─────────────────────────────────────────────────
-- STEP 2: Missing subcategories under "Música en vivo"
-- ─────────────────────────────────────────────────
WITH parent AS (
  SELECT id FROM public.categories
  WHERE name = 'Música en vivo' AND parent_id IS NULL
)
INSERT INTO public.categories (name, parent_id, type, active)
SELECT v.name, parent.id, 'music', TRUE
FROM parent,
(VALUES
  ('Grupos musicales'),
  ('Tríos'),
  ('Solistas'),
  ('Cuartetos'),
  ('Sextetos')
) AS v(name)
ON CONFLICT DO NOTHING;

-- ─────────────────────────────────────────────────
-- STEP 3: Missing subcategories under "Entretenimiento"
-- ─────────────────────────────────────────────────
WITH parent AS (
  SELECT id FROM public.categories
  WHERE name = 'Entretenimiento' AND parent_id IS NULL
)
INSERT INTO public.categories (name, parent_id, type, active)
SELECT v.name, parent.id, 'entertainment', TRUE
FROM parent,
(VALUES
  ('Payasos'),
  ('Imitadores'),
  ('Shows infantiles'),
  ('Circo'),
  ('Acróbatas')
) AS v(name)
ON CONFLICT DO NOTHING;

-- ─────────────────────────────────────────────────
-- STEP 4: NEW root categories
-- ─────────────────────────────────────────────────
INSERT INTO public.categories (name, parent_id, type, active) VALUES
  ('Renta y Producción',  NULL, 'rental',     TRUE),
  ('Iluminación y Audio', NULL, 'audio',       TRUE),
  ('Decoración',          NULL, 'decoration',  TRUE),
  ('Multimedia',          NULL, 'multimedia',  TRUE)
ON CONFLICT DO NOTHING;

-- ─────────────────────────────────────────────────
-- STEP 5: Subcategorías de "Renta y Producción"
-- ─────────────────────────────────────────────────
WITH parent AS (
  SELECT id FROM public.categories
  WHERE name = 'Renta y Producción' AND parent_id IS NULL
)
INSERT INTO public.categories (name, parent_id, type, active)
SELECT v.name, parent.id, 'rental', TRUE
FROM parent,
(VALUES
  ('Renta de toldos'),
  ('Renta de sillas'),
  ('Renta de mesas'),
  ('Renta de brincolines'),
  ('Inflables acuáticos'),
  ('Escenarios'),
  ('Tarimas'),
  ('Plantas de luz'),
  ('Generadores eléctricos')
) AS v(name)
ON CONFLICT DO NOTHING;

-- ─────────────────────────────────────────────────
-- STEP 6: Subcategorías de "Iluminación y Audio"
-- ─────────────────────────────────────────────────
WITH parent AS (
  SELECT id FROM public.categories
  WHERE name = 'Iluminación y Audio' AND parent_id IS NULL
)
INSERT INTO public.categories (name, parent_id, type, active)
SELECT v.name, parent.id, 'audio', TRUE
FROM parent,
(VALUES
  ('Iluminación profesional'),
  ('Sonido profesional'),
  ('Micrófonos'),
  ('Pantallas LED'),
  ('Proyectores'),
  ('Cabinas DJ')
) AS v(name)
ON CONFLICT DO NOTHING;

-- ─────────────────────────────────────────────────
-- STEP 7: Subcategorías de "Decoración"
-- ─────────────────────────────────────────────────
WITH parent AS (
  SELECT id FROM public.categories
  WHERE name = 'Decoración' AND parent_id IS NULL
)
INSERT INTO public.categories (name, parent_id, type, active)
SELECT v.name, parent.id, 'decoration', TRUE
FROM parent,
(VALUES
  ('Decoración infantil'),
  ('Decoración temática'),
  ('Centros de mesa'),
  ('Globos'),
  ('Flores')
) AS v(name)
ON CONFLICT DO NOTHING;

-- ─────────────────────────────────────────────────
-- STEP 8: Subcategorías de "Multimedia"
-- ─────────────────────────────────────────────────
WITH parent AS (
  SELECT id FROM public.categories
  WHERE name = 'Multimedia' AND parent_id IS NULL
)
INSERT INTO public.categories (name, parent_id, type, active)
SELECT v.name, parent.id, 'multimedia', TRUE
FROM parent,
(VALUES
  ('Fotografía'),
  ('Video'),
  ('Drones'),
  ('Cabina 360'),
  ('Cabina fotográfica')
) AS v(name)
ON CONFLICT DO NOTHING;

-- ─────────────────────────────────────────────────
-- VERIFICATION: Show final category tree summary
-- ─────────────────────────────────────────────────
SELECT
  root.name   AS categoria_raiz,
  root.type   AS tipo,
  COUNT(sub.id) AS subcategorias
FROM public.categories root
LEFT JOIN public.categories sub
  ON sub.parent_id = root.id AND sub.active = TRUE
WHERE root.parent_id IS NULL
  AND root.active = TRUE
GROUP BY root.id, root.name, root.type
ORDER BY root.type, root.name;
