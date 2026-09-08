-- 623_category_details_jsonb.sql
-- Pedido 2026-09-05: el ciclo de cotización (QuoteFormScreen, QuoteDetailScreen)
-- y el perfil "Mi Equipo" del proveedor (DashboardScreen) están armados
-- únicamente para música (sonido/iluminación/tarima/pantalla LED) — no
-- preguntan nada relevante para Comida, Renta de mobiliario, Payasos o
-- Fotógrafos. Se agrega una columna flexible en vez de ~14 columnas
-- dedicadas casi siempre vacías (ya hay 12 columnas dedicadas de equipo
-- musical, que NO se tocan ni se renombran).
--
-- groups.category_details  = lo que el proveedor ofrece (su "Mi Comida",
--   "Mi Renta", etc. — análogo a has_sound/has_stage/etc. pero para las
--   4 categorías nuevas).
-- quotes.category_details  = lo que el cliente pidió al cotizar, para esas
--   mismas categorías.
--
-- 100% aditivo: default '{}', ninguna fila existente cambia de significado.

ALTER TABLE public.groups ADD COLUMN IF NOT EXISTS category_details jsonb NOT NULL DEFAULT '{}'::jsonb;
ALTER TABLE public.quotes ADD COLUMN IF NOT EXISTS category_details jsonb NOT NULL DEFAULT '{}'::jsonb;
