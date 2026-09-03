-- ============================================================
-- sql/587_food_category.sql
-- NO APLICADO EN PRODUCCIÓN — requiere autorización.
--
-- Agrega la categoría raíz "Comida" a `categories`. Hoy NO existe ninguna
-- fila de comida/catering en esa tabla (confirmado por consulta directa
-- 2026-08-30) — es el único hueco real detectado en la taxonomía de las 8
-- categorías pedidas para "agregar otro proveedor al evento".
--
-- Puramente aditivo: un INSERT, ninguna función ni tabla existente se toca.
-- Sin esta fila, la tarjeta "🍔 Comida" del selector de categorías
-- (EventCategoryPickerScreen.tsx) es real y navega, pero HomeScreen no
-- podrá listar categorías de comida en el chip raíz porque `categories`
-- no la conoce (el filtro por genre="Comida" seguiría funcionando en cuanto
-- exista al menos un grupo con genre='Comida', pero no aparecería como chip
-- seleccionable en la lista general del Home hasta aplicar esto).
-- ============================================================

BEGIN;

INSERT INTO public.categories (name, parent_id, type, active)
VALUES ('Comida', NULL, 'service', true)
ON CONFLICT DO NOTHING;

COMMIT;

-- ── VERIFICACIÓN ──────────────────────────────────────────────────────────────
SELECT id, name, type FROM public.categories WHERE name = 'Comida';
-- Esperado: 1 fila
