-- ROLLBACK de sql/604_photography_no_break_timer.sql
-- Solo correr en emergencia deliberada.

BEGIN;

UPDATE public.categories
SET name = 'Multimedia'
WHERE id = '88709623-ae3e-400c-857c-24f89ea0b879' AND name = 'Fotógrafos';

CREATE OR REPLACE FUNCTION public.group_default_break_type(p_group_id UUID)
RETURNS TEXT LANGUAGE sql STABLE SET search_path TO 'public' AS $function$
  SELECT CASE
    WHEN g.genre = ANY(ARRAY[
      'Comediante', 'Payasos', 'Comida',
      'Renta de brincolines', 'Inflables acuáticos',
      'Renta de mesas', 'Renta de sillas'
    ]) THEN 'D'
    ELSE NULL
  END
  FROM public.groups g WHERE g.id = p_group_id;
$function$;

COMMIT;
