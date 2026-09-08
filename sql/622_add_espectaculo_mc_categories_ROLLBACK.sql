-- 622_add_espectaculo_mc_categories_ROLLBACK.sql
CREATE OR REPLACE FUNCTION public.group_default_break_type(p_group_id uuid)
 RETURNS text
 LANGUAGE sql
 STABLE
 SET search_path TO 'public'
AS $function$
  SELECT CASE
    WHEN g.genre = ANY(ARRAY[
      'Comediante', 'Payasos', 'Comida',
      'Renta de brincolines', 'Inflables acuáticos',
      'Renta de mesas', 'Renta de sillas',
      'Fotografía', 'Drones', 'Cabina 360', 'Cabina fotográfica'
    ]) THEN 'D'
    ELSE NULL
  END
  FROM public.groups g WHERE g.id = p_group_id;
$function$;
