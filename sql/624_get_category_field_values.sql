-- sql/624_get_category_field_values.sql
-- Lista de opciones que crece sola por categoría, sin tabla nueva.
--
-- PETICIÓN REAL (2026-09-05): "los tipos de servicio se pueden ir
-- agregando dependiendo el proveedor... que se guarde para siempre el
-- tipo de servicio de esa categoría pero para todos" — si un proveedor
-- de Comida escribe "Rosticería" (función "Agregar otro", ya construida
-- en sql/623), el SIGUIENTE proveedor de Comida debe poder elegirla de
-- la lista, no volver a escribirla. Aplica igual a Renta, Payasos,
-- Fotógrafos (cualquier categoría con campos chips/multiChips).
--
-- Decisión de diseño: NO se crea una tabla nueva que sincronizar. Lo que
-- cada proveedor escribe YA se guarda en groups.category_details al
-- guardar su perfil (sql/623) — esta función solo LEE los valores
-- distintos que ya existen ahí para una categoría+campo dados. Se
-- "autolimpia" sola (si nadie más ofrece "Toro mecánico", deja de
-- aparecer) y no requiere tocar el flujo de guardado existente.
--
-- Reusa group_category_key(group_id) (sql/610, ya en producción — la
-- misma función que usa el admin para filtrar Destacado/Recomendado por
-- categoría) para no duplicar la lista de géneros por categoría.
--
-- category_details puede tener, para un mismo campo, un STRING (campos
-- 'chips') o un ARRAY (campos 'multiChips') — se prueban ambos casos
-- porque la función no sabe de antemano cuál es.
CREATE OR REPLACE FUNCTION public.get_category_field_values(p_category_key TEXT, p_field_key TEXT)
RETURNS TABLE(value TEXT)
LANGUAGE sql STABLE
SET search_path TO 'public'
AS $$
  SELECT DISTINCT v FROM (
    SELECT category_details->>p_field_key AS v
    FROM public.groups g
    WHERE g.is_active = true
      AND public.group_category_key(g.id) = p_category_key
      AND jsonb_typeof(g.category_details->p_field_key) = 'string'
    UNION
    SELECT jsonb_array_elements_text(g.category_details->p_field_key) AS v
    FROM public.groups g
    WHERE g.is_active = true
      AND public.group_category_key(g.id) = p_category_key
      AND jsonb_typeof(g.category_details->p_field_key) = 'array'
  ) t
  WHERE v IS NOT NULL AND v <> '';
$$;
