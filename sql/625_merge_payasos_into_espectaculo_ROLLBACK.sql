-- 625_merge_payasos_into_espectaculo_ROLLBACK.sql
-- Restaura group_category_key y group_default_break_type a su versión
-- previa (Payasos como categoría propia forzada a 'D'; Espectáculo y
-- Maestro de Ceremonias sin clasificar en group_category_key).

CREATE OR REPLACE FUNCTION public.group_category_key(p_group_id uuid)
 RETURNS text
 LANGUAGE sql
 STABLE
 SET search_path TO 'public'
AS $function$
  SELECT CASE
    WHEN g.genre = ANY(ARRAY[
      'Bachata','Balada','Banda','Blues','Bolero','Corridos','Corridos Tumbados',
      'Country','Cuartetos','Cumbia','Danzón','Electrónica','Folklore','Gospel',
      'Grupero','Grupos musicales','Hip Hop','Huapango','Jazz','Mariachi','Marimba',
      'Merengue','Norteño','Pop','R&B','Ranchero','Reggaeton','Rock','Salsa',
      'Sextetos','Son Jarocho','Tango','Tríos','Tropical','Trova','Vallenato','Versátil'
    ]) THEN 'grupo'
    WHEN g.genre = 'Solistas' THEN 'solista'
    WHEN g.genre = 'DJ' THEN 'dj'
    WHEN g.genre = 'Comediante' THEN 'comediante'
    WHEN g.genre = 'Payasos' THEN 'payasos'
    WHEN g.genre = ANY(ARRAY[
      'Sonido / Iluminación','Sonido','Iluminación','Cabinas DJ',
      'Iluminación profesional','Micrófonos','Pantallas LED','Proyectores','Sonido profesional'
    ]) THEN 'luzSonido'
    WHEN g.genre = 'Comida' THEN 'comida'
    WHEN g.genre = ANY(ARRAY[
      'Escenarios','Generadores eléctricos','Inflables acuáticos','Plantas de luz',
      'Renta de brincolines','Renta de mesas','Renta de sillas','Renta de toldos','Tarimas'
    ]) THEN 'renta'
    WHEN g.genre = ANY(ARRAY['Fotografía','Drones','Cabina 360','Cabina fotográfica']) THEN 'fotografos'
    ELSE NULL
  END
  FROM public.groups g WHERE g.id = p_group_id;
$function$;

CREATE OR REPLACE FUNCTION public.group_default_break_type(p_group_id uuid)
 RETURNS text
 LANGUAGE sql
 STABLE
 SET search_path TO 'public'
AS $function$
  SELECT CASE
    WHEN g.genre = ANY(ARRAY[
      'Comediante', 'Payasos', 'Comida', 'Maestro de Ceremonias',
      'Renta de brincolines', 'Inflables acuáticos',
      'Renta de mesas', 'Renta de sillas',
      'Fotografía', 'Drones', 'Cabina 360', 'Cabina fotográfica'
    ]) THEN 'D'
    ELSE NULL
  END
  FROM public.groups g WHERE g.id = p_group_id;
$function$;
